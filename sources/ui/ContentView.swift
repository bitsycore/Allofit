import SwiftUI
import AppKit

// ContentView is the main window layout: a search bar bonded to the title
// bar via `.background(.bar)` (Liquid Glass on macOS 26, vibrant material
// on macOS 15), a results table on the left, a Quick Look preview pane on
// the right (toggleable via the toolbar), and a status bar at the bottom.
struct ContentView: View {

	// AppModel is intentionally not observed here: its counters change on
	// every index update and would re-evaluate this body (and the Table)
	// each time. StatusBarView observes it instead.
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
			// isolated so its refreshes don't re-evaluate the Table closure
			StatusBarView(stats: searchModel.stats, selectionText: selectionSummary)
		}
	}

	// ===========================
	// MARK: Column customization persistence
	// ===========================

	// restores the saved column order / visibility
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

	// persists the column order / visibility
	private nonisolated static func saveColumnCustomization(_ inValue: TableColumnCustomization<FileRecord>) {
		guard let vData = try? JSONEncoder().encode(inValue) else { return }
		UserDefaults.standard.set(vData, forKey: kColumnCustomizationKey)
	}

	// ===========================
	// MARK: Search bar
	// ===========================

	private var searchBar: some View {
		HStack(spacing: 8) {
			SearchField(
				text: $searchModel.query,
				placeholder: "Search files…  e.g.  Start*.pdf  ·  *.png | *.jpg",
				initiallyFirstResponder: true
			)
			.frame(minHeight: 24)
			// Everything-style category filter, ANDed with the query
			Picker("Filter", selection: $searchModel.filter) {
				ForEach(SearchFilter.allCases) { vFilter in
					Label(vFilter.title, systemImage: vFilter.symbolName).tag(vFilter)
				}
			}
			.labelsHidden()
			.pickerStyle(.menu)
			.fixedSize()
			.help("Show only one kind of item")
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
		.background(.bar)
	}

	// ===========================
	// MARK: Results table
	// ===========================

	private var resultsTable: some View {
		// Uses the explicit `rows:` form of Table so the drag source lives on
		// TableRow rather than embedded in cell content. Cell-content
		// drag modifiers install a SwiftUI drag-gesture recognizer that
		// races with NSTableView's mouseDown→selection event on macOS 26 and
		// occasionally eats left-clicks; row-level dragging doesn't.
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
					Text(nameText(for: vRecord))
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
				Text(pathText(for: vRecord))
					.foregroundColor(.secondary)
					.truncationMode(.middle)
					.lineLimit(1)
					.help(vRecord.parentPath)
			}
			.width(min: 200, ideal: 380)
			.customizationID("path")

			TableColumn("Size", value: \FileRecord.size) { vRecord in
				Text(vRecord.isDirectory ? "-" : Formatters.size(bytes: vRecord.size))
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
					// drag the file itself, like Finder (see fileDragProvider)
					.itemProvider {
						ContentView.fileDragProvider(for: vRecord)
					}
			}
		}
		.contextMenu(forSelectionType: FileRecord.ID.self) { vIds in
			Button("Open") { openSelection(inIds: vIds) }
			openWithMenu(inIds: vIds)
			Button("Reveal in Finder") { revealSelection(inIds: vIds) }
			Button("Quick Look") { quickLookSelection(inIds: vIds) }
			Divider()
			Button("Copy") { copyFiles(inIds: vIds) }
			Button("Copy Name") { copyNames(inIds: vIds) }
			Button("Copy Path") { copyPaths(inIds: vIds) }
			Divider()
			Button("Move to Trash") { trashSelection(inIds: vIds) }
		} primaryAction: { vIds in
			runPrimaryAction(inIds: vIds)
		}
		// ⌘C on the table copies the files themselves (like Finder); in the
		// search field ⌘C keeps copying text
		.onCopyCommand {
			recordsFor(inIds: selection).map { ContentView.fileDragProvider(for: $0) }
		}
		// Finder-style shortcuts, active while the table has focus
		.onKeyPress(phases: .down) { vPress in
			handleTableKey(inPress: vPress)
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

	// item provider for dragging a record out of the table. Built from the
	// NSURL object so AppKit writes it to the drag pasteboard the way Finder
	// does (public.file-url): browsers then upload the file and apps import
	// it. .draggable(URL) and NSItemProvider(contentsOf:) only exported a
	// link / plain text, which makes browsers open the file in place of the
	// current page.
	static func fileDragProvider(for inRecord: FileRecord) -> NSItemProvider {
		let vProvider = NSItemProvider(object: URL(fileURLWithPath: inRecord.fullPath) as NSURL)
		vProvider.suggestedName = inRecord.name
		return vProvider
	}

	// ===========================
	// MARK: Highlighting
	// ===========================

	// the name with the matched parts in bold (when enabled in Settings)
	private func nameText(for inRecord: FileRecord) -> AttributedString {
		guard prefs.highlightMatches else { return AttributedString(inRecord.name) }
		return Highlighter.attributed(inRecord.name, inTerms: searchModel.highlights.name)
	}

	// the folder with the matched parts of path terms in bold
	private func pathText(for inRecord: FileRecord) -> AttributedString {
		guard prefs.highlightMatches else { return AttributedString(inRecord.parentPath) }
		return Highlighter.attributed(inRecord.parentPath, inTerms: searchModel.highlights.path)
	}

	// ===========================
	// MARK: Keyboard
	// ===========================

	// Finder-style shortcuts for the table: Return runs the primary action,
	// ⌘Return reveals, ⌘Y previews, ⌥⌘C copies paths, ⌘⌫ moves to Trash
	private func handleTableKey(inPress: KeyPress) -> KeyPress.Result {
		guard !selection.isEmpty else { return .ignored }
		let vMods = inPress.modifiers.intersection([.command, .option, .shift, .control])
		switch (inPress.key, vMods) {
			case (.return, []):
				runPrimaryAction(inIds: selection)
			case (.return, [.command]):
				revealSelection(inIds: selection)
			case (KeyEquivalent("y"), [.command]):
				quickLookSelection(inIds: selection)
			case (KeyEquivalent("c"), [.command, .option]):
				copyPaths(inIds: selection)
			case (.delete, [.command]):
				trashSelection(inIds: selection)
			default:
				return .ignored
		}
		return .handled
	}

	// "3 selected (12 MB)" for the status bar, nil without a selection
	private var selectionSummary: String? {
		guard !selection.isEmpty else { return nil }
		let vRecords = recordsFor(inIds: selection)
		let vBytes = vRecords.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.size }
		let vCount = "\(vRecords.count.formatted()) selected"
		return vBytes > 0 ? "\(vCount) (\(Formatters.size(bytes: vBytes)))" : vCount
	}

	// ===========================
	// MARK: Selection actions
	// ===========================

	// reveals the selected files in Finder
	private func revealSelection(inIds: Set<FileRecord.ID>) {
		// reveal in Finder shows the *original* file (not the staged copy),
		// since the user wants to navigate to the real location on disk
		let vUrls = recordsFor(inIds: inIds).map { URL(fileURLWithPath: $0.fullPath) }
		NSWorkspace.shared.activateFileViewerSelecting(vUrls)
	}

	// opens the selected files in the Quick Look panel
	private func quickLookSelection(inIds: Set<FileRecord.ID>) {
		// prefer the staged URL when one exists - QLPreviewPanel renders
		// it without permission issues, whereas the original would fail
		let vUrls = recordsFor(inIds: inIds).map { access.effectiveURL(for: $0) }
		QuickLookCoordinator.shared.show(inUrls: vUrls)
	}

	// copies the selected paths, one per line
	private func copyPaths(inIds: Set<FileRecord.ID>) {
		// always copy the original path - the staged tmp path is an
		// implementation detail that has no meaning outside this session
		let vPaths = recordsFor(inIds: inIds).map { $0.fullPath }
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(vPaths.joined(separator: "\n"), forType: .string)
	}

	// double-click / Return: open or reveal, as chosen in Settings
	private func runPrimaryAction(inIds: Set<FileRecord.ID>) {
		switch prefs.primaryAction {
			case .open: openSelection(inIds: inIds)
			case .reveal: revealSelection(inIds: inIds)
		}
	}

	// "Open With" submenu listing the apps that can open the first selected
	// file, default app first
	@ViewBuilder
	private func openWithMenu(inIds: Set<FileRecord.ID>) -> some View {
		if let vFirst = recordsFor(inIds: inIds).first {
			let vUrl = URL(fileURLWithPath: vFirst.fullPath)
			let vDefault = NSWorkspace.shared.urlForApplication(toOpen: vUrl)
			let vApps = [vDefault].compactMap { $0 }
				+ NSWorkspace.shared.urlsForApplications(toOpen: vUrl).filter { $0 != vDefault }
			Menu("Open With") {
				ForEach(vApps, id: \.self) { vApp in
					Button(FileManager.default.displayName(atPath: vApp.path) + (vApp == vDefault ? " (default)" : "")) {
						openSelection(inIds: inIds, withApp: vApp)
					}
				}
			}
			.disabled(vApps.isEmpty)
		}
	}

	// opens the selected files with a specific app
	private func openSelection(inIds: Set<FileRecord.ID>, withApp inApp: URL) {
		let vUrls = recordsFor(inIds: inIds).map { access.effectiveURL(for: $0) }
		NSWorkspace.shared.open(vUrls, withApplicationAt: inApp, configuration: NSWorkspace.OpenConfiguration())
	}

	// copies the selected files themselves (paste in Finder copies them)
	private func copyFiles(inIds: Set<FileRecord.ID>) {
		let vUrls = recordsFor(inIds: inIds).map { URL(fileURLWithPath: $0.fullPath) as NSURL }
		NSPasteboard.general.clearContents()
		NSPasteboard.general.writeObjects(vUrls)
	}

	// copies the selected names, one per line
	private func copyNames(inIds: Set<FileRecord.ID>) {
		let vNames = recordsFor(inIds: inIds).map { $0.name }
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(vNames.joined(separator: "\n"), forType: .string)
	}

	// moves the selected files to the Trash and drops their rows at once
	private func trashSelection(inIds: Set<FileRecord.ID>) {
		let vRecords = recordsFor(inIds: inIds)
		let vUrls = vRecords.map { URL(fileURLWithPath: $0.fullPath) }
		NSWorkspace.shared.recycle(vUrls) { vTrashed, _ in
			let vGone = Set(vRecords.filter { vTrashed[URL(fileURLWithPath: $0.fullPath)] != nil }.map(\.id))
			guard !vGone.isEmpty else { return }
			DispatchQueue.main.async {
				searchModel.removeVisible(inIds: vGone)
				selection.subtract(vGone)
			}
		}
	}

	// opens the selected files with their default app
	private func openSelection(inIds: Set<FileRecord.ID>) {
		// open the staged copy when available so the default app can read
		// it; falls back to the original path for files we can read directly
		for vRecord in recordsFor(inIds: inIds) {
			NSWorkspace.shared.open(access.effectiveURL(for: vRecord))
		}
	}

	// visible records with the given ids
	private func recordsFor(inIds: Set<FileRecord.ID>) -> [FileRecord] {
		return searchModel.visibleRecords.filter { inIds.contains($0.id) }
	}

	// ===========================
	// MARK: Sort mapping
	// ===========================

	// converts a Table sort comparator into a sort mode
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

	// converts a sort mode into a Table sort comparator
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
// load progress, indexed count changes during a scan, service-mode flip,
// the resource sampler's 2-second tick) only re-evaluate this small leaf
// view rather than the ContentView body that contains the Table.
private struct StatusBarView: View {

