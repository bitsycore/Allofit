import SwiftUI
import AppKit
import Quartz

// QuickLookPreviewView wraps Quartz's QLPreviewView so an inline Quick
// Look preview can be embedded inside a SwiftUI hierarchy. The same
// renderer powers the floating QLPreviewPanel (spacebar), so file-type
// coverage (PDFs, images, video, source files, plists, etc.) is
// identical between the inline pane and the floating panel.
struct QuickLookPreviewView: NSViewRepresentable {

	// the file to preview; nil clears the view
	let url: URL?

	func makeNSView(context: Context) -> NSView {
		guard let vView = QLPreviewView(frame: .zero, style: .normal) else {
			return NSView()
		}
		// keep the view alive when the parent window closes - we own its
		// lifetime via SwiftUI, not via QLPreviewPanel's modal behaviour
		vView.shouldCloseWithWindow = false
		vView.autostarts = true
		return vView
	}

	func updateNSView(_ nsView: NSView, context: Context) {
		guard let vQlView = nsView as? QLPreviewView else { return }
		vQlView.previewItem = (url as NSURL?)
	}
}

// AuthorizeBadge is the small lock icon that appears either inside the
// preview pane (when the selected file isn't user-readable) or at the
// right of the selected row when the preview pane is closed. Clicking
// it kicks off the sudo cp + chown via AdminShell - the system prompts
// for the password the first time inside the admin-auth-cache window.
struct AuthorizeBadge: View {

	@EnvironmentObject var access: AccessManager
	let record: FileRecord

	var body: some View {
		Button {
			Task { await access.authorize(record) }
		} label: {
			if access.isAuthorizing(record.id) {
				ProgressView()
					.controlSize(.small)
					.frame(width: 16, height: 16)
			} else {
				Image(systemName: "lock.shield.fill")
					.foregroundStyle(.orange)
					.font(.system(size: 14, weight: .semibold))
			}
		}
		.buttonStyle(.plain)
		.disabled(access.isAuthorizing(record.id))
		.help(access.isAuthorizing(record.id)
			  ? "Authorizing…"
			  : "Authorize to read this file")
	}
}

// PreviewPane is the right-hand side panel in the main window. When
// exactly one row is selected it renders a Quick Look preview plus a
// small metadata footer. If the file isn't user-readable the preview
// area becomes a single big tap-target showing a lock icon - clicking
// it (or the badge that appears on the selected row when the pane is
// closed) triggers the sudo-elevation flow.
struct PreviewPane: View {

	@EnvironmentObject var model: AppModel
	@EnvironmentObject var access: AccessManager
	// passed in from ContentView (its @State) so this view re-renders
	// whenever the user's selection changes
	let selection: Set<FileRecord.ID>

	private var selectedRecord: FileRecord? {
		guard selection.count == 1, let vId = selection.first else { return nil }
		return model.visibleRecords.first(where: { $0.id == vId })
	}

	var body: some View {
		VStack(spacing: 0) {
			if let vRecord = selectedRecord {
				content(for: vRecord)
			} else {
				emptyState
			}
		}
		.background(Color(NSColor.controlBackgroundColor))
	}

	// preview + metadata footer for one selected record
	private func content(for inRecord: FileRecord) -> some View {
		let vEffectiveUrl = access.effectiveURL(for: inRecord)
		let vReadable = ElevatedAccess.canRead(path: vEffectiveUrl.path)
		return VStack(spacing: 0) {
			Group {
				if vReadable {
					QuickLookPreviewView(url: vEffectiveUrl)
				} else {
					authorizePrompt(for: inRecord)
				}
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)

			Divider()
			metadata(for: inRecord)
		}
	}

	// full-area authorize hint shown when the selected file isn't
	// user-readable. The whole area is the button target so users
	// can click anywhere over the locked preview to authorize.
	private func authorizePrompt(for inRecord: FileRecord) -> some View {
		Button {
			Task { await access.authorize(inRecord) }
		} label: {
			VStack(spacing: 10) {
				if access.isAuthorizing(inRecord.id) {
					ProgressView()
						.controlSize(.regular)
				} else {
					Image(systemName: "lock.shield.fill")
						.font(.system(size: 40))
						.foregroundStyle(.orange)
				}
				Text(access.isAuthorizing(inRecord.id)
					 ? "Authorizing…"
					 : "Click to authorize preview")
					.font(.callout)
					.foregroundColor(.secondary)
				if let vErr = access.lastError, !access.isAuthorizing(inRecord.id) {
					Text(vErr)
						.font(.caption)
						.foregroundColor(.red)
						.multilineTextAlignment(.center)
						.padding(.horizontal, 20)
				}
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.disabled(access.isAuthorizing(inRecord.id))
	}

	// thin metadata bar at the bottom of the preview pane
	private func metadata(for inRecord: FileRecord) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(inRecord.name)
				.font(.headline)
				.lineLimit(2)
				.truncationMode(.middle)
			Text(inRecord.parentPath)
				.font(.caption)
				.foregroundColor(.secondary)
				.truncationMode(.middle)
				.lineLimit(1)
				.textSelection(.enabled)
			HStack(spacing: 6) {
				if !inRecord.isDirectory {
					Text(Formatters.size(bytes: inRecord.size))
						.monospacedDigit()
					Text("·")
				}
				Text("Modified \(Formatters.date(inRecord.dateModified))")
					.monospacedDigit()
			}
			.font(.caption)
			.foregroundColor(.secondary)
		}
		.padding(12)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(.bar)
	}

	// placeholder shown when nothing or multiple rows are selected
	private var emptyState: some View {
		VStack(spacing: 10) {
			Image(systemName: "eye.slash")
				.font(.system(size: 32))
				.foregroundColor(.secondary.opacity(0.6))
			Text(placeholderText)
				.font(.callout)
				.foregroundColor(.secondary)
				.multilineTextAlignment(.center)
				.padding(.horizontal, 16)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	private var placeholderText: String {
		if selection.isEmpty {
			return "Select a file to preview"
		}
		return "\(selection.count) items selected"
	}
}
