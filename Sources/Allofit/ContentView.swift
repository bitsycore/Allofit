import SwiftUI
import AppKit
import UniformTypeIdentifiers

// ContentView is the main window layout: search bar at the top, a results
// table that mirrors the look of Everything, and a status bar at the bottom.
struct ContentView: View {

	@EnvironmentObject var model: AppModel
	@EnvironmentObject var prefs: Preferences
	@State private var selection: Set<FileRecord.ID> = []
	// SwiftUI Table sort order - clicking a column header updates this
	@State private var sortOrder: [KeyPathComparator<FileRecord>] = [
		KeyPathComparator(\FileRecord.name, order: .forward)
	]

	var body: some View {
		VStack(spacing: 0) {
			searchBar
			Divider()
			resultsTable
			Divider()
			statusBar
		}
		.onAppear {
			// align Table sort order with the persisted sort descriptor
			sortOrder = [Self.comparatorFor(inDescriptor: model.sortDescriptor)]
			model.start()
		}
		.onDisappear {
			model.saveCache()
		}
		.onChange(of: sortOrder) { _, vNew in
			if let vFirst = vNew.first {
				// defer to the next runloop tick so we don't write back into
				// the model while NSTableView is still in its sort delegate
				// callback - that triggers the "reentrant operation in its
				// NSTableView delegate" warning from AppKit
				let vDescriptor = Self.mapSortOrder(inComparator: vFirst)
				DispatchQueue.main.async {
					model.sortDescriptor = vDescriptor
				}
			}
		}
	}

	// ===========================
	// MARK: Search bar
	// ===========================