	@EnvironmentObject var model: AppModel
	@EnvironmentObject var prefs: Preferences
	@EnvironmentObject var searchModel: WindowSearchModel
	// per-window match count and search time
	@ObservedObject var stats: SearchStats
	// "3 selected (12 MB)", nil without a selection
	let selectionText: String?
	// process memory / CPU sampler shared by all windows
	@ObservedObject private var process = ProcessStats.shared

	// CPU use above which the figure is highlighted (100 = one core)
	private let kBusyCpuPercent: Double = 50

	var body: some View {
		HStack(spacing: 8) {
			if model.isLoadingCache {
				ProgressView()
					.controlSize(.small)
				Text("Loading index…")
			} else if model.isIndexing {
				ProgressView()
					.controlSize(.small)
				Text("Indexing…  \(model.indexedCount.formatted()) entries")
			} else {
				Text(resultsText)
				if let vSelection = selectionText {
					Text("·")
					Text(vSelection)
				}
			}
			Spacer()
			HStack(spacing: 6) {
				Text(String(format: "%.0f ms", stats.lastSearchMilliseconds))
				Text("·")
				Text("RAM \(Formatters.memory(bytes: process.footprintBytes))")
				Text("·")
				Text(String(format: "CPU %.0f%%", process.cpuPercent))
					.foregroundColor(process.cpuPercent >= kBusyCpuPercent ? .orange : .secondary)
				Text("·")
				Text(roleText)
			}
			.monospacedDigit()
			.help(detailsText)
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 4)
		.font(.caption)
		.foregroundColor(.secondary)
	}

