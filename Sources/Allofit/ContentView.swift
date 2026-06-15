import SwiftUI
import AppKit

// ContentView is the main window layout: a search bar bonded to the title
// bar via `.background(.bar)` (Liquid Glass on macOS 26, vibrant material
// on macOS 15), a results table that fills the body, and a status bar at
// the bottom. The Settings gear sits permanently in the window toolbar.
struct ContentView: View {

	@EnvironmentObject var model: AppModel
	@EnvironmentObject var prefs: Preferences
	@State private var selection: Set<FileRecord.ID> = []
	// drives the Table's drag-to-reorder and column-visibility customization.
	// Initial value is hydrated from UserDefaults so the user's column order
	// survives app launches; subsequent changes flow back via .onChange.
	@State private var columnCustomization: TableColumnCustomization<FileRecord> = ContentView.loadColumnCustomization()
	// debounced background save task for columnCustomization changes.
	// Cancelled+rescheduled per change so a drag (which fires onChange on
	// every micro-update) only runs JSONEncoder once, off-main.
	@State private var columnSaveTask: Task<Void, Never>?

	private nonisolated static let kColumnCustomizationKey = "Allofit.columnCustomization"
	private nonisolated static let kColumnSaveDebounceNanos: UInt64 = 300_000_000

	// Computed binding for the Table's sortOrder: reads/writes
	// model.sortDescriptor directly so the sort state survives any number
	// of window closes / reopens (the previous `@State sortOrder` got
	// reset whenever the view was recreated, and the onChange-syncing
	// dance occasionally didn't re-wire properly after a window reopen).
	private var sortOrderBinding: Binding<[KeyPathComparator<FileRecord>]> {
		Binding(
			get: { [Self.comparatorFor(inDescriptor: model.sortDescriptor)] },
			set: { vNewOrder in
				guard let vFirst = vNewOrder.first else { return }
				let vDescriptor = Self.mapSortOrder(inComparator: vFirst)
				// defer one runloop tick so we don't write back into the
				// model while NSTableView is still in its sort delegate
				// callback (avoids the reentrant-operation AppKit warning)
				DispatchQueue.main.async {
					model.sortDescriptor = vDescriptor
				}
			}
		)
	}

	var body: some View {
		VStack(spacing: 0) {
			searchBar
			resultsTable
			Divider()
			StatusBarView()  // isolated so its @Published refresh
							 // doesn't re-evaluate the Table closure
		}
		.toolbar {
			ToolbarItem(placement: .primaryAction) {
				SettingsLink {
					Image(systemName: "gearshape")
				}
				.help("Preferences (⌘,)")
			}
		}
		.onAppear {
			model.start()
		}
		.onDisappear {
			model.saveCache()
		}
		.onChange(of: columnCustomization) { _, vNew in
			// Debounced + off-main save. SwiftUI fires onChange on every
			// micro-update during a column drag - encoding synchronously
			// on main here would freeze the drag delegate. Cancel any
			// pending task and reschedule so we encode at most once per
			// drag (300 ms after the user lets go).
			columnSaveTask?.cancel()
			columnSaveTask = Task.detached(priority: .utility) {
				try? await Task.sleep(nanoseconds: Self.kColumnSaveDebounceNanos)
				if Task.isCancelled { return }
				ContentView.saveColumnCustomization(vNew)
			}
		}
	}

	// ===========================
	// MARK: Column customization persistence
	// ===========================

	// loads the previously-saved column order/visibility from UserDefaults,
	// or returns a fresh default if nothing was saved or decoding fails
	private static func loadColumnCustomization() -> TableColumnCustomization<FileRecord> {
		guard let vData = UserDefaults.standard.data(forKey: kColumnCustomizationKey),
			  let vCustom = try? JSONDecoder().decode(
				TableColumnCustomization<FileRecord>.self,
				from: vData
			  )
		else {
			return TableColumnCustomization<FileRecord>()
		}
		return vCustom
	}

