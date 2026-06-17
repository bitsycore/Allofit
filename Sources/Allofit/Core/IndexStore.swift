import Foundation
import CoreServices

// IndexStore persists the file index to disk using a compact LZ4-compressed
// binary format. It also stores the FSEvents event id at save time so the
// watcher can replay events that happened while the app was closed - the
// fast-resume mechanism analogous to how Everything reads the USN journal
// on launch.
//
// On-disk layout:
//   [magic "AZLF" : u32][version : u32][uncompressedSize : u64]
//   [LZ4-compressed payload]
// The compressed payload decompresses to:
//   [lastEventId : u64][recordCount : u64]
//   { for each record: id u64, size i64, created f64, modified f64,
//                       flags u8, name(len u32, utf8 bytes),
//                       parentPath(len u32, utf8 bytes) }
enum IndexStore {

	// outer envelope magic: ASCII "AZLF" (compressed) - bumped from v1 "ALOF"
	private static let kMagic: UInt32 = 0x415A_4C46
	// format version - bump if the inner payload layout changes
	private static let kVersion: UInt32 = 2

	// the value loaded back from the cache
	struct LoadResult {
		// records previously persisted
		let records: [FileRecord]
		// last FSEvents event id known when the cache was written
		let lastEventId: UInt64
	}

	// per-process cache location: the system-wide path when running as root
	// daemon (env var set by ServiceInstaller), otherwise the per-user path.
	static var cacheURL: URL {
		let vUseSystem = ProcessInfo.processInfo.environment["ALLOFIT_SYSTEM_INDEX"] == "1"
		return cacheURL(forSystem: vUseSystem)
	}

	// returns the cache URL for a specific scope. The GUI uses this to read
	// the system-wide cache when the root daemon owns the index.
	static func cacheURL(forSystem inSystem: Bool) -> URL {
		let vBase: URL
		if inSystem {
			vBase = URL(fileURLWithPath: "/Library/Application Support")
		} else {
			vBase = FileManager.default.urls(
				for: .applicationSupportDirectory,
				in: .userDomainMask
			).first!
		}
		let vDir = vBase.appendingPathComponent("Allofit", isDirectory: true)
		try? FileManager.default.createDirectory(at: vDir, withIntermediateDirectories: true)
		// for the system-wide path the directory may have been created by the
		// root daemon - make sure non-root users (the GUI) can traverse it
		if inSystem {
			chmod(vDir.path, 0o755)
		}
		return vDir.appendingPathComponent("index.bin")
	}

	// returns the URL appropriate for a given service mode
	static func cacheURL(forServiceMode inMode: Preferences.ServiceMode) -> URL {
		return cacheURL(forSystem: inMode == .rootDaemon)
	}

	// path of the indexer lock sentinel, alongside the cache
	static func lockURL(forSystem inSystem: Bool) -> URL {
		return cacheURL(forSystem: inSystem)
			.deletingLastPathComponent()
			.appendingPathComponent("indexer.lock")
	}

	// returns the on-disk size in bytes of the current cache file, or 0
	static func cacheFileSize(at inUrl: URL) -> Int64 {
		guard let vAttrs = try? FileManager.default.attributesOfItem(atPath: inUrl.path) else { return 0 }
		return (vAttrs[.size] as? NSNumber)?.int64Value ?? 0
	}

	// deletes the cache file at the given URL
	static func clearCache(at inUrl: URL) {
		try? FileManager.default.removeItem(at: inUrl)
	}

	// ===========================
	// MARK: Save / load
	// ===========================

	// writes the records and event id atomically to the default cacheURL
	static func save(inRecords: [FileRecord], inLastEventId: UInt64) {
		save(inRecords: inRecords, inLastEventId: inLastEventId, to: cacheURL)
	}

	// writes the records and event id atomically to a specific URL.
	// Wrapped in autoreleasepool because every call autoreleases a number
	// of Foundation objects (the compressed NSData, NSURLs created by
	// FileManager.replaceItem, etc.) - if the caller is a long-running
	// block whose own pool never drains, those would accumulate forever.
	static func save(inRecords: [FileRecord], inLastEventId: UInt64, to inUrl: URL) {
		autoreleasepool {
			save_impl(inRecords: inRecords, inLastEventId: inLastEventId, to: inUrl)
		}
	}