	private var searchBar: some View {
		HStack(spacing: 8) {
			SearchField(
				text: $model.query,
				placeholder: "Search files…  e.g.  Start*.pdf  ·  *.png | *.jpg",
				initiallyFirstResponder: true
			)
			.frame(minHeight: 28)

			SettingsLink {
				Image(systemName: "gearshape")
			}
			.help("Preferences (⌘,)")
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
	}

	// ===========================
	// MARK: Results table
	// ===========================

	private var resultsTable: some View {
		Table(model.visibleRecords, selection: $selection, sortOrder: $sortOrder) {
			TableColumn("Name", value: \FileRecord.name) { vRecord in
				HStack(spacing: 6) {
					Image(nsImage: IconCache.icon(
						forName: vRecord.name,
						isDirectory: vRecord.isDirectory
					))
					.resizable()
					.frame(width: 16, height: 16)
					Text(vRecord.name)
						.lineLimit(1)
				}
				.draggable(URL(fileURLWithPath: vRecord.fullPath))
			}
			.width(min: 200, ideal: 320)

			TableColumn("Path", value: \FileRecord.parentPath) { vRecord in
				Text(vRecord.parentPath)
					.foregroundColor(.secondary)
					.truncationMode(.middle)
					.lineLimit(1)
			}
			.width(min: 200, ideal: 380)

			TableColumn("Size", value: \FileRecord.size) { vRecord in
				Text(vRecord.isDirectory ? "—" : Self.formatSize(inBytes: vRecord.size))
					.foregroundColor(.secondary)
					.monospacedDigit()
			}
			.width(90)

			TableColumn("Created", value: \FileRecord.dateCreated) { vRecord in
				Text(Self.formatDate(inDate: vRecord.dateCreated))
					.foregroundColor(.secondary)
					.monospacedDigit()
			}
			.width(140)

			TableColumn("Modified", value: \FileRecord.dateModified) { vRecord in
				Text(Self.formatDate(inDate: vRecord.dateModified))
					.foregroundColor(.secondary)
					.monospacedDigit()
			}
			.width(140)
		}
		.contextMenu(forSelectionType: FileRecord.ID.self) { vIds in
			Button("Open") { openSelection(inIds: vIds) }
			Button("Reveal in Finder") { revealSelection(inIds: vIds) }
			Button("Quick Look") { quickLookSelection(inIds: vIds) }
			Divider()
			Button("Copy Path") { copyPaths(inIds: vIds) }
		} primaryAction: { vIds in
			openSelection(inIds: vIds)
		}
	}

	// ===========================
	// MARK: Status bar
	// ===========================

	private var statusBar: some View {
		HStack(spacing: 8) {
			if model.isIndexing {
				ProgressView()
					.controlSize(.small)
				Text("Indexing…  \(model.indexedCount) entries")
			} else {
				Text("\(model.visibleRecords.count) shown  ·  \(model.indexedCount) indexed")
			}
			Spacer()
			Text(model.isIndexer ? "Indexer" : "Reader")
				.foregroundColor(.secondary)
			switch prefs.serviceMode {
				case .none: EmptyView()
				case .userAgent: Text("· User service").foregroundColor(.secondary)
				case .rootDaemon: Text("· Root service").foregroundColor(.secondary)
			}
			if !model.query.isEmpty {
				Text("· Filtered").foregroundColor(.secondary)
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 4)
		.font(.caption)
		.foregroundColor(.secondary)
	}

	// ===========================
	// MARK: Selection actions
	// ===========================

	private func revealSelection(inIds: Set<FileRecord.ID>) {
		let vUrls = recordsFor(inIds: inIds).map { URL(fileURLWithPath: $0.fullPath) }
		NSWorkspace.shared.activateFileViewerSelecting(vUrls)
	}

	private func quickLookSelection(inIds: Set<FileRecord.ID>) {
		let vUrls = recordsFor(inIds: inIds).map { URL(fileURLWithPath: $0.fullPath) }
		QuickLookCoordinator.shared.show(inUrls: vUrls)
	}

	private func copyPaths(inIds: Set<FileRecord.ID>) {
		let vPaths = recordsFor(inIds: inIds).map { $0.fullPath }
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(vPaths.joined(separator: "\n"), forType: .string)
	}

	private func openSelection(inIds: Set<FileRecord.ID>) {
		for vRecord in recordsFor(inIds: inIds) {
			NSWorkspace.shared.open(URL(fileURLWithPath: vRecord.fullPath))
		}
	}

	private func recordsFor(inIds: Set<FileRecord.ID>) -> [FileRecord] {
		return model.visibleRecords.filter { inIds.contains($0.id) }
	}

	// ===========================
	// MARK: Sort mapping
	// ===========================

	// converts a Table sort comparator into the model's FileSortDescriptor
	private static func mapSortOrder(inComparator: KeyPathComparator<FileRecord>) -> FileSortDescriptor {
		let vAsc = inComparator.order == .forward
		let vKp = inComparator.keyPath
		if vKp == \FileRecord.name { return vAsc ? .nameAscending : .nameDescending }
		if vKp == \FileRecord.parentPath { return vAsc ? .pathAscending : .pathDescending }
		if vKp == \FileRecord.size { return vAsc ? .sizeAscending : .sizeDescending }
		if vKp == \FileRecord.dateCreated { return vAsc ? .createdAscending : .createdDescending }
		if vKp == \FileRecord.dateModified { return vAsc ? .modifiedAscending : .modifiedDescending }
		return .nameAscending
	}

	// returns the matching comparator for a given persisted sort descriptor
	private static func comparatorFor(inDescriptor: FileSortDescriptor) -> KeyPathComparator<FileRecord> {
		switch inDescriptor {
			case .nameAscending: return KeyPathComparator(\FileRecord.name, order: .forward)
			case .nameDescending: return KeyPathComparator(\FileRecord.name, order: .reverse)
			case .pathAscending: return KeyPathComparator(\FileRecord.parentPath, order: .forward)
			case .pathDescending: return KeyPathComparator(\FileRecord.parentPath, order: .reverse)
			case .sizeAscending: return KeyPathComparator(\FileRecord.size, order: .forward)
			case .sizeDescending: return KeyPathComparator(\FileRecord.size, order: .reverse)
			case .createdAscending: return KeyPathComparator(\FileRecord.dateCreated, order: .forward)
			case .createdDescending: return KeyPathComparator(\FileRecord.dateCreated, order: .reverse)
			case .modifiedAscending: return KeyPathComparator(\FileRecord.dateModified, order: .forward)
			case .modifiedDescending: return KeyPathComparator(\FileRecord.dateModified, order: .reverse)
		}
	}

	// ===========================
	// MARK: Formatting helpers
	// ===========================

	private static let kSizeFormatter: ByteCountFormatter = {
		let vF = ByteCountFormatter()
		vF.countStyle = .file
		return vF
	}()

	private static func formatSize(inBytes: Int64) -> String {
		return kSizeFormatter.string(fromByteCount: inBytes)
	}

	private static let kDateFormatter: DateFormatter = {
		let vF = DateFormatter()
		vF.dateStyle = .short
		vF.timeStyle = .short
		return vF
	}()

	private static func formatDate(inDate: Date) -> String {
		if inDate.timeIntervalSince1970 < 1 { return "—" }
		return kDateFormatter.string(from: inDate)
	}
}
