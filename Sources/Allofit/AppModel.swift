import Foundation
import SwiftUI
import CoreServices

// Background-thread-safe last-seen-mtime cell for the cache-file poll.
// Lets the DispatchSource timer compare a new stat() result against the
// previously seen value without touching any @MainActor state, so the
// poll only hops to main when the cache has actually changed on disk.
private final class BackgroundMtime: @unchecked Sendable {
	private var mtime: Date?
	private let lock = NSLock()

	// returns true if the supplied mtime differs from the stored value
	// (and updates the stored value), false otherwise
	func updateIfChanged(_ inMtime: Date) -> Bool {
		lock.lock()
		defer { lock.unlock() }
		if mtime != inMtime {
			mtime = inMtime
			return true
		}
		return false
	}
}

// AppModel is the central observable state for the application.
// It owns the in-memory file index, drives the background indexer and the
// FSEvents watcher, debounces the search query and exposes a filtered/sorted
// slice of the index to SwiftUI.
//
// Threading rule of thumb: this class is @MainActor so all Published properties
// are written from main. Heavy work (LZ4 (de)compression, filtering, sorting,
// path-lookup rebuilds, filesystem walks) happens on background queues; the
// result is then assigned back on main with DispatchQueue.main.async or
// MainActor.run. Snapshots of value types (Array, String) cross thread
// boundaries via Swift COW semantics, so no defensive copies are needed.
@MainActor
final class AppModel: ObservableObject {

	// the canonical full index of every entry observed so far
	@Published private(set) var allRecords: [FileRecord] = []
	// the filtered, sorted and capped records currently shown in the table
	@Published private(set) var visibleRecords: [FileRecord] = []
	// total number of entries indexed (used for the status bar)
	@Published private(set) var indexedCount: Int = 0
	// true while a full reindex is in progress
	@Published private(set) var isIndexing: Bool = false
	// true while the cache file is being loaded into memory at startup
	@Published private(set) var isLoadingCache: Bool = false
	// true when this process owns the index (got the lock or built-in mode)
	@Published private(set) var isIndexer: Bool = false
	// the user-entered search query, debounced before filtering
	@Published var query: String = "" {
		didSet {
			scheduleSearch()
			prefs.lastQuery = query
		}
	}
	// the active sort descriptor chosen by the user via column headers
	@Published var sortDescriptor: FileSortDescriptor = .nameAscending {
		didSet {
			applyFilterAndSort()
			prefs.lastSort = sortDescriptor
		}
	}

	// maximum number of rows handed to SwiftUI Table for snappy scrolling
	private let kMaxVisibleRows = 5000
	// debounce delay between keystroke and filter rebuild
	private let kSearchDebounceSeconds = 0.05
	// how often the index is written to disk while running (seconds)
	private let kAutosaveSeconds: TimeInterval = 30

	private let prefs = Preferences.shared
	// background queues isolated by concern - keeps the slow stuff off main
	private let indexQueue = DispatchQueue(label: "allofit.index", qos: .utility)
	private let searchQueue = DispatchQueue(label: "allofit.search", qos: .userInitiated)
	private let ioQueue = DispatchQueue(label: "allofit.io", qos: .utility)
	// pending debounced search work, cancelled on each keystroke
	private var searchWorkItem: DispatchWorkItem?
	// pending filter+sort task, cancelled if a newer one supersedes it
	private var filterTask: Task<Void, Never>?
	// watcher used in indexer mode for live updates
	private let watcher = FileWatcher()
	// watcher used in reader mode to detect cache file refreshes
	private let cacheWatcher = FileWatcher()
	// path -> array index, kept in sync with allRecords (main-thread only)
	private var pathIndex: [String: Int] = [:]
	// autosave timer when running in indexer mode
	private var autosaveTimer: Timer?
	// true when allRecords has changed since the last save
	private var dirty = false
	// last FSEvents event id known to be reflected in allRecords
	private var lastEventId: UInt64 = 0
	// process-wide indexer mutex (nil until acquired)
	private var indexerLock: IndexerLock?
	// guards start() from running twice across window close/reopen
	private var hasStarted = false
	// true while a privileged service operation is in flight (Reindex / Clear)
	@Published private(set) var isWorking: Bool = false
	// last user-facing status string for the Settings buttons
	@Published private(set) var workMessage: String = ""
	// polling backup for reader-mode cache changes; FSEvents alone can miss
	// updates if the watched directory didn't exist when the stream started.
	// Uses DispatchSourceTimer on a background queue (not Timer on the main
	// runloop) so the periodic stat() doesn't compete with NSTableView click
	// handling - main-runloop timers were the source of dropped clicks.
	private var cachePollSource: DispatchSourceTimer?
	// last mtime we observed on the cache file - skips needless reloads
	private var lastSeenCacheMtime: Date?
	// minimum gap between two reader-mode reloads. Prevents the Table from
	// being re-rendered while the user is mid-click. 1 second is well below
	// any human-perceptible "stale" threshold but caps the worst-case churn
	// during heavy filesystem activity.
	private let kMinReloadInterval: TimeInterval = 1.0
	// timestamp of the last reloadFromCache() that actually swapped data in
	private var lastReloadAt: Date?

