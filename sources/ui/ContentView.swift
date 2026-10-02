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
	// selected record ids (shared with the table, preview and status bar)
	@State private var selection: Set<FileRecord.ID> = []
	// whether the right-hand preview pane is currently visible. Persisted
	// across launches so the user's pane-visibility preference sticks.
	@AppStorage("Allofit.showPreviewPane") private var showPreviewPane: Bool = true

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
			perform: { vAction, vIds in perform(inAction: vAction, inIds: vIds) }
		)
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
	// MARK: Actions
	// ===========================

	// runs an action requested by the table (menu, keyboard, double-click)
	private func perform(inAction: ResultAction, inIds: Set<FileRecord.ID>) {
		switch inAction {
			case .primary:
				switch prefs.primaryAction {
					case .open: openSelection(inIds: inIds)
					case .reveal: revealSelection(inIds: inIds)
				}
			case .open: openSelection(inIds: inIds)
			case .openWith(let vApp): openSelection(inIds: inIds, withApp: vApp)
			case .reveal: revealSelection(inIds: inIds)
			case .quickLook: quickLookSelection(inIds: inIds)
			case .copyFiles: copyFiles(inIds: inIds)
			case .copyNames: copyNames(inIds: inIds)
			case .copyPaths: copyPaths(inIds: inIds)
			case .trash: trashSelection(inIds: inIds)
			case .authorize:
				if let vRecord = recordsFor(inIds: inIds).first {
					Task { await access.authorize(vRecord) }
				}
		}
	}

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

	// opens the selected files with a specific app
	private func openSelection(inIds: Set<FileRecord.ID>, withApp inApp: URL) {
		let vUrls = recordsFor(inIds: inIds).map { access.effectiveURL(for: $0) }
		NSWorkspace.shared.open(vUrls, withApplicationAt: inApp, configuration: NSWorkspace.OpenConfiguration())
	}

	// opens the selected files with their default app
	private func openSelection(inIds: Set<FileRecord.ID>) {
		// open the staged copy when available so the default app can read
		// it; falls back to the original path for files we can read directly
		for vRecord in recordsFor(inIds: inIds) {
			NSWorkspace.shared.open(access.effectiveURL(for: vRecord))
		}
	}

	// shown records with the given ids
	private func recordsFor(inIds: Set<FileRecord.ID>) -> [FileRecord] {
		guard !inIds.isEmpty else { return [] }
		return searchModel.results.filter { inIds.contains($0.id) }
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
		return "\(stats.matchCount.formatted()) results  ·  \(model.indexedCount.formatted()) indexed"
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
