import AppKit
import Quartz

// QuickLookCoordinator drives the system-wide QLPreviewPanel for the current
// selection. It acts as both data source and delegate for the panel, which is
// itself a process-wide singleton.
final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {

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

	func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
		return urls.count
	}

	func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
		return urls[index] as NSURL
	}
}