	private static func save_impl(inRecords: [FileRecord], inLastEventId: UInt64, to inUrl: URL) {
		var vPayload = Data()
		vPayload.reserveCapacity(16 + inRecords.count * 80)
		writeU64(into: &vPayload, value: inLastEventId)
		writeU64(into: &vPayload, value: UInt64(inRecords.count))
		for vRecord in inRecords {
			writeU64(into: &vPayload, value: vRecord.id)
			writeI64(into: &vPayload, value: vRecord.size)
			writeF64(into: &vPayload, value: vRecord.dateCreated.timeIntervalSince1970)
			writeF64(into: &vPayload, value: vRecord.dateModified.timeIntervalSince1970)
			var vFlags: UInt8 = 0
			if vRecord.isDirectory { vFlags |= 0x01 }
			vPayload.append(vFlags)
			writeString(into: &vPayload, value: vRecord.name)
			writeString(into: &vPayload, value: vRecord.parentPath)
		}

		// compress with LZ4 (raw block format, ~70% size reduction on text-heavy paths)
		let vUncompressedSize = UInt64(vPayload.count)
		let vCompressed: Data
		do {
			vCompressed = try (vPayload as NSData).compressed(using: .lz4) as Data
		} catch {
			NSLog("[Allofit] LZ4 compression failed, skipping save: \(error)")
			return
		}

		var vEnvelope = Data()
		vEnvelope.reserveCapacity(16 + vCompressed.count)
		writeU32(into: &vEnvelope, value: kMagic)
		writeU32(into: &vEnvelope, value: kVersion)
		writeU64(into: &vEnvelope, value: vUncompressedSize)
		vEnvelope.append(vCompressed)

		let vTmp = inUrl.appendingPathExtension("tmp")
		do {
			try vEnvelope.write(to: vTmp, options: .atomic)
			_ = try FileManager.default.replaceItem(
				at: inUrl,
				withItemAt: vTmp,
				backupItemName: nil,
				options: [],
				resultingItemURL: nil
			)
			// the root daemon writes this file owned by root. The GUI runs
			// as the user and must be able to read it, so force world-read
			// permissions regardless of the process's umask.
			chmod(inUrl.path, 0o644)
		} catch {
			NSLog("[Allofit] cache save failed at %@: %@", inUrl.path, "\(error)")
			try? FileManager.default.removeItem(at: vTmp)
		}
	}

	// reads the persisted index back from the default cacheURL
	static func load() -> LoadResult? {
		return load(from: cacheURL)
	}

	// reads the persisted index back from a specific URL. Wrapped in
	// autoreleasepool so the decompressed NSData and the per-record
	// String allocations don't linger in the caller's pool.
	static func load(from inUrl: URL) -> LoadResult? {
		return autoreleasepool {
			load_impl(from: inUrl)
		}
	}