	// "N results" plus how many are listed when the list is capped
	private var resultsText: String {
		let vMatches = stats.matchCount
		let vShown = searchModel.visibleRecords.count
		let vIndexed = model.indexedCount.formatted()
		if vShown < vMatches {
			return "\(vMatches.formatted()) results (first \(vShown.formatted()) listed)  ·  \(vIndexed) indexed"
		}
		return "\(vMatches.formatted()) results  ·  \(vIndexed) indexed"
	}

	// indexer / reader role, plus the service kind when one is used
	private var roleText: String {
		let vRole = model.isIndexer ? "Indexer" : "Reader"
		switch prefs.serviceMode {
			case .none: return vRole
			case .userAgent: return vRole + " · User service"
			case .rootDaemon: return vRole + " · Root service"
		}
	}

	// multi-line tooltip with the full set of figures
	private var detailsText: String {
		let vCacheBytes = IndexStore.cacheFileSize(at: IndexStore.cacheURL(forServiceMode: prefs.serviceMode))
		let vUpdated = model.lastIndexChangeAt.map { $0.formatted(.relative(presentation: .named)) } ?? "never"
		let vLines = [
			"Memory: \(Formatters.memory(bytes: process.footprintBytes)) (peak \(Formatters.memory(bytes: process.peakFootprintBytes)))",
			String(format: "CPU: %.1f%% (100%% = one core)", process.cpuPercent) + "  ·  \(process.threadCount) threads",
			String(format: "Last search: %.1f ms over ", stats.lastSearchMilliseconds) + "\(model.indexedCount.formatted()) entries",
			"Index updated: \(vUpdated)",
			"Cache on disk: \(Formatters.sizeOrDash(bytes: vCacheBytes))",
			"Roots: \(prefs.rootPaths.count)  ·  Role: \(roleText)"
		]
		return vLines.joined(separator: "\n")
	}
}
