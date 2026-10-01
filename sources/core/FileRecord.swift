import Foundation

// FileRecord stores the minimum metadata needed to display and search a single
// filesystem entry. Keeping only names and small fixed-size fields lets the
// in-memory index scale to hundreds of thousands of entries.
struct FileRecord: Identifiable, Hashable, Sendable {

	// stable identifier derived from the absolute path (see pathHash). Also
	// the key of IndexState's lookup table, and the SwiftUI row identity -
	// being deterministic, it survives updates and relaunches so the
	// selection doesn't jump when a file changes under it.
	let id: UInt64
	// last path component (file or directory name)
	let name: String
	// parent directory absolute path (interned: siblings share one buffer)
	let parentPath: String
	// size in bytes (0 for directories)
	let size: Int64
	// creation timestamp
	let dateCreated: Date
	// last modification timestamp
	let dateModified: Date
	// true if this entry is a directory
	let isDirectory: Bool
	// lowercased, NFC-normalized name used for case-insensitive matching.
	// Shares the name's storage when the name is already in that form.
	let nameLower: String

	init(name: String,
		 parentPath: String,
		 size: Int64,
		 dateCreated: Date,
		 dateModified: Date,
		 isDirectory: Bool) {
		self.id = FileRecord.pathHash(inParent: parentPath, inName: name)
		self.name = name
		self.parentPath = parentPath
		self.size = size
		self.dateCreated = dateCreated
		self.dateModified = dateModified
		self.isDirectory = isDirectory
		let vLower = FileRecord.searchForm(of: name)
		self.nameLower = (vLower == name) ? name : vLower
	}

	// returns the absolute full path computed from parent and name
	var fullPath: String {
		if parentPath.isEmpty { return name }
		if parentPath == "/" { return "/" + name }
		return parentPath + "/" + name
	}

	// ===========================
	// MARK: Normalization / hashing
	// ===========================

	// lowercases and canonically composes a string so byte-level matching
	// behaves like a case-insensitive, normalization-insensitive compare.
	// Pure-ASCII strings (the vast majority) skip the NFC pass.
	static func searchForm(of inString: String) -> String {
		let vLower = inString.lowercased()
		if vLower.utf8.allSatisfy({ $0 < 0x80 }) { return vLower }
		return vLower.precomposedStringWithCanonicalMapping
	}

	// 64-bit FNV-1a offset basis and prime
	private static let kFnvOffset: UInt64 = 0xcbf2_9ce4_8422_2325
	private static let kFnvPrime: UInt64 = 0x0000_0100_0000_01b3

	// FNV-1a hash of an absolute path's UTF-8 bytes. Deterministic across
	// processes (unlike Hasher, which is randomly seeded per launch).
	// Non-ASCII paths are hashed in composed (NFC) form: APFS accepts both
	// "é" and "e + combining accent" for the same file, and FSEvents and the
	// directory enumerator don't always report the same form.
	static func pathHash(_ inPath: String) -> UInt64 {
		var vHash = kFnvOffset
		if !isASCII(inPath) {
			for vByte in inPath.precomposedStringWithCanonicalMapping.utf8 {
				vHash = (vHash ^ UInt64(vByte)) &* kFnvPrime
			}
			return vHash
		}
		for vByte in inPath.utf8 {
			vHash = (vHash ^ UInt64(vByte)) &* kFnvPrime
		}
		return vHash
	}

	// true when the string is plain ASCII (no normalization ambiguity)
	private static func isASCII(_ inString: String) -> Bool {
		return inString.utf8.allSatisfy { $0 < 0x80 }
	}

	// same value as pathHash(fullPath) but computed from the parent + name
	// without allocating the joined string (ASCII fast path)
	static func pathHash(inParent: String, inName: String) -> UInt64 {
		if inParent.isEmpty { return pathHash(inName) }
		if !isASCII(inParent) || !isASCII(inName) {
			return pathHash(inParent == "/" ? "/" + inName : inParent + "/" + inName)
		}
		var vHash = kFnvOffset
		for vByte in inParent.utf8 {
			vHash = (vHash ^ UInt64(vByte)) &* kFnvPrime
		}
		if inParent != "/" {
			vHash = (vHash ^ UInt64(UInt8(ascii: "/"))) &* kFnvPrime
		}
		for vByte in inName.utf8 {
			vHash = (vHash ^ UInt64(vByte)) &* kFnvPrime
		}
		return vHash
	}
}

// Sort modes for FileRecord lists. Defined at file scope so both Preferences
// (which persists the last choice) and AppModel can reference it without a
// circular dependency.
enum FileSortDescriptor: String, CaseIterable, Identifiable {
	case nameAscending, nameDescending
	case sizeAscending, sizeDescending
	case createdAscending, createdDescending
	case modifiedAscending, modifiedDescending
	case pathAscending, pathDescending
	var id: String { rawValue }
}
