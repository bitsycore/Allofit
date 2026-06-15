import Foundation
import SwiftUI

// AccessManager holds the in-memory mapping from FileRecord.ID to the
// staged user-readable copy produced by an "Authorize" tap. Both the
// Table (which shows a lock badge on the selected row when the preview
// pane is closed) and the PreviewPane (which gates the QLPreviewView
// behind the same badge) observe this so the badge disappears and the
// preview switches to the staged URL as soon as the sudo copy lands.
//
// All published mutations happen on the main actor; the actual sudo cp
// runs inside a Task.detached spawned by `authorize(_:)` so the AppleScript
// password prompt doesn't block the main runloop.
@MainActor
final class AccessManager: ObservableObject {

	// id -> URL of the user-readable copy in ~/Library/Caches/Allofit/elevated
	@Published private(set) var stagedURLs: [FileRecord.ID: URL] = [:]
	// ids currently being authorized (admin script in flight); used to
	// render a small spinner inside the lock badge
	@Published private(set) var authorizingIds: Set<FileRecord.ID> = []
	// most recent authorization error (cancelled prompt, sudo failure,
	// etc); surfaced as the badge's accessibility / tooltip text
	@Published private(set) var lastError: String?

	// returns the URL to use when previewing / opening the file: the
	// staged copy if we have one, otherwise the original path
	func effectiveURL(for inRecord: FileRecord) -> URL {
		if let vStaged = stagedURLs[inRecord.id] {
			return vStaged
		}
		return URL(fileURLWithPath: inRecord.fullPath)
	}

	// true if the effective URL (staged or original) isn't readable by
	// the current user - this is what drives the lock-badge visibility
	func needsAuthorization(for inRecord: FileRecord) -> Bool {
		let vUrl = effectiveURL(for: inRecord)
		return !ElevatedAccess.canRead(path: vUrl.path)
	}

	// true while an authorize task is in flight for the given record id
	func isAuthorizing(_ inId: FileRecord.ID) -> Bool {
		return authorizingIds.contains(inId)
	}

	// runs the sudo cp + chown flow for one record. The first call inside
	// the system's admin-auth-cache window (~5 min) prompts for the
	// password; subsequent calls within that window are silent.
	func authorize(_ inRecord: FileRecord) async {
		let vId = inRecord.id
		// idempotency: a double-tap on the badge shouldn't kick off two
		// concurrent admin scripts for the same file
		guard !authorizingIds.contains(vId) else { return }
		authorizingIds.insert(vId)
		lastError = nil
		let vOriginalUrl = URL(fileURLWithPath: inRecord.fullPath)
		do {
			// Task.detached so the synchronous NSAppleScript admin prompt
			// runs on a background thread; the prompt itself is shown on
			// main by AppKit regardless of where we invoke it from
			let vStaged = try await Task.detached(priority: .userInitiated) {
				try ElevatedAccess.stage(vOriginalUrl)
			}.value
			stagedURLs[vId] = vStaged
		} catch {
			lastError = error.localizedDescription
		}
		authorizingIds.remove(vId)
	}

	// wipes the in-memory mapping. Called after ElevatedAccess.cleanup()
	// removes the on-disk files so the two stay consistent.
	func reset() {
		stagedURLs.removeAll()
		authorizingIds.removeAll()
		lastError = nil
	}
}