	init() {
		// only the cheap UI state is restored synchronously - the cache file
		// is loaded off-main in start() so the window appears instantly
		query = prefs.lastQuery
		sortDescriptor = prefs.lastSort
	}

	// kicks off background activity for the first time. Subsequent calls are
	// no-ops so we don't double-bootstrap when the user reopens the window.
	// To force a re-bootstrap (e.g. after Install/Uninstall swaps the role),
	// call switchToCurrentMode() instead.
	func start() {
		if hasStarted { return }
		hasStarted = true
		bootstrap()
	}

	// re-runs the mode-detection + cache-load + watcher-setup sequence.
	// Used after the user changes the service installation state so the GUI
	// can hot-swap between indexer and reader without a full app restart.
	func switchToCurrentMode() {
		NSLog("[Allofit GUI] switching mode (serviceMode=%@)", prefs.serviceMode.rawValue)
		bootstrap()
	}

	// stops all watchers/timers and releases the indexer lock, leaving the
	// model ready for a fresh bootstrap()
	private func tearDownActiveMode() {
		watcher.stop()
		cacheWatcher.stop()
		autosaveTimer?.invalidate()
		autosaveTimer = nil
		cachePollSource?.cancel()
		cachePollSource = nil
		indexerLock?.unlock()
		indexerLock = nil
		filterTask?.cancel()
		filterTask = nil
	}

	// determines indexer vs reader role, loads the cache from the appropriate
	// path, and starts the right watcher set. Safe to call repeatedly.
	private func bootstrap() {
		tearDownActiveMode()

		if prefs.serviceMode != .none {
			isIndexer = false
		} else {
			let vLock = IndexerLock(path: IndexStore.lockURL(forSystem: false).path)
			if vLock.tryLock() {
				indexerLock = vLock
				isIndexer = true
			} else {
				isIndexer = false
				NSLog("[Allofit GUI] indexer lock held by another process, running as reader")
			}
		}

		isLoadingCache = true
		let vCacheURL = IndexStore.cacheURL(forServiceMode: prefs.serviceMode)
		NSLog("[Allofit GUI] bootstrap: serviceMode=%@ isIndexer=%@ cacheURL=%@",
			  prefs.serviceMode.rawValue,
			  isIndexer ? "true" : "false",
			  vCacheURL.path)
		ioQueue.async { [weak self] in
			// decompress + parse off-main (this is the expensive part)
			let vCache = IndexStore.load(from: vCacheURL)
			// build the path lookup while we are already off-main
			let vLookup = AppModel.buildPathLookup(inRecords: vCache?.records ?? [])
			DispatchQueue.main.async {
				guard let vSelf = self else { return }
				if let vCache = vCache {
					NSLog("[Allofit GUI] loaded %d records from cache", vCache.records.count)
					vSelf.allRecords = vCache.records
					vSelf.pathIndex = vLookup
					vSelf.indexedCount = vCache.records.count
					vSelf.lastEventId = vCache.lastEventId
				} else {
					NSLog("[Allofit GUI] cache load returned nil (file missing or invalid)")
					vSelf.allRecords = []
					vSelf.pathIndex = [:]
					vSelf.indexedCount = 0
				}
				// capture the initial mtime so the reader-mode poller doesn't
				// immediately re-trigger on its first tick
				if let vAttrs = try? FileManager.default.attributesOfItem(atPath: vCacheURL.path),
				   let vMtime = vAttrs[.modificationDate] as? Date {
					vSelf.lastSeenCacheMtime = vMtime
				} else {
					vSelf.lastSeenCacheMtime = nil
				}
				vSelf.isLoadingCache = false
				vSelf.applyFilterAndSort()
				if vSelf.isIndexer {
					vSelf.startIndexerMode()
				} else {
					vSelf.startReaderMode()
				}
			}
		}
	}

