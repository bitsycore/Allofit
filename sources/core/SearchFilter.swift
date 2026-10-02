import Foundation

// SearchFilter is the category menu next to the search field (Everything's
// Filters dropdown). Each filter is an extra query clause ANDed with what the
// user typed, written in the regular search syntax.
enum SearchFilter: String, CaseIterable, Identifiable, Sendable {
	case everything, folders, documents, pictures, audio, video, archives, applications, code

	var id: String { rawValue }

	// menu label
	var title: String {
		switch self {
			case .everything: return "Everything"
			case .folders: return "Folders"
			case .documents: return "Documents"
			case .pictures: return "Pictures"
			case .audio: return "Audio"
			case .video: return "Video"
			case .archives: return "Archives"
			case .applications: return "Applications"
			case .code: return "Code"
		}
	}

	// SF Symbol shown in the menu
	var symbolName: String {
		switch self {
			case .everything: return "square.grid.2x2"
			case .folders: return "folder"
			case .documents: return "doc.text"
			case .pictures: return "photo"
			case .audio: return "music.note"
			case .video: return "film"
			case .archives: return "archivebox"
			case .applications: return "app"
			case .code: return "chevron.left.forwardslash.chevron.right"
		}
	}

	// query clause added to the user's query; nil for no restriction
	var clause: String? {
		switch self {
			case .everything:
				return nil
			case .folders:
				return "folder:"
			case .documents:
				return Self.extClause(["pdf", "doc", "docx", "odt", "rtf", "txt", "md", "pages", "key", "numbers",
									   "xls", "xlsx", "ods", "ppt", "pptx", "odp", "csv", "epub"])
			case .pictures:
				return Self.extClause(["jpg", "jpeg", "png", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp",
									   "svg", "raw", "cr2", "cr3", "nef", "arw", "dng", "psd", "ai", "ico", "icns"])
			case .audio:
				return Self.extClause(["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "ogg", "opus", "wma",
									   "caf", "mid", "midi"])
			case .video:
				return Self.extClause(["mp4", "m4v", "mov", "avi", "mkv", "webm", "wmv", "flv", "mpg", "mpeg", "3gp"])
			case .archives:
				return Self.extClause(["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "dmg", "iso",
									   "pkg", "jar", "apk", "aab", "xip"])
			case .applications:
				return "folder:ext:app"
			case .code:
				return Self.extClause(["swift", "c", "h", "m", "mm", "cpp", "hpp", "cc", "java", "kt", "kts", "js",
									   "mjs", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "php", "cs", "sh", "zsh",
									   "json", "yaml", "yml", "toml", "xml", "html", "css", "scss", "gradle", "sql"])
		}
	}

	// the user's query with this filter's clause appended
	func apply(toQuery inQuery: String) -> String {
		guard let vClause = clause else { return inQuery }
		return inQuery + " " + vClause
	}

	// "ext:a;b;c" for a list of extensions
	private static func extClause(_ inExtensions: [String]) -> String {
		return "ext:" + inExtensions.joined(separator: ";")
	}
}
