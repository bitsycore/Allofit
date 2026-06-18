import SwiftUI
import AppKit

// ContentView is the main window layout: a search bar bonded to the title
// bar via `.background(.bar)` (Liquid Glass on macOS 26, vibrant material
// on macOS 15), a results table on the left, a Quick Look preview pane on
// the right (toggleable via the toolbar), and a status bar at the bottom.
struct ContentView: View {

	@EnvironmentObject var model: AppModel
	@EnvironmentObject var prefs: Preferences
	@EnvironmentObject var access: AccessManager
	// per-window search model: owns this window's query + filtered slice so
	// two windows can run independent searches against the shared AppModel
	@EnvironmentObject var searchModel: WindowSearchModel
	@State private var selection: Set<FileRecord.ID> = []
	// drives the Table's drag-to-reorder and column-visibility customization.
	// Initial value is hydrated from UserDefaults so the user's column order
	// survives app launches; subsequent changes flow back via .onChange.
	@State private var columnCustomization: TableColumnCustomization<FileRecord> = ContentView.loadColumnCustomization()
	// debounced background save task for columnCustomization changes.
	// Cancelled+rescheduled per change so a drag (which fires onChange on
	// every micro-update) only runs JSONEncoder once, off-main.
	@State private var columnSaveTask: Task<Void, Never>?
	// whether the right-hand preview pane is currently visible. Persisted
	// across launches so the user's pane-visibility preference sticks.
	@AppStorage("Allofit.showPreviewPane") private var showPreviewPane: Bool = true

	private nonisolated static let kColumnCustomizationKey = "Allofit.columnCustomization"
	private nonisolated static let kColumnSaveDebounceNanos: UInt64 = 300_000_000

	// Computed binding for the Table's sortOrder: reads/writes the
	// per-window searchModel.sortDescriptor so clicking a column header
	// only re-sorts this window. The last-clicked sort is mirrored into
	// Preferences so a fresh window opens with the most recent choice.
	private var sortOrderBinding: Binding<[KeyPathComparator<FileRecord>]> {
		Binding(
			get: { [Self.comparatorFor(inDescriptor: searchModel.sortDescriptor)] },
			set: { vNewOrder in
				guard let vFirst = vNewOrder.first else { return }
				let vDescriptor = Self.mapSortOrder(inComparator: vFirst)
				// defer one runloop tick so we don't write back into the
				// model while NSTableView is still in its sort delegate
				// callback (avoids the reentrant-operation AppKit warning)
				DispatchQueue.main.async {
					searchModel.sortDescriptor = vDescriptor
				}
			}
		)
	}