	// persists the current column order/visibility to UserDefaults.
	// nonisolated so the debounced background task can call it without an
	// actor hop - the encode is the only non-trivial step and we want it
	// genuinely off-main during column drags.
	private nonisolated static func saveColumnCustomization(_ inValue: TableColumnCustomization<FileRecord>) {
		guard let vData = try? JSONEncoder().encode(inValue) else { return }
		UserDefaults.standard.set(vData, forKey: kColumnCustomizationKey)
	}

	// ===========================
	// MARK: Search bar
	// ===========================

	// Always-visible row at the top. `.background(.bar)` uses the system
	// "bar" material, which sits right below the toolbar with the same
	// vibrancy treatment - on macOS 26 this is the Liquid Glass surface,
	// on macOS 15 it's the standard chrome material.
	private var searchBar: some View {
		SearchField(
			text: $model.query,
			placeholder: "Search files…  e.g.  Start*.pdf  ·  *.png | *.jpg",
			initiallyFirstResponder: true
		)
		.frame(minHeight: 24)
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
		.background(.bar)
	}

	// ===========================
	// MARK: Results table
	// ===========================

	private var resultsTable: some View {
		// Uses the explicit `rows:` form of Table so we can attach `.draggable`
		// to TableRow rather than to cell content. Putting `.draggable` on
		// cell content installs a SwiftUI drag-gesture recognizer that
		// competes with NSTableView's mouseDown → selection event on
		// macOS 26 - the recognizer's "should this be a drag?" decision
		// delays and occasionally eats the click, leaving the row never
		// selected even though right-click (which bypasses the drag gesture
		// entirely) still works. Row-level `.draggable` puts the drag at
		// the same scope as NSTableView's own row-drag machinery and leaves
		// the click path clean.
		Table(of: FileRecord.self,
			  selection: $selection,
			  sortOrder: sortOrderBinding,
			  columnCustomization: $columnCustomization) {
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
			}
			.width(min: 200, ideal: 320)
			.customizationID("name")

			TableColumn("Path", value: \FileRecord.parentPath) { vRecord in
				Text(vRecord.parentPath)
					.foregroundColor(.secondary)
					.truncationMode(.middle)
					.lineLimit(1)
			}
			.width(min: 200, ideal: 380)
			.customizationID("path")

			TableColumn("Size", value: \FileRecord.size) { vRecord in
				Text(vRecord.isDirectory ? "—" : Self.formatSize(inBytes: vRecord.size))
					.foregroundColor(.secondary)
					.monospacedDigit()
			}
			.width(90)
			.customizationID("size")

			TableColumn("Created", value: \FileRecord.dateCreated) { vRecord in
				Text(Self.formatDate(inDate: vRecord.dateCreated))
					.foregroundColor(.secondary)
					.monospacedDigit()
			}
			.width(140)
			.customizationID("created")

			TableColumn("Modified", value: \FileRecord.dateModified) { vRecord in
				Text(Self.formatDate(inDate: vRecord.dateModified))
					.foregroundColor(.secondary)
					.monospacedDigit()
			}
			.width(140)
			.customizationID("modified")
		} rows: {
			ForEach(model.visibleRecords) { vRecord in
				TableRow(vRecord)
					.draggable(URL(fileURLWithPath: vRecord.fullPath))
			}
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

	fileprivate static func formatSize(inBytes: Int64) -> String {
		return kSizeFormatter.string(fromByteCount: inBytes)
	}

	private static let kDateFormatter: DateFormatter = {
		let vF = DateFormatter()
		vF.dateStyle = .short
		vF.timeStyle = .short
		return vF
	}()

	fileprivate static func formatDate(inDate: Date) -> String {
		if inDate.timeIntervalSince1970 < 1 { return "—" }
		return kDateFormatter.string(from: inDate)
	}
}

// ===========================
// MARK: Status bar
// ===========================

// Extracted into its own View so its @Published-driven refreshes (cache
// load progress, indexed count changes during a scan, service-mode flip)
// only re-evaluate this small view rather than the ContentView body that
// contains the Table. SwiftUI's dependency tracking is per-View, so an
// isolated leaf observer doesn't churn the Table's closure scope.
private struct StatusBarView: View {

	@EnvironmentObject var model: AppModel
	@EnvironmentObject var prefs: Preferences

	var body: some View {
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
}
