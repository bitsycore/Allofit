import Foundation
import SwiftUI
import Combine
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

// Thread-safe accumulator for FSEvents batches. The FSEvents callback appends
// here from its own queue and only schedules a flush when none is pending, so
// a replay that delivers thousands of batches in a burst becomes a handful of
// coalesced flushes instead of thousands of main-queue hops.
private final class PendingChanges: @unchecked Sendable {
	// changes received since the last drain
	private var changes: [FSChange] = []
	// true while a flush is scheduled but has not drained yet
	private var flushScheduled = false
	// how long changes are collected before a flush (follows AppActivity)
	private var delaySeconds: TimeInterval = 2
	// guards every field above
	private let lock = NSLock()

	// current collection delay before a flush
	var coalesceDelay: TimeInterval {
		lock.lock()
		defer { lock.unlock() }
		return delaySeconds
	}

	// changes the collection delay used for the next flushes
	func setCoalesceDelay(_ inSeconds: TimeInterval) {
		lock.lock()
		delaySeconds = inSeconds
		lock.unlock()
	}

	// true when changes are waiting to be flushed
	var hasPending: Bool {
		lock.lock()
		defer { lock.unlock() }
		return !changes.isEmpty
	}

	// appends a batch; returns true if the caller must schedule a flush
	func append(inChanges: [FSChange]) -> Bool {
		lock.lock()
		defer { lock.unlock() }
		changes.append(contentsOf: inChanges)
		if flushScheduled { return false }
		flushScheduled = true
		return true
	}

	// takes every pending change and re-arms flush scheduling
	func drain() -> [FSChange] {
		lock.lock()
		defer { lock.unlock() }
		let vResult = changes
		changes = []
		flushScheduled = false
		return vResult
	}

	// discards pending changes (used when the watcher is torn down)
	func reset() {
		_ = drain()
	}
}

// AppModel is the shared backing state for the application.
// It owns the in-memory file index, drives the background indexer and the
// FSEvents watcher, and exposes the active sort descriptor. The per-window
// search query and filtered/visible slice live in WindowSearchModel so two
// windows can run independent searches against this same shared index.
//
// Threading rule of thumb: this class is @MainActor so all state is written
// from main. Heavy work (LZ4 (de)compression, filtering, sorting, pruning,
// filesystem walks and stats) happens on background queues; the result is
// then merged back on main. Snapshots of value types (Array, IndexState)
// cross thread boundaries via Swift COW semantics.
//
// The record array is deliberately NOT @Published: every mutation of a
// @Published array emits the whole array, and any subscriber that buffers
// those values (receive(on:)) forces a full copy of the index per change -
// that is what used to blow up to tens of GB during an FSEvents replay.
// Views observe the small @Published counters; search models listen to the
// payload-free recordsChanged signal and read allRecords when they refilter.
@MainActor
final class AppModel: ObservableObject {

	// the canonical index (records + id lookup), main-thread only
	private var index = IndexState()
	// every entry observed so far, in no particular order
	var allRecords: RecordStore { index.records }
	// fires on main after allRecords changed (no payload by design)
	let recordsChanged = PassthroughSubject<Void, Never>()
	// when the index last changed; read by the status bar on its own
	// refresh tick, so deliberately not @Published
	private(set) var lastIndexChangeAt: Date?
	// total number of entries indexed (used for the status bar)
	@Published private(set) var indexedCount: Int = 0
	// true while a full reindex is in progress
	@Published private(set) var isIndexing: Bool = false
	// true while the cache file is being loaded into memory at startup
	@Published private(set) var isLoadingCache: Bool = false
	// true when this process owns the index (got the lock or built-in mode)
	@Published private(set) var isIndexer: Bool = false

	// how often the index is written to disk while running (seconds)
	private let kAutosaveSeconds: TimeInterval = 30
	// delay before a roots / exclusions edit is applied to the live index
	private let kConfigDebounceSeconds: TimeInterval = 1.0