	var body: some View {
		Group {
			if showPreviewPane {
				HSplitView {
					mainColumn
						.layoutPriority(1)
						.frame(minWidth: 460)
					PreviewPane(selection: selection)
						.frame(minWidth: 200, idealWidth: 360)
				}
			} else {
				mainColumn
			}
		}
		.toolbar {
			ToolbarItem(placement: .primaryAction) {
				Button {
					showPreviewPane.toggle()
				} label: {
					Image(systemName: showPreviewPane
						  ? "sidebar.right"
						  : "sidebar.squares.right")
				}
				.help(showPreviewPane ? "Hide preview" : "Show preview")
			}
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

	// search bar + table + status bar - everything except the preview pane
	private var mainColumn: some View {
		VStack(spacing: 0) {
			searchBar
			resultsTable
			Divider()
			StatusBarView()  // isolated so its @Published refresh
							 // doesn't re-evaluate the Table closure
		}
	}

	// ===========================
	// MARK: Column customization persistence
	// ===========================

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

	private nonisolated static func saveColumnCustomization(_ inValue: TableColumnCustomization<FileRecord>) {
		guard let vData = try? JSONEncoder().encode(inValue) else { return }
		UserDefaults.standard.set(vData, forKey: kColumnCustomizationKey)
	}

	// ===========================
	// MARK: Search bar
	// ===========================

	private var searchBar: some View {
		SearchField(
			text: $searchModel.query,
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
		// Uses the explicit `rows:` form of Table so `.draggable` lives on
		// TableRow rather than embedded in cell content. Cell-content
		// draggable installs a SwiftUI drag-gesture recognizer that races
		// with NSTableView's mouseDown→selection event on macOS 26 and
		// occasionally eats left-clicks; row-level draggable doesn't.
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
						.help(vRecord.name)
					// When the preview pane is closed, surface the
					// elevate-permission affordance on the selected row
					// itself so the user has a way to authorize without
					// having to open the pane first. needsAuthorization
					// is a stat() call so we only invoke it for the row
					// that's actually selected.
					if !showPreviewPane,
					   selection.count == 1,
					   selection.contains(vRecord.id),
					   access.needsAuthorization(for: vRecord) {
						Spacer(minLength: 4)
						// pass access explicitly: Table cells live in
						// detached NSHostingViews that don't reliably
						// inherit @EnvironmentObject, which was the cause
						// of repeated EnvironmentObject.error() crashes
						AuthorizeBadge(access: access, record: vRecord)
					}
				}
			}
			.width(min: 200, ideal: 320)
			.customizationID("name")

			TableColumn("Path", value: \FileRecord.parentPath) { vRecord in
				Text(vRecord.parentPath)
					.foregroundColor(.secondary)
					.truncationMode(.middle)
					.lineLimit(1)
					.help(vRecord.parentPath)
			}
			.width(min: 200, ideal: 380)
			.customizationID("path")

			TableColumn("Size", value: \FileRecord.size) { vRecord in
				Text(vRecord.isDirectory ? "—" : Formatters.size(bytes: vRecord.size))
					.foregroundColor(.secondary)
					.monospacedDigit()
			}
			.width(90)
			.customizationID("size")

			TableColumn("Created", value: \FileRecord.dateCreated) { vRecord in
				Text(Formatters.date(vRecord.dateCreated))
					.foregroundColor(.secondary)
					.monospacedDigit()
			}
			.width(140)
			.customizationID("created")

			TableColumn("Modified", value: \FileRecord.dateModified) { vRecord in
				Text(Formatters.date(vRecord.dateModified))
					.foregroundColor(.secondary)
					.monospacedDigit()
			}
			.width(140)
			.customizationID("modified")
		} rows: {
			ForEach(searchModel.visibleRecords) { vRecord in
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
		// Finder-style spacebar Quick Look. .onKeyPress only fires when the
		// view (Table) has keyboard focus, so spaces typed into the search
		// field still produce literal spaces in the query.
		.onKeyPress(.space) {
			guard !selection.isEmpty else { return .ignored }
			let vUrls = recordsFor(inIds: selection)
				.map { URL(fileURLWithPath: $0.fullPath) }
			QuickLookCoordinator.shared.show(inUrls: vUrls)
			return .handled
		}
	}

	// ===========================
	// MARK: Selection actions
	// ===========================

	private func revealSelection(inIds: Set<FileRecord.ID>) {
		// reveal in Finder shows the *original* file (not the staged copy),
		// since the user wants to navigate to the real location on disk
		let vUrls = recordsFor(inIds: inIds).map { URL(fileURLWithPath: $0.fullPath) }
		NSWorkspace.shared.activateFileViewerSelecting(vUrls)
	}

	private func quickLookSelection(inIds: Set<FileRecord.ID>) {
		// prefer the staged URL when one exists - QLPreviewPanel renders
		// it without permission issues, whereas the original would fail
		let vUrls = recordsFor(inIds: inIds).map { access.effectiveURL(for: $0) }
		QuickLookCoordinator.shared.show(inUrls: vUrls)
	}

	private func copyPaths(inIds: Set<FileRecord.ID>) {
		// always copy the original path - the staged tmp path is an
		// implementation detail that has no meaning outside this session
		let vPaths = recordsFor(inIds: inIds).map { $0.fullPath }
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(vPaths.joined(separator: "\n"), forType: .string)
	}

	private func openSelection(inIds: Set<FileRecord.ID>) {
		// open the staged copy when available so the default app can read
		// it; falls back to the original path for files we can read directly
		for vRecord in recordsFor(inIds: inIds) {
			NSWorkspace.shared.open(access.effectiveURL(for: vRecord))
		}
	}

	private func recordsFor(inIds: Set<FileRecord.ID>) -> [FileRecord] {
		return searchModel.visibleRecords.filter { inIds.contains($0.id) }
	}

	// ===========================
	// MARK: Sort mapping
	// ===========================

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
}

// ===========================
// MARK: Status bar
// ===========================

// Extracted into its own View so its @Published-driven refreshes (cache
// load progress, indexed count changes during a scan, service-mode flip)
// only re-evaluate this small leaf view rather than the ContentView body
// that contains the Table.
private struct StatusBarView: View {

	@EnvironmentObject var model: AppModel
	@EnvironmentObject var prefs: Preferences
	@EnvironmentObject var searchModel: WindowSearchModel

	var body: some View {
		HStack(spacing: 8) {
			if model.isIndexing {
				ProgressView()
					.controlSize(.small)
				Text("Indexing…  \(model.indexedCount) entries")
			} else {
				Text("\(searchModel.visibleRecords.count) shown  ·  \(model.indexedCount) indexed")
			}
			Spacer()
			Text(model.isIndexer ? "Indexer" : "Reader")
				.foregroundColor(.secondary)
			switch prefs.serviceMode {
				case .none: EmptyView()
				case .userAgent: Text("· User service").foregroundColor(.secondary)
				case .rootDaemon: Text("· Root service").foregroundColor(.secondary)
			}
			if !searchModel.query.isEmpty {
				Text("· Filtered").foregroundColor(.secondary)
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 4)
		.font(.caption)
		.foregroundColor(.secondary)
	}
}