	// manually triggered cache reload; surfaced as a button in the Cache tab
	// so users can verify the GUI reads what the daemon wrote. Bypasses
	// reloadFromCache's rate-limit / same-eventId guards since the user
	// explicitly asked.
	func forceReloadCache() {
		NSLog("[Allofit GUI] manual reload triggered")
		lastReloadAt = nil
		lastEventId = 0
		reloadFromCache()
	}

	// reindexes from scratch on the next idle moment
	func reindex() {
		guard isIndexer, !isIndexing else { return }
		isIndexing = true
		indexedCount = 0
		let vRoots = VolumeManager.effectiveRoots(inPreferences: prefs)
		let vMatcher = ExclusionMatcher(inExclusions: prefs.excludedPaths)
		let vStartId = UInt64(FSEventsGetCurrentEventId())
		indexQueue.async { [weak self] in
			var vAccumulated: [FileRecord] = []
			vAccumulated.reserveCapacity(200_000)
			for vRoot in vRoots {
				let vBaseline = vAccumulated.count
				let vList = FileIndexer.indexRoot(inRoot: vRoot, inExclusions: vMatcher) { vCount in
					DispatchQueue.main.async {
						self?.indexedCount = vBaseline + vCount
					}
				}
				vAccumulated.append(contentsOf: vList)
			}
			let vFinal = vAccumulated
			let vLookup = AppModel.buildPathLookup(inRecords: vFinal)
			// persist off-main before bouncing back so main never sees the
			// LZ4 compression cost
			IndexStore.save(inRecords: vFinal, inLastEventId: vStartId)
			DispatchQueue.main.async {
				self?.applyFreshIndex(inRecords: vFinal, inLookup: vLookup, inEventId: vStartId)
			}
		}
	}

	// dispatches a reindex appropriate for the current mode. In built-in mode
	// it triggers an in-process FileIndexer pass. In service mode it stops
	// the daemon, deletes its cache, and starts the daemon again so the
	// daemon's fresh process performs the scan from scratch. The privileged
	// portion runs on a detached task so the main thread (and the password
	// dialog from NSAppleScript) doesn't freeze the UI.
	func performReindex() async {
		if isIndexer {
			reindex()
			return
		}
		await runPrivilegedAction(inLabel: "Reindexing") { vScope, vUrl in
			try ServiceInstaller.clearCacheAndRestart(inScope: vScope, inCacheURL: vUrl)
		}
	}

	// removes the on-disk cache, with the right privilege escalation per mode.
	// In built-in mode the file is owned by the current user, so a plain
	// removeItem suffices. In service mode the cache may be owned by root and
	// the daemon would re-write it on its next autosave, so we tunnel the
	// delete through the same stop/delete/start admin script.
	func performClearCache() async {
		switch prefs.serviceMode {
			case .none:
				IndexStore.clearCache(at: IndexStore.cacheURL(forServiceMode: .none))
				workMessage = "Cache cleared."
				if isIndexer { reindex() }
			case .userAgent, .rootDaemon:
				await runPrivilegedAction(inLabel: "Clearing cache") { vScope, vUrl in
					try ServiceInstaller.clearCacheAndRestart(inScope: vScope, inCacheURL: vUrl)
				}
		}
	}