	private let prefs = Preferences.shared
	// background queues isolated by concern - keeps the slow stuff off main
	private let indexQueue = DispatchQueue(label: "allofit.index", qos: .utility)
	private let ioQueue = DispatchQueue(label: "allofit.io", qos: .utility)
	// watcher used in indexer mode for live updates
	private let watcher = FileWatcher()
	// watcher used in reader mode to detect cache file refreshes
	private let cacheWatcher = FileWatcher()
	// FSEvents batches waiting to be resolved and applied (indexer mode)
	private let pendingChanges = PendingChanges()
	// roots the watcher was started with; their own records need no parent
	private var watchedRoots: Set<String> = []
	// exclusions the running watcher resolves changes with
	private var currentExclusions: ExclusionMatcher?
	// bumped whenever the whole index is replaced, so a subtree rescan that
	// started against the previous index doesn't merge into the new one
	private var indexGeneration = 0
	// autosave timer when running in indexer mode
	private var autosaveTimer: Timer?
	// true when the index has changed since the last save
	private var dirty = false
	// last FSEvents event id known to be reflected in the index
	private var lastEventId: UInt64 = 0
	// process-wide indexer mutex (nil until acquired)
	private var indexerLock: IndexerLock?
	// guards start() from running twice across window close/reopen
	private var hasStarted = false
	// subscriptions to Preferences / app lifecycle
	private var cancellables: Set<AnyCancellable> = []
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
	// minimum gap between two reader-mode reloads. Prevents the Table from
	// being re-rendered while the user is mid-click. 1 second is well below
	// any human-perceptible "stale" threshold but caps the worst-case churn
	// during heavy filesystem activity.
	private let kMinReloadInterval: TimeInterval = 1.0
	// timestamp of the last reloadFromCache() that actually swapped data in
	private var lastReloadAt: Date?

