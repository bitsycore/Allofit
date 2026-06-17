import Foundation

// FileRecord stores the minimum metadata needed to display and search a single
// filesystem entry. Keeping only names and small fixed-size fields lets the
// in-memory index scale to hundreds of thousands of entries.
struct FileRecord: Identifiable, Hashable {

	// stable identifier used for SwiftUI list diffing
	let id: UInt64
	// last path component (file or directory name)
	let name: String
	// parent directory absolute path
	let parentPath: String
	// size in bytes (0 for directories)
	let size: Int64
	// creation timestamp
	let dateCreated: Date
	// last modification timestamp
	let dateModified: Date
	// true if this entry is a directory
	let isDirectory: Bool
	// lowercased name cached once for case-insensitive substring matching
	let nameLower: String

	init(id: UInt64,
		 name: String,
		 parentPath: String,
		 size: Int64,
		 dateCreated: Date,
		 dateModified: Date,
		 isDirectory: Bool) {
		self.id = id
		self.name = name
		self.parentPath = parentPath
		self.size = size
		self.dateCreated = dateCreated
		self.dateModified = dateModified
		self.isDirectory = isDirectory
		self.nameLower = name.lowercased()
	}

	// returns the absolute full path computed from parent and name
	var fullPath: String {
		if parentPath.isEmpty { return name }
		if parentPath == "/" { return "/" + name }
		return parentPath + "/" + name
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
