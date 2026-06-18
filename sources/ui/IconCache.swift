import AppKit
import UniformTypeIdentifiers

// IconCache returns NSImage icons keyed by file extension (or "_dir" for
// directories). The previous code called NSWorkspace.shared.icon(forFile:)
// per row, which stat's the file and inspects .app bundle Info.plist - that
// is what was driving the beachball and the NSTableView reentrance warnings
// when rendering thousands of rows.
//
// NSWorkspace.shared.icon(for: UTType) is a pure in-memory lookup keyed by
// uniform type identifier, so once the per-extension icon is cached the row
// renderer touches no filesystem at all.
enum IconCache {

	// extension (lowercased) or sentinel key -> cached icon
	// nonisolated(unsafe) because all access is serialized through the lock
	// below - Swift's static-isolation check can't see that, so we vouch.
	nonisolated(unsafe) private static var cache: [String: NSImage] = [:]
	// guard for cache access (Table renderers may run on multiple threads)
	private static let lock = NSLock()

	// returns the icon for a file or directory with the given name
	static func icon(forName inName: String, isDirectory inIsDir: Bool) -> NSImage {
		let vKey: String
		if inIsDir {
			vKey = "_dir"
		} else {
			let vExt = (inName as NSString).pathExtension.lowercased()
			vKey = vExt.isEmpty ? "_file" : vExt
		}

		lock.lock()
		if let vCached = cache[vKey] {
			lock.unlock()
			return vCached
		}
		lock.unlock()

		let vIcon: NSImage
		if inIsDir {
			vIcon = NSWorkspace.shared.icon(for: .folder)
		} else if vKey == "_file" {
			vIcon = NSWorkspace.shared.icon(for: .data)
		} else if let vType = UTType(filenameExtension: vKey) {
			vIcon = NSWorkspace.shared.icon(for: vType)
		} else {
			vIcon = NSWorkspace.shared.icon(for: .data)
		}

		lock.lock()
		cache[vKey] = vIcon
		lock.unlock()
		return vIcon
	}
}