	// installs a launchd service for the current serviceMode preference,
	// off-main so the password dialog doesn't freeze the GUI. On success
	// the GUI hot-swaps into reader mode so the user doesn't need to relaunch.
	func performInstallService() async {
		let vOk = await runPrivilegedAction(inLabel: "Installing service") { vScope, _ in
			try ServiceInstaller.install(inScope: vScope)
		}
		if vOk {
			// give launchd a moment to bring the daemon up before we switch
			// the GUI into reader mode and start watching the cache file
			try? await Task.sleep(nanoseconds: 1_500_000_000)
			switchToCurrentMode()
		}
	}

	// uninstalls the launchd service for the current serviceMode preference.
	// On success the GUI hot-swaps back into built-in indexer mode.
	func performUninstallService() async {
		let vOk = await runPrivilegedAction(inLabel: "Uninstalling service") { vScope, _ in
			try ServiceInstaller.uninstall(inScope: vScope)
		}
		if vOk {
			// give launchd a moment to actually tear the daemon down so its
			// indexer lock is released before the GUI tries to grab it
			try? await Task.sleep(nanoseconds: 1_500_000_000)
			switchToCurrentMode()
		}
	}

	// shared helper: runs a service-mode operation on a detached queue while
	// publishing isWorking/workMessage so the UI can show progress. Returns
	// true if the action ran without throwing.
	@discardableResult
	private func runPrivilegedAction(inLabel: String,
									  inBody: @Sendable @escaping (ServiceInstaller.Scope, URL) throws -> Void) async -> Bool {
		let vMode = prefs.serviceMode
		guard vMode != .none else { return false }
		let vScope: ServiceInstaller.Scope = (vMode == .userAgent) ? .userAgent : .rootDaemon
		let vUrl = IndexStore.cacheURL(forServiceMode: vMode)
		// flush UserDefaults so the daemon reads up-to-date settings from
		// our plist after it restarts (cfprefsd can buffer writes for minutes)
		Preferences.flushToDisk()
		isWorking = true
		workMessage = "\(inLabel)…"
		do {
			try await Task.detached(priority: .userInitiated) {
				try inBody(vScope, vUrl)
			}.value
			workMessage = "\(inLabel): done."
			isWorking = false
			return true
		} catch {
			workMessage = "\(inLabel) failed: \(error.localizedDescription)"
			NSLog("[Allofit] %@ failed: %@", inLabel, "\(error)")
			isWorking = false
			return false
		}
	}

	// writes the current index to disk (called on quit and by autosave)
	func saveCache() {
		guard isIndexer else { return }
		// snapshot on main (cheap COW), then dispatch compression off-main
		let vRecords = allRecords
		let vEventId = max(lastEventId, watcher.latestEventId)
		dirty = false
		ioQueue.async {
			IndexStore.save(inRecords: vRecords, inLastEventId: vEventId)
		}
	}

	// ===========================
	// MARK: Indexer mode
	// ===========================

	private func startIndexerMode() {
		if allRecords.isEmpty {
			reindex()
		} else {
			startWatching(inSinceWhen: lastEventId)
		}
		startAutosaveTimer()
	}

	private func startWatching(inSinceWhen: UInt64) {
		let vRoots = VolumeManager.effectiveRoots(inPreferences: prefs)
		watcher.start(
			inRoots: vRoots.map { $0.path },
			inSinceWhen: FSEventStreamEventId(inSinceWhen)
		) { vChanges in
			DispatchQueue.main.async { [weak self] in
				self?.applyFileSystemChanges(inChanges: vChanges)
			}
		}
	}

	private func startAutosaveTimer() {
		autosaveTimer?.invalidate()
		// .common mode so the timer fires even while SwiftUI is busy
		let vTimer = Timer(timeInterval: kAutosaveSeconds, repeats: true) { [weak self] _ in
			Task { @MainActor in
				guard let vSelf = self, vSelf.dirty else { return }
				vSelf.saveCache()
			}
		}
		RunLoop.main.add(vTimer, forMode: .common)
		autosaveTimer = vTimer
	}

