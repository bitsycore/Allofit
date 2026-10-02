import SwiftUI
import AppKit

// ContentView is the main window layout: a search bar bonded to the title
// bar via `.background(.bar)` (Liquid Glass on macOS 26, vibrant material
// on macOS 15), the results list on the left, a Quick Look preview pane on
// the right (toggleable via the toolbar), and a status bar at the bottom.
struct ContentView: View {

	// AppModel is intentionally not observed here: its counters change on
	// every index update and would re-evaluate this body each time.
	// StatusBarView observes it instead.
	@EnvironmentObject var prefs: Preferences
	@EnvironmentObject var access: AccessManager
	// per-window search model: owns this window's query + results so two
	// windows can run independent searches against the shared AppModel
	@EnvironmentObject var searchModel: WindowSearchModel
	// selected records, in row order (shared with the table, preview and
	// status bar)
	@State private var selection: [FileRecord] = []
	// window undo stack (Move to Trash can be undone)
	@Environment(\.undoManager) private var undoManager
	// whether the right-hand preview pane is currently visible. Persisted
	// across launches so the user's pane-visibility preference sticks.
	@AppStorage("Allofit.showPreviewPane") private var showPreviewPane: Bool = true
	// search syntax popover
	@State private var showSyntaxHelp = false

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
					// a real label so VoiceOver reads it, shown as an icon
					Label(showPreviewPane ? "Hide Preview" : "Show Preview",
						  systemImage: showPreviewPane ? "sidebar.right" : "sidebar.squares.right")
						.labelStyle(.iconOnly)
				}
				.help(showPreviewPane ? "Hide preview" : "Show preview")
			}
			ToolbarItem(placement: .primaryAction) {
				SettingsLink {
					Label("Settings", systemImage: "gearshape")
						.labelStyle(.iconOnly)
				}
				.help("Settings (⌘,)")
			}
		}
	}

	// search bar + results + status bar - everything except the preview pane
	private var mainColumn: some View {
		VStack(spacing: 0) {
			searchBar
			resultsTable
			Divider()
			// isolated so its refreshes don't re-evaluate this body
			StatusBarView(stats: searchModel.stats, selectionText: selectionSummary)
		}
	}

	// ===========================
	// MARK: Search bar
	// ===========================

	// search field plus the Everything-style category filter
	private var searchBar: some View {
		HStack(spacing: 8) {
			SearchField(
				text: $searchModel.query,
				placeholder: "Search files…  e.g.  Start*.pdf  ·  *.png | *.jpg",
				initiallyFirstResponder: true
			)
			.frame(minHeight: 24)
			// category filter, ANDed with the query
			Picker("Filter", selection: $searchModel.filter) {
				ForEach(SearchFilter.allCases) { vFilter in
					Label(vFilter.title, systemImage: vFilter.symbolName).tag(vFilter)
				}
			}
			.labelsHidden()
			.pickerStyle(.menu)
			.fixedSize()
			.help("Show only one kind of item")
			// search syntax cheat sheet
			Button {
				showSyntaxHelp.toggle()
			} label: {
				Label("Search Syntax", systemImage: "questionmark.circle")
					.labelStyle(.iconOnly)
			}
			.buttonStyle(.borderless)
			.help("Search syntax")
			.popover(isPresented: $showSyntaxHelp, arrowEdge: .bottom) {
				SyntaxHelpView()
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
		.background(.bar)
	}

	// ===========================
	// MARK: Results
	// ===========================

	// native table with every result (see ResultsTable)
	private var resultsTable: some View {
		ResultsTable(
			records: searchModel.results,
			version: searchModel.resultsVersion,
			highlights: searchModel.highlights,
			highlightEnabled: prefs.highlightMatches,
			selection: $selection,
			sort: $searchModel.sortDescriptor,
			needsAuthorization: { vRecord in access.needsAuthorization(for: vRecord) },
			perform: { vAction, vRecords in perform(inAction: vAction, inRecords: vRecords) }
		)
		// explains an empty list (loading, indexing, no match, filter on)
		.overlay {
			EmptyResultsView(stats: searchModel.stats, filter: searchModel.filter, hasQuery: !searchModel.query.isEmpty)
				.allowsHitTesting(false)
		}
	}

	// "3 selected (12 MB)" for the status bar, nil without a selection
	private var selectionSummary: String? {
		guard !selection.isEmpty else { return nil }
		let vBytes = selection.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.size }
		let vCount = "\(selection.count.formatted()) selected"
		return vBytes > 0 ? "\(vCount) (\(Formatters.size(bytes: vBytes)))" : vCount
	}

	// ===========================
	// MARK: Actions
	// ===========================

	// runs an action requested by the table (menu, keyboard, double-click)
	private func perform(inAction: ResultAction, inRecords: [FileRecord]) {
		switch inAction {
			case .primary:
				switch prefs.primaryAction {
					case .open: openRecords(inRecords)
					case .reveal: revealRecords(inRecords)
				}
			case .open: openRecords(inRecords)
			case .openWith(let vApp): openRecords(inRecords, withApp: vApp)
			case .reveal: revealRecords(inRecords)
			case .quickLook:
				// prefer the staged URL when one exists - QLPreviewPanel
				// renders it without permission issues
				QuickLookCoordinator.shared.show(inUrls: inRecords.map { access.effectiveURL(for: $0) })
			case .copyFiles:
				NSPasteboard.general.clearContents()
				NSPasteboard.general.writeObjects(inRecords.map { URL(fileURLWithPath: $0.fullPath) as NSURL })
			case .copyNames:
				copyLines(inRecords.map(\.name))
			case .copyPaths:
				// always the original path - a staged copy's tmp path means
				// nothing outside this session
				copyLines(inRecords.map(\.fullPath))
			case .trash:
				trashRecords(inRecords)
			case .authorize:
				if let vRecord = inRecords.first {
					Task { await access.authorize(vRecord) }
				}
		}
	}

	// reveals the records in Finder (the original files, not staged copies)
	private func revealRecords(_ inRecords: [FileRecord]) {
		NSWorkspace.shared.activateFileViewerSelecting(inRecords.map { URL(fileURLWithPath: $0.fullPath) })
	}

	// puts one string per line on the pasteboard
	private func copyLines(_ inLines: [String]) {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(inLines.joined(separator: "\n"), forType: .string)
	}

	// moves the records to the Trash: their rows go away at once, ⌘Z puts
	// them back, and a failure is reported instead of silently ignored
	private func trashRecords(_ inRecords: [FileRecord]) {
		let vUrls = inRecords.map { URL(fileURLWithPath: $0.fullPath) }
		let vUndo = undoManager
		NSWorkspace.shared.recycle(vUrls) { vTrashed, vError in
			// look the results up with the very URL objects passed in (a
			// folder's URL gains a trailing slash, rebuilt ones wouldn't match)
			var vMoved: [(record: FileRecord, original: URL, trashed: URL)] = []
			for (vRecord, vUrl) in zip(inRecords, vUrls) {
				if let vInTrash = vTrashed[vUrl] {
					vMoved.append((vRecord, vUrl, vInTrash))
				}
			}
			DispatchQueue.main.async {
				if !vMoved.isEmpty {
					searchModel.removeTrashed(inRecords: vMoved.map(\.record))
					let vGone = Set(vMoved.map(\.record.id))
					selection.removeAll { vGone.contains($0.id) }
					registerPutBack(inMoves: vMoved.map { ($0.original, $0.trashed) }, inUndo: vUndo)
				}
				if let vError = vError {
					let vAlert = NSAlert(error: vError)
					vAlert.messageText = vMoved.isEmpty
						? "Couldn't move to the Trash"
						: "Some items couldn't be moved to the Trash"
					vAlert.runModal()
				}
			}
		}
	}

	// registers "Undo Move to Trash": moves the items back and tells the
	// index (the watcher ignores this app's own file operations)
	private func registerPutBack(inMoves: [(original: URL, trashed: URL)], inUndo: UndoManager?) {
		guard let vUndo = inUndo else { return }
		let vModel = searchModel
		vUndo.registerUndo(withTarget: vModel) { vTarget in
			var vRestored: [String] = []
			for vMove in inMoves where (try? FileManager.default.moveItem(at: vMove.trashed, to: vMove.original)) != nil {
				vRestored.append(vMove.original.path)
			}
			vTarget.noticeRestored(inPaths: vRestored)
		}
		vUndo.setActionName(inMoves.count == 1 ? "Move to Trash" : "Move \(inMoves.count) Items to Trash")
	}

	// opens the records with a specific app
	private func openRecords(_ inRecords: [FileRecord], withApp inApp: URL) {
		let vUrls = inRecords.map { access.effectiveURL(for: $0) }
		NSWorkspace.shared.open(vUrls, withApplicationAt: inApp, configuration: NSWorkspace.OpenConfiguration())
	}

	// opens the records with their default app (the staged copy when one
	// exists, so the app can read it)
	private func openRecords(_ inRecords: [FileRecord]) {
		for vRecord in inRecords {
			NSWorkspace.shared.open(access.effectiveURL(for: vRecord))
		}
	}
}

