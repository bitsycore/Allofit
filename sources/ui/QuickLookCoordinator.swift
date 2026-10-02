import AppKit
import Quartz

// QuickLookCoordinator drives the system-wide QLPreviewPanel for the current
// selection. It acts as both data source and delegate for the panel, which is
// itself a process-wide singleton.
@MainActor
final class QuickLookCoordinator: NSObject, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {

	// singleton because QLPreviewPanel is itself a singleton
	static let shared = QuickLookCoordinator()

	// urls currently being previewed
	private var urls: [URL] = []

	// presents the Quick Look panel for the given URLs
	func show(inUrls: [URL]) {
		guard !inUrls.isEmpty else { return }
		urls = inUrls
		guard let vPanel = QLPreviewPanel.shared() else { return }
		vPanel.dataSource = self
		vPanel.delegate = self
		vPanel.reloadData()
		vPanel.makeKeyAndOrderFront(nil)
	}

	// ===========================
	// MARK: QLPreviewPanelDataSource
	// ===========================

	// number of files shown by the panel
	func numberOfPreviewItems(in inPanel: QLPreviewPanel!) -> Int {
		return urls.count
	}

	// file shown at the given panel position
	func previewPanel(_ inPanel: QLPreviewPanel!, previewItemAt inIndex: Int) -> QLPreviewItem! {
		return urls[inIndex] as NSURL
	}
}
