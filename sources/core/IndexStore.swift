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
		// pure path computation (no disk access: it's called from views);
		// saveImpl creates the folder when it writes
		return vBase
			.appendingPathComponent("Allofit", isDirectory: true)
			.appendingPathComponent("index.bin")
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
	static func save(inRecords: some Collection<FileRecord>, inLastEventId: UInt64) {
		save(inRecords: inRecords, inLastEventId: inLastEventId, to: cacheURL)
	}

	// writes the records and event id atomically to a specific URL.
	// Wrapped in autoreleasepool because every call autoreleases a number
	// of Foundation objects (the compressed NSData, NSURLs created by
	// FileManager.replaceItem, etc.) - if the caller is a long-running
	// block whose own pool never drains, those would accumulate forever.
	static func save(inRecords: some Collection<FileRecord>, inLastEventId: UInt64, to inUrl: URL) {
		autoreleasepool {
			saveImpl(inRecords: inRecords, inLastEventId: inLastEventId, to: inUrl)
		}
	}

	// encodes, LZ4-compresses and atomically writes the cache (body of save)
	private static func saveImpl(inRecords: some Collection<FileRecord>, inLastEventId: UInt64, to inUrl: URL) {
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

		// the folder may not exist yet (first save). The system-wide one must
		// stay traversable by the GUI user; the index inside is owner-only
		// (see restrictAccess)
		let vDir = inUrl.deletingLastPathComponent()
		try? FileManager.default.createDirectory(at: vDir, withIntermediateDirectories: true)
		if getuid() == 0 {
			chmod(vDir.path, 0o755)
		}
		// unique per save: two saves running at once (reindex and autosave
		// on different queues) must not write the same temp file
		let vTmp = inUrl.deletingLastPathComponent()
			.appendingPathComponent(".\(inUrl.lastPathComponent).\(UUID().uuidString).tmp")
		do {
			try vEnvelope.write(to: vTmp)
			// owner-only access, set on the temp file *before* it becomes
			// the cache, so the index (a listing of every file name) is
			// never readable by other local users, even for a moment
			restrictAccess(inPath: vTmp.path)
			// rename(2) is atomic and keeps the temp file's owner and mode
			// (FileManager.replaceItem may carry over the old file's)
			guard rename(vTmp.path, inUrl.path) == 0 else {
				throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
			}
		} catch {
			NSLog("[Allofit] cache save failed at %@: %@", inUrl.path, "\(error)")
			try? FileManager.default.removeItem(at: vTmp)
		}
	}

	// makes a cache file readable by its owner only. The root daemon hands
	// it to the user who installed the service (the GUI reads it as that
	// user); everyone else gets nothing.
	private static func restrictAccess(inPath: String) {
		if getuid() == 0,
		   let vOwner = ProcessInfo.processInfo.environment["ALLOFIT_OWNER_USER"],
		   let vEntry = getpwnam(vOwner) {
			chown(inPath, vEntry.pointee.pw_uid, vEntry.pointee.pw_gid)
		}
		chmod(inPath, 0o600)
	}

	// largest uncompressed payload accepted from a cache file (a corrupt or
	// crafted header must not make the loader allocate without bound)
	private static let kMaxPayloadBytes: UInt64 = 8 << 30

	// reads the persisted index back from the default cacheURL
	static func load() -> LoadResult? {
		return load(from: cacheURL)
	}

	// reads the persisted index back from a specific URL. Wrapped in
	// autoreleasepool so the decompressed NSData and the per-record
	// String allocations don't linger in the caller's pool.
	static func load(from inUrl: URL) -> LoadResult? {
		return autoreleasepool {
			loadImpl(from: inUrl)
		}
	}

	// reads, decompresses and decodes the cache (body of load)
	private static func loadImpl(from inUrl: URL) -> LoadResult? {
		guard let vData = try? Data(contentsOf: inUrl) else { return nil }
		var vOffset = 0
		guard let vMagic = readU32(from: vData, offset: &vOffset), vMagic == kMagic else { return nil }
		guard let vVersion = readU32(from: vData, offset: &vOffset), vVersion == kVersion else { return nil }
		guard let vDeclaredSize = readU64(from: vData, offset: &vOffset),
			  vDeclaredSize <= kMaxPayloadBytes else { return nil }

		let vCompressed = vData.subdata(in: vOffset..<vData.count)
		let vPayload: Data
		do {
			vPayload = try (vCompressed as NSData).decompressed(using: .lz4) as Data
		} catch {
			NSLog("[Allofit] LZ4 decompression failed: \(error)")
			return nil
		}
		guard UInt64(vPayload.count) == vDeclaredSize else { return nil }

		var vP = 0
		guard let vLastEventId = readU64(from: vPayload, offset: &vP) else { return nil }
		guard let vCount = readU64(from: vPayload, offset: &vP) else { return nil }
		// each record takes at least 41 bytes - rejects a corrupt count
		// before it turns into a huge reserveCapacity
		guard vCount <= UInt64(vPayload.count / 41) else { return nil }
		var vRecords: [FileRecord] = []
		vRecords.reserveCapacity(Int(vCount))
		// siblings share one parentPath buffer instead of one copy each
		let vInterner = PathInterner()
		for _ in 0..<Int(vCount) {
			// the stored id is ignored: ids are recomputed from the path so
			// caches written with the old per-launch random hash still load
			guard let _ = readU64(from: vPayload, offset: &vP),
				  let vSize = readI64(from: vPayload, offset: &vP),
				  let vCreated = readF64(from: vPayload, offset: &vP),
				  let vModified = readF64(from: vPayload, offset: &vP),
				  let vFlags = readU8(from: vPayload, offset: &vP),
				  let vName = readString(from: vPayload, offset: &vP),
				  let vParent = readString(from: vPayload, offset: &vP)
			else {
				return nil
			}
			let vShared = vInterner.intern(vParent)
			vRecords.append(FileRecord(
				name: vName,
				parentPath: vShared.path,
				parentLower: vShared.folded,
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

	// appends a little-endian UInt32
	private static func writeU32(into ioData: inout Data, value inValue: UInt32) {
		var vV = inValue.littleEndian
		withUnsafeBytes(of: &vV) { ioData.append(contentsOf: $0) }
	}

	// appends a little-endian UInt64
	private static func writeU64(into ioData: inout Data, value inValue: UInt64) {
		var vV = inValue.littleEndian
		withUnsafeBytes(of: &vV) { ioData.append(contentsOf: $0) }
	}

	// appends a little-endian Int64
	private static func writeI64(into ioData: inout Data, value inValue: Int64) {
		var vV = inValue.littleEndian
		withUnsafeBytes(of: &vV) { ioData.append(contentsOf: $0) }
	}

	// appends a Double as its little-endian bit pattern
	private static func writeF64(into ioData: inout Data, value inValue: Double) {
		var vV = inValue.bitPattern.littleEndian
		withUnsafeBytes(of: &vV) { ioData.append(contentsOf: $0) }
	}

	// appends a UInt32 byte length followed by the UTF-8 bytes
	private static func writeString(into ioData: inout Data, value inValue: String) {
		let vBytes = Array(inValue.utf8)
		writeU32(into: &ioData, value: UInt32(vBytes.count))
		ioData.append(contentsOf: vBytes)
	}

	// reads one byte at ioOffset and advances it; nil past the end
	private static func readU8(from inData: Data, offset ioOffset: inout Int) -> UInt8? {
		guard ioOffset + 1 <= inData.count else { return nil }
		let vV = inData[inData.startIndex + ioOffset]
		ioOffset += 1
		return vV
	}

	// reads a little-endian UInt32 at ioOffset and advances it
	private static func readU32(from inData: Data, offset ioOffset: inout Int) -> UInt32? {
		guard ioOffset + 4 <= inData.count else { return nil }
		let vOffset = ioOffset
		let vV = inData.withUnsafeBytes { (vPtr: UnsafeRawBufferPointer) -> UInt32 in
			vPtr.loadUnaligned(fromByteOffset: vOffset, as: UInt32.self).littleEndian
		}
		ioOffset += 4
		return vV
	}

	// reads a little-endian UInt64 at ioOffset and advances it
	private static func readU64(from inData: Data, offset ioOffset: inout Int) -> UInt64? {
		guard ioOffset + 8 <= inData.count else { return nil }
		let vOffset = ioOffset
		let vV = inData.withUnsafeBytes { (vPtr: UnsafeRawBufferPointer) -> UInt64 in
			vPtr.loadUnaligned(fromByteOffset: vOffset, as: UInt64.self).littleEndian
		}
		ioOffset += 8
		return vV
	}

	// reads a little-endian Int64 at ioOffset and advances it
	private static func readI64(from inData: Data, offset ioOffset: inout Int) -> Int64? {
		guard ioOffset + 8 <= inData.count else { return nil }
		let vOffset = ioOffset
		let vV = inData.withUnsafeBytes { (vPtr: UnsafeRawBufferPointer) -> Int64 in
			vPtr.loadUnaligned(fromByteOffset: vOffset, as: Int64.self).littleEndian
		}
		ioOffset += 8
		return vV
	}

	// reads a Double stored as its little-endian bit pattern
	private static func readF64(from inData: Data, offset ioOffset: inout Int) -> Double? {
		guard let vBits = readU64(from: inData, offset: &ioOffset) else { return nil }
		return Double(bitPattern: vBits)
	}

	// reads a UInt32-length-prefixed UTF-8 string and advances ioOffset
	private static func readString(from inData: Data, offset ioOffset: inout Int) -> String? {
		guard let vLen = readU32(from: inData, offset: &ioOffset) else { return nil }
		let vLength = Int(vLen)
		guard ioOffset + vLength <= inData.count else { return nil }
		let vStart = ioOffset
		ioOffset += vLength
		// native decode (no Foundation bridging); invalid bytes are repaired
		return inData.withUnsafeBytes { vPtr in
			String(decoding: vPtr[vStart..<(vStart + vLength)], as: UTF8.self)
		}
	}
}