	// applies a batch of FSEvents-reported changes. Updates and removals are
	// batched so we rebuild the path lookup once per batch (the per-event
	// rebuild used previously was O(n × removals) on main and also left
	// pathIndex with stale indices between iterations). MustScanSubDirs is
	// handled off-main so a kernel history loss doesn't freeze the UI.
	private func applyFileSystemChanges(inChanges: [FSChange]) {
		let vMatcher = ExclusionMatcher(inExclusions: prefs.excludedPaths)
		var vChanged = false
		var vRescan: [String] = []
		var vRemoved: Set<String> = []

		for vChange in inChanges {
			if vMatcher.isExcluded(inPath: vChange.path) { continue }
			if vChange.mustScanSubDirs {
				vRescan.append(vChange.path)
				continue
			}
			// skip paths we've already queued for removal in this batch
			if vRemoved.contains(vChange.path) { continue }
			let vURL = URL(fileURLWithPath: vChange.path)
			let vExists = (try? vURL.checkResourceIsReachable()) ?? false
			if vExists, let vRecord = FileIndexer.makeRecord(inURL: vURL) {
				if let vIdx = pathIndex[vRecord.fullPath] {
					allRecords[vIdx] = vRecord
				} else {
					allRecords.append(vRecord)
					pathIndex[vRecord.fullPath] = allRecords.count - 1
				}
				vChanged = true
			} else if pathIndex[vChange.path] != nil {
				// defer the actual removal so we can bulk-remove all at once
				// at the end of the batch, then rebuild the lookup once
				vRemoved.insert(vChange.path)
				vChanged = true
			}
		}

		if !vRemoved.isEmpty {
			// one bulk pass over allRecords + one lookup rebuild per batch
			allRecords.removeAll { vRemoved.contains($0.fullPath) }
			rebuildPathLookup()
		}

		if !vRescan.isEmpty {
			kickRescanSubtrees(inPaths: vRescan, inExclusions: vMatcher)
		}

		if vChanged {
			indexedCount = allRecords.count
			lastEventId = watcher.latestEventId
			dirty = true
			scheduleSearch()
		}
	}

	// rebuilds the entries below the given subtrees from the filesystem in
	// the background, then hands the new arrays back to main in one shot
	private func kickRescanSubtrees(inPaths: [String], inExclusions: ExclusionMatcher) {
		let vCurrent = allRecords
		let vPrefixes = inPaths.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
		indexQueue.async { [weak self] in
			var vKept = vCurrent.filter { vRec in
				let vP = vRec.fullPath
				for vPre in vPrefixes where vP == String(vPre.dropLast()) || vP.hasPrefix(vPre) {
					return false
				}
				return true
			}
			for vPath in inPaths {
				let vList = FileIndexer.indexRoot(
					inRoot: URL(fileURLWithPath: vPath),
					inExclusions: inExclusions
				)
				vKept.append(contentsOf: vList)
			}
			let vFinal = vKept
			let vLookup = AppModel.buildPathLookup(inRecords: vFinal)
			DispatchQueue.main.async {
				self?.allRecords = vFinal
				self?.pathIndex = vLookup
				self?.indexedCount = vFinal.count
				self?.dirty = true
				self?.scheduleSearch()
			}
		}
	}

	// rebuilds the path -> array-index dictionary from allRecords. Called
	// synchronously on main after batched removals so the subsequent code
	// sees a consistent pathIndex. One-shot O(n) per FSEvents batch.
	private func rebuildPathLookup() {
		pathIndex = AppModel.buildPathLookup(inRecords: allRecords)
	}

	// ===========================
	// MARK: Reader mode
	// ===========================