	private static func load_impl(from inUrl: URL) -> LoadResult? {
		guard let vData = try? Data(contentsOf: inUrl) else { return nil }
		var vOffset = 0
		guard let vMagic = readU32(from: vData, offset: &vOffset), vMagic == kMagic else { return nil }
		guard let vVersion = readU32(from: vData, offset: &vOffset), vVersion == kVersion else { return nil }
		guard let _ = readU64(from: vData, offset: &vOffset) else { return nil }  // uncompressed size, advisory only

		let vCompressed = vData.subdata(in: vOffset..<vData.count)
		let vPayload: Data
		do {
			vPayload = try (vCompressed as NSData).decompressed(using: .lz4) as Data
		} catch {
			NSLog("[Allofit] LZ4 decompression failed: \(error)")
			return nil
		}

		var vP = 0
		guard let vLastEventId = readU64(from: vPayload, offset: &vP) else { return nil }
		guard let vCount = readU64(from: vPayload, offset: &vP) else { return nil }
		var vRecords: [FileRecord] = []
		vRecords.reserveCapacity(Int(vCount))
		for _ in 0..<Int(vCount) {
			guard let vId = readU64(from: vPayload, offset: &vP),
				  let vSize = readI64(from: vPayload, offset: &vP),
				  let vCreated = readF64(from: vPayload, offset: &vP),
				  let vModified = readF64(from: vPayload, offset: &vP),
				  let vFlags = readU8(from: vPayload, offset: &vP),
				  let vName = readString(from: vPayload, offset: &vP),
				  let vParent = readString(from: vPayload, offset: &vP)
			else {
				return nil
			}
			vRecords.append(FileRecord(
				id: vId,
				name: vName,
				parentPath: vParent,
				size: vSize,
				dateCreated: Date(timeIntervalSince1970: vCreated),
				dateModified: Date(timeIntervalSince1970: vModified),
				isDirectory: (vFlags & 0x01) != 0
			))
		}
		return LoadResult(records: vRecords, lastEventId: vLastEventId)
	}

	// ===========================
	// MARK: Binary helpers
	// ===========================

	private static func writeU32(into ioData: inout Data, value: UInt32) {
		var vV = value.littleEndian
		withUnsafeBytes(of: &vV) { ioData.append(contentsOf: $0) }
	}
	private static func writeU64(into ioData: inout Data, value: UInt64) {
		var vV = value.littleEndian
		withUnsafeBytes(of: &vV) { ioData.append(contentsOf: $0) }
	}
	private static func writeI64(into ioData: inout Data, value: Int64) {
		var vV = value.littleEndian
		withUnsafeBytes(of: &vV) { ioData.append(contentsOf: $0) }
	}
	private static func writeF64(into ioData: inout Data, value: Double) {
		var vV = value.bitPattern.littleEndian
		withUnsafeBytes(of: &vV) { ioData.append(contentsOf: $0) }
	}
	private static func writeString(into ioData: inout Data, value: String) {
		let vBytes = Array(value.utf8)
		writeU32(into: &ioData, value: UInt32(vBytes.count))
		ioData.append(contentsOf: vBytes)
	}
	private static func readU8(from inData: Data, offset: inout Int) -> UInt8? {
		guard offset + 1 <= inData.count else { return nil }
		let vV = inData[inData.startIndex + offset]
		offset += 1
		return vV
	}
	private static func readU32(from inData: Data, offset: inout Int) -> UInt32? {
		guard offset + 4 <= inData.count else { return nil }
		let vV = inData.withUnsafeBytes { (vPtr: UnsafeRawBufferPointer) -> UInt32 in
			vPtr.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
		}
		offset += 4
		return vV
	}
	private static func readU64(from inData: Data, offset: inout Int) -> UInt64? {
		guard offset + 8 <= inData.count else { return nil }
		let vV = inData.withUnsafeBytes { (vPtr: UnsafeRawBufferPointer) -> UInt64 in
			vPtr.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian
		}
		offset += 8
		return vV
	}
	private static func readI64(from inData: Data, offset: inout Int) -> Int64? {
		guard offset + 8 <= inData.count else { return nil }
		let vV = inData.withUnsafeBytes { (vPtr: UnsafeRawBufferPointer) -> Int64 in
			vPtr.loadUnaligned(fromByteOffset: offset, as: Int64.self).littleEndian
		}
		offset += 8
		return vV
	}
	private static func readF64(from inData: Data, offset: inout Int) -> Double? {
		guard let vBits = readU64(from: inData, offset: &offset) else { return nil }
		return Double(bitPattern: vBits)
	}
	private static func readString(from inData: Data, offset: inout Int) -> String? {
		guard let vLen = readU32(from: inData, offset: &offset) else { return nil }
		let vLength = Int(vLen)
		guard offset + vLength <= inData.count else { return nil }
		let vStart = inData.startIndex + offset
		let vEnd = vStart + vLength
		let vSlice = inData[vStart..<vEnd]
		offset += vLength
		return String(data: vSlice, encoding: .utf8)
	}
}