	// wires up the quit and settings observers (loading happens in start)
	init() {
		// the cache file is loaded off-main in start() so the window
		// appears instantly; here we only wire up observers.
		// Persist on Cmd+Q: the autosave only runs every 30 s and an async
		// save would be killed with the process.
		NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
			.sink { [weak self] _ in
				MainActor.assumeIsolated {
					self?.saveCacheNow()
				}
			}
			.store(in: &cancellables)
		// slow index updates down while the app isn't being looked at, and
		// catch up at once when a window comes back
		AppActivity.shared.$level
			.removeDuplicates()
			.sink { [weak self] vLevel in
				self?.activityChanged(inLevel: vLevel)
			}
			.store(in: &cancellables)
		// the delays are user settings: apply edits right away
		Publishers.Merge3(
			prefs.$updateDelayForeground,
			prefs.$updateDelayBackground,
			prefs.$updateDelayHidden
		)
		.dropFirst(3)
		.receive(on: DispatchQueue.main)
		.sink { [weak self] _ in
			self?.activityChanged(inLevel: AppActivity.shared.level)
		}
		.store(in: &cancellables)
		// apply roots / exclusions / volume edits to the live index
		Publishers.Merge4(
			prefs.$rootPaths.map { _ in () },
			prefs.$excludedPaths.map { _ in () },
			prefs.$includeMountedVolumes.map { _ in () },
			prefs.$includeNetworkVolumes.map { _ in () }
		)
		.dropFirst(4)
		.debounce(for: .seconds(kConfigDebounceSeconds), scheduler: DispatchQueue.main)
		.sink { [weak self] in
			self?.applyConfigurationChange()
		}
		.store(in: &cancellables)
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
		pendingChanges.reset()
		autosaveTimer?.invalidate()
		autosaveTimer = nil
		cachePollSource?.cancel()
		cachePollSource = nil
		indexerLock?.unlock()
		indexerLock = nil
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
		let vIsIndexer = isIndexer
		let vRoots = Set(VolumeManager.effectiveRoots(inPreferences: prefs).map { $0.path })
		let vMatcher = ExclusionMatcher(inExclusions: prefs.excludedPaths)
		NSLog("[Allofit GUI] bootstrap: serviceMode=%@ isIndexer=%@ cacheURL=%@",
			  prefs.serviceMode.rawValue,
			  vIsIndexer ? "true" : "false",
			  vCacheURL.path)
		ioQueue.async { [weak self] in
			// decompress + parse + reconcile off-main (the expensive part)
			let vCache = IndexStore.load(from: vCacheURL)
			var vState = IndexState(inRecords: vCache?.records ?? [])
			// as the indexer, drop what no longer matches the configuration
			// (removed roots, new exclusions, orphans from older versions)
			let vPruned = vIsIndexer ? vState.prune(inRoots: vRoots, inExclusions: vMatcher, inIsHidden: FileIndexer.isHidden) : 0
			DispatchQueue.main.async {
				guard let vSelf = self else { return }
				if let vCache = vCache {
					NSLog("[Allofit GUI] loaded %d records from cache (%d pruned)",
						  vState.count, vPruned)
					vSelf.lastEventId = vCache.lastEventId
				} else {
					NSLog("[Allofit GUI] cache load returned nil (file missing or invalid)")
					vSelf.lastEventId = 0
				}
				vSelf.replaceIndex(inState: vState)
				vSelf.dirty = vPruned > 0
				vSelf.isLoadingCache = false
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
			for vRoot in vRoots {
				// per-root autoreleasepool so the file-enumeration's
				// autoreleased NSURL/NSDate/NSNumber objects don't pile
				// up across roots inside this long-running async block
				autoreleasepool {
					let vBaseline = vAccumulated.count
					let vList = FileIndexer.indexRoot(inRoot: vRoot, inExclusions: vMatcher) { vCount in
						DispatchQueue.main.async {
							self?.indexedCount = vBaseline + vCount
						}
					}
					vAccumulated.append(contentsOf: vList)
				}
			}
			let vState = IndexState(inRecords: vAccumulated)
			// persist off-main before bouncing back so main never sees the
			// LZ4 compression cost
			IndexStore.save(inRecords: vState.records, inLastEventId: vStartId)
			DispatchQueue.main.async {
				self?.applyFreshIndex(inState: vState, inEventId: vStartId)
			}
		}
	}

	// dispatches a reindex appropriate for the current mode. In built-in mode
	// it triggers an in-process FileIndexer pass. In service mode it stops
	// the daemon, deletes its cache, and starts the daemon again so the
	// daemon's fresh process performs the scan from scratch. The privileged
	// portion runs on a detached task so the main thread (and the password
	// dialog from NSAppleScript) doesn't freeze the ui.
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

	// stops the running daemon for the current serviceMode preference
	// without uninstalling. Plist stays on disk so the next launch (or
	// performStartService) brings it back.
	func performStopService() async {
		await runPrivilegedAction(inLabel: "Stopping service") { vScope, _ in
			try ServiceInstaller.stop(inScope: vScope)
		}
	}

	// starts a stopped-but-installed daemon for the current serviceMode
	// preference. Hot-swaps the GUI into reader mode on success so the
	// reader watcher picks up the daemon's first cache write.
	func performStartService() async {
		let vOk = await runPrivilegedAction(inLabel: "Starting service") { vScope, _ in
			try ServiceInstaller.start(inScope: vScope)
		}
		if vOk {
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
	// publishing isWorking/workMessage so the ui can show progress. Returns
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

	// writes the current index to disk (autosave, window close, replay end).
	// Snapshots on main (cheap COW), compresses off-main.
	func saveCache() {
		guard isIndexer else { return }
		let vRecords = index.records
		// lastEventId tracks what is actually merged into the index; the
		// stream's latest id can be ahead (changes still being resolved),
		// and saving that would make the next launch skip those changes
		let vEventId = lastEventId
		dirty = false
		ioQueue.async {
			IndexStore.save(inRecords: vRecords, inLastEventId: vEventId)
		}
	}

	// synchronous save used at quit; ioQueue.sync also waits for any
	// asynchronous save still in flight so the newest state wins
	private func saveCacheNow() {
		guard isIndexer, dirty else { return }
		let vRecords = index.records
		let vEventId = lastEventId
		dirty = false
		ioQueue.sync {
			IndexStore.save(inRecords: vRecords, inLastEventId: vEventId)
		}
	}

	// ===========================
	// MARK: Indexer mode
	// ===========================

	// starts live updates after the cache was loaded. Falls back to a full
	// reindex when there is no cache, and to background rescans when the
	// saved event id can't be replayed or a configured root is missing.
	private func startIndexerMode() {
		startAutosaveTimer()
		if index.count == 0 {
			reindex()
			return
		}
		let vRoots = VolumeManager.effectiveRoots(inPreferences: prefs).map { $0.path }
		let vCurrentId = UInt64(FSEventsGetCurrentEventId())
		if lastEventId == 0 || lastEventId > vCurrentId {
			// the id is from another FSEvents database (volume erased,
			// cache copied from another Mac...): replay would silently
			// deliver nothing, so re-walk everything in the background
			// while the cached results stay searchable
			NSLog("[Allofit GUI] saved event id %llu not replayable (current %llu), rescanning roots",
				  lastEventId, vCurrentId)
			lastEventId = vCurrentId
			startWatching(inSinceWhen: vCurrentId)
			kickRescanSubtrees(inPaths: vRoots)
			return
		}
		startWatching(inSinceWhen: lastEventId)
		// roots added since the cache was written have never been walked
		let vMissing = vRoots.filter { !index.contains(inPath: $0) }
		if !vMissing.isEmpty {
			kickRescanSubtrees(inPaths: vMissing)
		}
	}

	// starts the FSEvents watcher from inSinceWhen. Batches are coalesced in
	// pendingChanges, resolved (stat'ed) on indexQueue, and only the final
	// in-memory merge runs on main - so replaying days of history after a
	// relaunch neither floods the main queue nor freezes the ui.
	private func startWatching(inSinceWhen: UInt64) {
		let vRoots = VolumeManager.effectiveRoots(inPreferences: prefs).map { $0.path }
		watchedRoots = Set(vRoots)
		pendingChanges.reset()
		let vPending = pendingChanges
		let vQueue = indexQueue
		let vMatcher = ExclusionMatcher(inExclusions: prefs.excludedPaths)
		currentExclusions = vMatcher
		watcher.start(
			inRoots: vRoots,
			inSinceWhen: FSEventStreamEventId(inSinceWhen)
		) { [weak self] vChanges in
			guard vPending.append(inChanges: vChanges) else { return }
			vQueue.asyncAfter(deadline: .now() + vPending.coalesceDelay) { [weak self] in
				AppModel.flush(inPending: vPending, inExclusions: vMatcher, inModel: self)
			}
		}
	}

	// resolves everything pending (on the calling background queue) and
	// merges the result on main
	private nonisolated static func flush(inPending: PendingChanges,
										  inExclusions: ExclusionMatcher,
										  inModel: AppModel?) {
		let vChanges = inPending.drain()
		// an early catch-up flush may already have taken everything
		guard !vChanges.isEmpty else { return }
		let vResolved = IndexState.resolve(inChanges: vChanges, inExclusions: inExclusions)
		DispatchQueue.main.async { [weak inModel] in
			inModel?.applyResolvedChanges(inResolved: vResolved)
		}
	}

	// adapts the update cadence to the visibility level (delays from
	// Settings > Performance). Longer collection windows when nobody looks
	// mean fewer wake-ups and fewer stats, since repeated writes to one file
	// collapse into one check. When the app becomes more visible (or a
	// delay is shortened), pending changes are applied right away.
	private func activityChanged(inLevel: AppActivity.Level) {
		let vDelay: TimeInterval
		switch inLevel {
			case .foreground: vDelay = prefs.updateDelayForeground
			case .background: vDelay = prefs.updateDelayBackground
			case .hidden: vDelay = prefs.updateDelayHidden
		}
		let vPrevious = pendingChanges.coalesceDelay
		pendingChanges.setCoalesceDelay(vDelay)
		guard vDelay < vPrevious, isIndexer, pendingChanges.hasPending, let vMatcher = currentExclusions else { return }
		let vPending = pendingChanges
		indexQueue.async { [weak self] in
			AppModel.flush(inPending: vPending, inExclusions: vMatcher, inModel: self)
		}
	}

	// saves the index every kAutosaveSeconds while it has unsaved changes
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

	// merges a resolved set of FSEvents changes into the index (pure
	// in-memory work; the stats were done off-main by IndexState.resolve)
	private func applyResolvedChanges(inResolved: ResolvedChanges) {
		guard isIndexer else { return }
		let vResult = index.apply(inChanges: inResolved, inRoots: watchedRoots)
		lastEventId = max(lastEventId, inResolved.maxEventId)
		if vResult.changed {
			dirty = true
			publishRecords()
		}
		if !vResult.rescans.isEmpty {
			kickRescanSubtrees(inPaths: vResult.rescans)
		}
		// persist right after a relaunch replay finishes so the next launch
		// resumes from here instead of replaying the same history again
		if inResolved.historyDone {
			NSLog("[Allofit GUI] FSEvents history replay done, saving cache")
			saveCache()
		}
	}

	// re-walks the given subtrees in the background, then swaps their
	// content in on main. Used for kernel-requested rescans, folders that
	// were moved/renamed into the tree, and newly added roots.
	private func kickRescanSubtrees(inPaths: [String]) {
		let vRoots = SubtreeMatcher.minimalRoots(inPaths: inPaths)
		guard !vRoots.isEmpty else { return }
		let vMatcher = ExclusionMatcher(inExclusions: prefs.excludedPaths)
		let vGeneration = indexGeneration
		indexQueue.async { [weak self] in
			var vRecords: [FileRecord] = []
			for vPath in vRoots {
				// per-subtree autoreleasepool keeps the walk's autoreleased
				// URL/stat objects from accumulating across subtrees
				autoreleasepool {
					vRecords.append(contentsOf: FileIndexer.indexRoot(
						inRoot: URL(fileURLWithPath: vPath),
						inExclusions: vMatcher
					))
				}
			}
			let vFinal = vRecords
			DispatchQueue.main.async {
				guard let vSelf = self, vSelf.isIndexer, vSelf.indexGeneration == vGeneration else { return }
				vSelf.index.replaceSubtrees(inRoots: vRoots, inRecords: vFinal)
				vSelf.dirty = true
				vSelf.publishRecords()
			}
		}
	}

	// applies edited roots / exclusions / volume options to the live index
	// without a full reindex: prunes what fell out of scope, walks roots
	// that are new, and restarts the watcher on the new root set
	private func applyConfigurationChange() {
		guard isIndexer, !isIndexing, !isLoadingCache else { return }
		NSLog("[Allofit GUI] configuration changed, reconciling index")
		let vRoots = VolumeManager.effectiveRoots(inPreferences: prefs).map { $0.path }
		let vRootSet = Set(vRoots)
		let vMatcher = ExclusionMatcher(inExclusions: prefs.excludedPaths)
		let vState = index
		let vGeneration = indexGeneration
		watcher.stop()
		indexQueue.async { [weak self] in
			var vPruned = vState
			let vRemoved = vPruned.prune(inRoots: vRootSet, inExclusions: vMatcher, inIsHidden: FileIndexer.isHidden)
			DispatchQueue.main.async {
				guard let vSelf = self, vSelf.isIndexer, vSelf.indexGeneration == vGeneration else { return }
				NSLog("[Allofit GUI] reconcile: %d records pruned", vRemoved)
				vSelf.replaceIndex(inState: vPruned)
				vSelf.dirty = true
				vSelf.startWatching(inSinceWhen: vSelf.lastEventId)
				let vMissing = vRoots.filter { !vSelf.index.contains(inPath: $0) }
				if !vMissing.isEmpty {
					vSelf.kickRescanSubtrees(inPaths: vMissing)
				}
			}
		}
	}

	// ===========================
	// MARK: Reader mode
	// ===========================

	// follows the cache written by another indexer (service or second instance)
	private func startReaderMode() {
		let vUrl = IndexStore.cacheURL(forServiceMode: prefs.serviceMode)
		let vDir = vUrl.deletingLastPathComponent().path
		let vTarget = vUrl.path
		NSLog("[Allofit GUI] reader mode: watching cache at %@", vTarget)
		// FSEvents-based watcher for low-latency updates. We watch the
		// parent dir (FSEvents needs a real path) but only fire the reload
		// when the cache file itself changed - other files in the dir
		// (indexer.lock, .tmp atomic-rename leftovers, etc.) used to also
		// trigger main.async hops, which contributed to dropped clicks.
		cacheWatcher.start(inRoots: [vDir]) { [weak self] vChanges in
			let vCacheChanged = vChanges.contains(where: { $0.path == vTarget })
			guard vCacheChanged else { return }
			NSLog("[Allofit GUI] cache file changed (FSEvents), reloading")
			DispatchQueue.main.async { [weak self] in
				self?.reloadFromCache()
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

	// reloads the on-disk cache off-main and swaps it in atomically.
	//
	// Two guards keep this from disrupting Table interactions:
	//   1. lastEventId comparison - the daemon advances its event id every
	//      time it actually persists new state, so a matching id means the
	//      records on disk are identical to what we have and we can bail
	//      before touching any published state.
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
		let vCurrentCount = index.count
		ioQueue.async { [weak self] in
			guard let vCache = IndexStore.load(from: vUrl) else { return }
			// short-circuit when the on-disk content matches what we already
			// have - common when the daemon resaves on a noise-only FSEvents
			// burst (e.g. spotlight reindexing, temp files in /var). The
			// count check lets partial saves of a first scan through (the
			// daemon keeps the event id at 0 until the scan completes).
			if vCache.lastEventId == vCurrentEventId && vCache.records.count == vCurrentCount { return }
			let vState = IndexState(inRecords: vCache.records)
			DispatchQueue.main.async {
				guard let vSelf = self, !vSelf.isIndexer else { return }
				vSelf.lastEventId = vCache.lastEventId
				vSelf.replaceIndex(inState: vState)
			}
		}
	}

	// ===========================
	// MARK: Internals
	// ===========================

	// installs a whole new index (cache load, reindex, reload, reconcile)
	private func replaceIndex(inState: IndexState) {
		index = inState
		indexGeneration &+= 1
		publishRecords()
	}

	// notifies observers that the records changed
	private func publishRecords() {
		lastIndexChangeAt = Date()
		if indexedCount != index.count {
			indexedCount = index.count
		}
		recordsChanged.send()
	}

	// installs a freshly-built index and starts watching for changes
	private func applyFreshIndex(inState: IndexState, inEventId: UInt64) {
		replaceIndex(inState: inState)
		lastEventId = inEventId
		isIndexing = false
		dirty = false
		if isIndexer {
			startWatching(inSinceWhen: inEventId)
		}
	}
}