	private func startReaderMode() {
		let vUrl = IndexStore.cacheURL(forServiceMode: prefs.serviceMode)
		let vDir = vUrl.deletingLastPathComponent().path
		let vTarget = vUrl.path
		NSLog("[Allofit GUI] reader mode: watching cache at %@", vTarget)
		// FSEvents-based watcher for low-latency updates
		cacheWatcher.start(inRoots: [vDir]) { vChanges in
			if vChanges.contains(where: { $0.path == vTarget || $0.path == vDir }) {
				NSLog("[Allofit GUI] cache file changed (FSEvents), reloading")
				DispatchQueue.main.async { [weak self] in
					self?.reloadFromCache()
				}
			}
		}
		// Background-queue polling backup at 2s. The stat() runs off main,
		// and a lock-guarded background-side mtime tracker means we ONLY
		// hop to main when the cache actually changed - the steady state
		// puts zero work on the main runloop, leaving NSTableView's click
		// handling uninterrupted.
		cachePollSource?.cancel()
		let vPolledPath = vUrl.path
		let vBgMtime = BackgroundMtime()  // captured by the closure
		let vSource = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
		vSource.schedule(deadline: .now() + 2.0, repeating: 2.0)
		vSource.setEventHandler { [weak self] in
			guard let vAttrs = try? FileManager.default.attributesOfItem(atPath: vPolledPath),
				  let vMtime = vAttrs[.modificationDate] as? Date
			else { return }
			// Background-side change detection; only proceeds when mtime moved
			guard vBgMtime.updateIfChanged(vMtime) else { return }
			DispatchQueue.main.async {
				self?.reloadFromCache()
			}
		}
		vSource.resume()
		cachePollSource = vSource
	}

	// stat()'s the cache file and triggers a reload when mtime changes
	private func pollCacheForChanges() {
		let vUrl = IndexStore.cacheURL(forServiceMode: prefs.serviceMode)
		guard let vAttrs = try? FileManager.default.attributesOfItem(atPath: vUrl.path),
			  let vMtime = vAttrs[.modificationDate] as? Date
		else { return }
		if lastSeenCacheMtime != vMtime {
			NSLog("[Allofit GUI] cache mtime changed (poll), reloading")
			lastSeenCacheMtime = vMtime
			reloadFromCache()
		}
	}

	// reloads the on-disk cache off-main and swaps it in atomically.
	//
	// Two guards keep this from disrupting Table interactions:
	//   1. lastEventId comparison - the daemon advances its event id every
	//      time it actually persists new state, so a matching id means the
	//      records on disk are identical to what we have and we can bail
	//      before touching any @Published. This is what was eating clicks:
	//      the daemon resaving an unchanged cache still bumped its mtime,
	//      the poller triggered a reload, and the resulting @Published
	//      cascade re-rendered the Table at the exact moment the user
	//      was clicking a row.
	//   2. A 1-second floor between reloads. Even when changes do happen,
	//      we don't need to re-render the whole list at FSEvents' rate -
	//      the next tick will catch any newer state.
	private func reloadFromCache() {
		let vNow = Date()
		if let vLast = lastReloadAt, vNow.timeIntervalSince(vLast) < kMinReloadInterval {
			return
		}
		lastReloadAt = vNow
		let vUrl = IndexStore.cacheURL(forServiceMode: prefs.serviceMode)
		let vCurrentEventId = lastEventId
		ioQueue.async { [weak self] in
			let vCache = IndexStore.load(from: vUrl)
			// short-circuit when the on-disk content matches what we already
			// have - common when the daemon resaves on a noise-only FSEvents
			// burst (e.g. spotlight reindexing, temp files in /var)
			if let vC = vCache, vC.lastEventId == vCurrentEventId {
				return
			}
			let vLookup = AppModel.buildPathLookup(inRecords: vCache?.records ?? [])
			DispatchQueue.main.async {
				guard let vCache = vCache else { return }
				self?.allRecords = vCache.records
				self?.pathIndex = vLookup
				self?.indexedCount = vCache.records.count
				self?.lastEventId = vCache.lastEventId
				self?.applyFilterAndSort()
			}
		}
	}

	// ===========================
	// MARK: Internals
	// ===========================