// ===========================
// MARK: Status bar
// ===========================

// Extracted into its own View so its @Published-driven refreshes (cache
// load progress, indexed count changes during a scan, service-mode flip,
// the resource sampler's 2-second tick) only re-evaluate this small leaf
// view rather than the ContentView body that contains the results.
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
	// freeze key state, shown while held
	@ObservedObject private var freeze = FreezeKey.shared

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
			if freeze.isHeld {
				Label("Frozen", systemImage: "snowflake")
					.foregroundColor(.accentColor)
					.help("Holding ⌥ Option pauses list updates; release to catch up")
			}
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

	// "N results · M indexed"
	private var resultsText: String {
		let vCount = stats.matchCount
		return "\(vCount.formatted()) \(vCount == 1 ? "result" : "results")  ·  \(model.indexedCount.formatted()) indexed"
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

// ===========================
// MARK: Empty state
// ===========================

// EmptyResultsView is shown over an empty results list and says why it's
// empty: the index is loading or being built, nothing matches, or a filter
// hides everything. It observes AppModel itself so ContentView doesn't have to.
private struct EmptyResultsView: View {

	@EnvironmentObject var model: AppModel
	// match count of this window
	@ObservedObject var stats: SearchStats
	// active category filter
	let filter: SearchFilter
	// true when something is typed in the search field
	let hasQuery: Bool

	var body: some View {
		if stats.matchCount == 0 {
			VStack(spacing: 8) {
				if model.isLoadingCache {
					ProgressView()
					Text("Loading the index…")
						.font(.headline)
				} else if model.isIndexing {
					ProgressView()
					Text("Building the index…")
						.font(.headline)
					Text("\(model.indexedCount.formatted()) files so far. Results appear as they are found.")
						.font(.callout)
				} else if model.indexedCount == 0 {
					Text("Nothing indexed yet")
						.font(.headline)
					Text("Add folders in Settings > Indexes.")
						.font(.callout)
				} else {
					Text("No results")
						.font(.headline)
					if filter != .everything {
						Text("Only \(filter.title.lowercased()) are shown. Choose Everything in the filter menu to search all items.")
							.font(.callout)
					} else if hasQuery {
						Text("Click ? next to the search field for the search syntax.")
							.font(.callout)
					}
				}
			}
			.foregroundColor(.secondary)
			.multilineTextAlignment(.center)
			.frame(maxWidth: 360)
		}
	}
}