	// installs a freshly-built index and refreshes the visible slice
	private func applyFreshIndex(inRecords: [FileRecord],
								  inLookup: [String: Int],
								  inEventId: UInt64) {
		allRecords = inRecords
		pathIndex = inLookup
		indexedCount = inRecords.count
		lastEventId = inEventId
		isIndexing = false
		dirty = false
		applyFilterAndSort()
		if isIndexer {
			startWatching(inSinceWhen: inEventId)
		}
	}

	// debounces filter rebuilds so we don't refilter on every keystroke
	private func scheduleSearch() {
		searchWorkItem?.cancel()
		let vItem = DispatchWorkItem { [weak self] in
			DispatchQueue.main.async {
				self?.applyFilterAndSort()
			}
		}
		searchWorkItem = vItem
		searchQueue.asyncAfter(deadline: .now() + kSearchDebounceSeconds, execute: vItem)
	}

	// runs the actual filter and sort on a detached task so the UI never
	// stalls on keystrokes. The previous task is cancelled to avoid races.
	private func applyFilterAndSort() {
		filterTask?.cancel()
		// snapshot inputs on main; the detached task is self-contained
		let vQuery = query
		let vSort = sortDescriptor
		let vRecords = allRecords
		let vMax = kMaxVisibleRows
		filterTask = Task.detached(priority: .userInitiated) { [weak self] in
			let vEngine = SearchEngine(inQuery: vQuery)
			var vFiltered: [FileRecord]
			if vEngine.isActive {
				vFiltered = vRecords.filter { vEngine.match(inRecord: $0) }
			} else {
				vFiltered = vRecords
			}
			if Task.isCancelled { return }
			AppModel.sortInPlace(inRecords: &vFiltered, inDescriptor: vSort)
			if Task.isCancelled { return }
			let vCapped: [FileRecord]
			if vFiltered.count > vMax {
				vCapped = Array(vFiltered.prefix(vMax))
			} else {
				vCapped = vFiltered
			}
			if Task.isCancelled { return }
			// hop back to main with DispatchQueue.main.async (rather than
			// await MainActor.run) so the assignment is guaranteed to land
			// on the next runloop tick, avoiding NSTableView reentrance when
			// the search field is mid-edit
			DispatchQueue.main.async {
				guard let vSelf = self else { return }
				// Skip the @Published fire when the resulting list is byte-
				// for-byte identical to what the Table is already showing.
				// Full FileRecord equality catches mtime / size updates, so
				// we only skip true no-op reassignments. Clicks landing on
				// the Table during a no-op reload no longer get dropped.
				if vSelf.visibleRecords == vCapped { return }
				vSelf.visibleRecords = vCapped
			}
		}
	}

	// builds a fresh path -> array-index dictionary for the given records.
	// nonisolated so any background queue can call it without an actor hop.
	private nonisolated static func buildPathLookup(inRecords: [FileRecord]) -> [String: Int] {
		var vMap: [String: Int] = [:]
		vMap.reserveCapacity(inRecords.count)
		for (vI, vRecord) in inRecords.enumerated() {
			vMap[vRecord.fullPath] = vI
		}
		return vMap
	}

	// sorts the provided slice in place. nonisolated so the detached filter
	// task can call it without an actor hop.
	private nonisolated static func sortInPlace(inRecords: inout [FileRecord],
												 inDescriptor: FileSortDescriptor) {
		switch inDescriptor {
			case .nameAscending:
				inRecords.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
			case .nameDescending:
				inRecords.sort { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
			case .sizeAscending:
				inRecords.sort { $0.size < $1.size }
			case .sizeDescending:
				inRecords.sort { $0.size > $1.size }
			case .createdAscending:
				inRecords.sort { $0.dateCreated < $1.dateCreated }
			case .createdDescending:
				inRecords.sort { $0.dateCreated > $1.dateCreated }
			case .modifiedAscending:
				inRecords.sort { $0.dateModified < $1.dateModified }
			case .modifiedDescending:
				inRecords.sort { $0.dateModified > $1.dateModified }
			case .pathAscending:
				inRecords.sort { $0.parentPath < $1.parentPath }
			case .pathDescending:
				inRecords.sort { $0.parentPath > $1.parentPath }
		}
	}
}
