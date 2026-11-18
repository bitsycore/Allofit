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

// IndexBox holds the canonical index (records + id lookup). Only
// AppModel's mutateQueue reads or changes it.
private final class IndexBox: @unchecked Sendable {
	// the index itself
	var state = IndexState()
}

// AppModel is the shared backing state for the application.
// It owns the in-memory file index, drives the background indexer and the
// FSEvents watcher, and exposes the active sort descriptor. The per-window
// search query and filtered/visible slice live in WindowSearchModel so two
// windows can run independent searches against this same shared index.
//
// Threading rule of thumb: this class is @MainActor so its state is written
// from main. Heavy work (LZ4 (de)compression, filtering, sorting, pruning,
// filesystem walks and stats) happens on background queues. The index
// itself lives in an IndexBox changed only on mutateQueue: every update
// (FSEvents batches, walks, removals) runs there, and main only receives
// the resulting records snapshot (cheap: RecordStore shares its chunks).
// So a burst of file activity never blocks typing or clicking.
//
// The record array is deliberately NOT @Published: every mutation of a
// @Published array emits the whole array, and any subscriber that buffers
// those values (receive(on:)) forces a full copy of the index per change -
// that is what used to blow up to tens of GB during an FSEvents replay.
// Views observe the small @Published counters; search models listen to the
// payload-free recordsChanged signal and read allRecords when they refilter.
@MainActor
final class AppModel: ObservableObject {

	// the canonical index (records + id lookup), only touched on mutateQueue
	private nonisolated let indexBox = IndexBox()
	// serial queue running every change to the index, off the main thread
	private nonisolated let mutateQueue = DispatchQueue(label: "allofit.mutate", qos: .userInitiated)
	// the index's records as of the last change applied (main thread)
	private var records = RecordStore()
	// every entry observed so far, in no particular order
	var allRecords: RecordStore { records }
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
	// root folders being indexed for the first time (or re-read entirely),
	// with how many entries were found so far: shown in the status bar and
	// next to the folder in Settings
	@Published private(set) var scans: [ScanProgress] = []
	// protected roots whose wipe was refused, with when it last happened
	@Published private(set) var keptRoots: [String: Date] = [:]

	// one announced walk of a root folder
	struct ScanProgress: Identifiable, Equatable {
		// canonical path of the folder being walked
		let path: String
		// entries found so far
		var found: Int
		// identity for SwiftUI lists
		var id: String { path }
		// folder name for display ("Spirtech2k")
		var name: String { (path as NSString).lastPathComponent }
	}

	// how often the index is written to disk while running (seconds)
	private let kAutosaveSeconds: TimeInterval = 30
	// autosaves are at least this many times their own duration apart
	private let kSaveSpacingFactor: Double = 10
	// true while a save runs on ioQueue
	private var isSaving = false
	// how long the last save took, and when it ended
	private var lastSaveDuration: TimeInterval = 0
	private var lastSaveEnd = Date.distantPast
	// delay before a roots / exclusions edit is applied to the live index
	private let kConfigDebounceSeconds: TimeInterval = 1.0

	private let prefs = Preferences.shared
	// background queues isolated by concern - keeps the slow stuff off main
	private let indexQueue = DispatchQueue(label: "allofit.index", qos: .utility)
	private let ioQueue = DispatchQueue(label: "allofit.io", qos: .utility)
	// subtree walks (new roots, new or rescanned folders): separate from
	// indexQueue so a long walk never delays live updates
	private let walkQueue = DispatchQueue(label: "allofit.walk", qos: .utility)
	// while walking a new root or folder, what's found so far is added to
	// the index this often
	private let kWalkStreamSeconds: TimeInterval = 3
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
	// roots and protected roots the running watcher guards (see RootGuard)
	private var guardConfig: (roots: [String], protected: [String]) = ([], [])
	// subtree walks started but not merged yet
	private var rescansInFlight = 0
	// subtree walks queued on walkQueue that haven't started yet
	private var queuedWalks: [(path: String, isRescan: Bool)] = []
	// event id to save while rescans are in flight: the id from before the
	// changes that triggered them, so a quit or crash mid-walk replays those
	// changes instead of losing the folders' contents for good
	private var rescanFloorEventId: UInt64?
	// a reader-mode reload skipped (throttled or no window visible)
	private var pendingReaderReload = false
	// service mode the current role was started with (see activeServiceMode)
	private(set) var bootMode: Preferences.ServiceMode = .none
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
		// re-read the roots of a drive or share as soon as it mounts
		NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)
			.receive(on: DispatchQueue.main)
			.sink { [weak self] vNote in
				guard let vUrl = vNote.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
				self?.volumeMounted(inPath: VolumeManager.canonicalPath(inPath: vUrl.path))
			}
			.store(in: &cancellables)
		// apply roots / exclusions / volume edits to the live index
		Publishers.Merge5(
			prefs.$rootPaths.map { _ in () },
			prefs.$excludedPaths.map { _ in () },
			prefs.$includeMountedVolumes.map { _ in () },
			prefs.$includeNetworkVolumes.map { _ in () },
			prefs.$protectedRoots.map { _ in () }
		)
		.dropFirst(5)
		.debounce(for: .seconds(kConfigDebounceSeconds), scheduler: DispatchQueue.main)
		.sink { [weak self] in
			self?.applyConfigurationChange()
		}
		.store(in: &cancellables)
	}

	// the service mode actually in effect: the saved mode, but only if that
	// service is really installed. A mode saved without a working install
	// (or a service removed behind the app's back) falls back to indexing
	// in-process instead of waiting forever on a cache nobody writes.
	var activeServiceMode: Preferences.ServiceMode {
		switch prefs.serviceMode {
			case .none: return .none
			case .userAgent: return ServiceInstaller.isInstalled(inScope: .userAgent) ? .userAgent : .none
			case .rootDaemon: return ServiceInstaller.isInstalled(inScope: .rootDaemon) ? .rootDaemon : .none
		}
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

		let vMode = activeServiceMode
		bootMode = vMode
		if vMode != prefs.serviceMode {
			NSLog("[Allofit GUI] service mode %@ saved but not installed, indexing in-process", prefs.serviceMode.rawValue)
		}
		if vMode != .none {
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
		let vCacheURL = IndexStore.cacheURL(forServiceMode: vMode)
		let vIsIndexer = isIndexer
		let vRoots = Set(VolumeManager.effectiveRoots(inPreferences: prefs).map { $0.path })
		let vMatcher = ExclusionMatcher(inExclusions: prefs.excludedPaths)
		NSLog("[Allofit GUI] bootstrap: serviceMode=%@ isIndexer=%@ cacheURL=%@",
			  vMode.rawValue,
			  vIsIndexer ? "true" : "false",
			  vCacheURL.path)
		// user-initiated: the window waits for it. At utility priority a busy
		// Mac (a test suite running) throttled a 10 s load to over a minute.
		ioQueue.async(qos: .userInitiated, flags: .enforceQoS) { [weak self] in
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
		let vIoQueue = ioQueue
		// partial results only when there is nothing to show yet (first
		// run): a manual rebuild keeps the old index visible until the end
		let vPublishPartial = records.count == 0
		// the current entries of a root that can't be read, or of a protected
		// root the walk would wipe, are kept (see RootGuard)
		let vOld = records
		let vProtected = prefs.protectedRoots
		indexQueue.async { [weak self] in
			var vAccumulated: [FileRecord] = []
			var vSpared: [String] = []
			// the results fill in while the walk runs (instead of an empty
			// window until the end of a scan that can take minutes)
			let kPartialPublishSeconds: TimeInterval = 3
			var vLastPublish = Date()
			let vGuard = RootGuard.current(inRoots: vRoots.map { $0.path }, inProtected: vProtected)
			for vRoot in vRoots {
				let vStart = vAccumulated.count
				// per-root autoreleasepool so the file-enumeration's
				// autoreleased NSURL/NSDate/NSNumber objects don't pile
				// up across roots inside this long-running async block
				autoreleasepool {
					if vGuard.isOffline(inPath: vRoot.path) { return }
					FileIndexer.walkRoot(inRoot: vRoot, inExclusions: vMatcher) { vBatch in
						vAccumulated.append(contentsOf: vBatch)
						let vCount = vAccumulated.count
						let vNow = Date()
						guard vPublishPartial, vNow.timeIntervalSince(vLastPublish) >= kPartialPublishSeconds else {
							DispatchQueue.main.async { self?.indexedCount = vCount }
							return
						}
						vLastPublish = vNow
						let vPartial = IndexState(inRecords: vAccumulated)
						DispatchQueue.main.async {
							guard let vSelf = self, vSelf.isIndexing else { return }
							vSelf.replaceIndex(inState: vPartial)
						}
					}
				}
				// unmounted (now or during the walk), or about to be wiped
				let vRootMatcher = SubtreeMatcher(inRoots: [vRoot.path])
				let vOldPositions = vOld.positions(coveredBy: vRootMatcher)
				let vOldCount = vOldPositions.count
				let vIsOffline = !VolumeManager.isReachable(inPath: vRoot.path)
				let vIsWipe = vGuard.protectedRoot(of: vRoot.path) != nil
					&& RootGuard.isWipe(inBefore: vOldCount, inAfter: vAccumulated.count - vStart)
				if vOldCount > 0 && (vIsOffline || vIsWipe) {
					vAccumulated.removeSubrange(vStart...)
					vAccumulated.append(contentsOf: vOldPositions.map { vOld[$0] })
					if vIsWipe { vSpared.append(vRoot.path) }
				}
			}
			let vState = IndexState(inRecords: vAccumulated)
			// persist off-main (on the save queue, so it never races another
			// save) before bouncing back: main never sees the LZ4 cost
			vIoQueue.sync {
				IndexStore.save(inRecords: vState.records, inLastEventId: vStartId)
			}
			DispatchQueue.main.async {
				self?.noteKept(inRoots: vSpared)
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
		switch activeServiceMode {
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
	// inMode is the mode chosen in Settings: it is only saved once the
	// install succeeded, so a failed or cancelled install changes nothing
	func performInstallService(inMode: Preferences.ServiceMode) async {
		let vOk = await runPrivilegedAction(inLabel: "Installing service", inMode: inMode) { vScope, _ in
			try ServiceInstaller.install(inScope: vScope)
		}
		if vOk {
			prefs.serviceMode = inMode
			// give launchd a moment to bring the daemon up before we switch
			// the GUI into reader mode and start watching the cache file
			try? await Task.sleep(nanoseconds: 1_500_000_000)
			switchToCurrentMode()
		}
	}

	// stops the running daemon for the current serviceMode preference
	// without uninstalling. Plist stays on disk so the next launch (or
	// performStartService) brings it back.
	func performStopService(inMode: Preferences.ServiceMode? = nil) async {
		await runPrivilegedAction(inLabel: "Stopping service", inMode: inMode) { vScope, _ in
			try ServiceInstaller.stop(inScope: vScope)
		}
	}

	// starts a stopped-but-installed daemon for the current serviceMode
	// preference. Hot-swaps the GUI into reader mode on success so the
	// reader watcher picks up the daemon's first cache write.
	func performStartService(inMode: Preferences.ServiceMode? = nil) async {
		let vOk = await runPrivilegedAction(inLabel: "Starting service", inMode: inMode) { vScope, _ in
			try ServiceInstaller.start(inScope: vScope)
		}
		if vOk {
			try? await Task.sleep(nanoseconds: 1_500_000_000)
			switchToCurrentMode()
		}
	}

	// uninstalls the launchd service for the current serviceMode preference.
	// On success the GUI hot-swaps back into built-in indexer mode.
	func performUninstallService(inMode: Preferences.ServiceMode? = nil) async {
		let vMode = inMode ?? prefs.serviceMode
		let vOk = await runPrivilegedAction(inLabel: "Uninstalling service", inMode: vMode) { vScope, _ in
			try ServiceInstaller.uninstall(inScope: vScope)
		}
		if vOk {
			// back to the built-in indexer when the active service went away
			if vMode == prefs.serviceMode {
				prefs.serviceMode = .none
			}
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
	// inMode defaults to the saved mode (the installed service)
	private func runPrivilegedAction(inLabel: String,
									  inMode: Preferences.ServiceMode? = nil,
									  inBody: @Sendable @escaping (ServiceInstaller.Scope, URL) throws -> Void) async -> Bool {
		let vMode = inMode ?? prefs.serviceMode
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
	// inForce saves even when nothing changed (to persist replay progress)
	func saveCache(inForce: Bool = false) {
		guard isIndexer, dirty || inForce else { return }
		let vRecords = records
		// lastEventId tracks what is actually merged into the index; the
		// stream's latest id can be ahead (changes still being resolved),
		// and saving that would make the next launch skip those changes.
		// While subtree walks are pending, the id from before them is kept.
		let vEventId = rescanFloorEventId ?? lastEventId
		dirty = false
		isSaving = true
		ioQueue.async { [weak self] in
			let vStart = Date()
			IndexStore.save(inRecords: vRecords, inLastEventId: vEventId)
			let vDuration = Date().timeIntervalSince(vStart)
			DispatchQueue.main.async {
				self?.isSaving = false
				self?.lastSaveDuration = vDuration
				self?.lastSaveEnd = Date()
			}
		}
	}

	// true when an autosave may run now: nothing being saved, and enough
	// time since the last save. A save rewrites the whole index (seconds
	// for millions of entries), so under constant file activity the gap
	// grows with its cost instead of keeping a core busy saving.
	private var isAutosaveDue: Bool {
		guard dirty, !isSaving else { return false }
		let vGap = max(kAutosaveSeconds, lastSaveDuration * kSaveSpacingFactor)
		return Date().timeIntervalSince(lastSaveEnd) >= vGap
	}

	// synchronous save used at quit; ioQueue.sync also waits for any
	// asynchronous save still in flight so the newest state wins
	private func saveCacheNow() {
		guard isIndexer, dirty else { return }
		let vRecords = records
		let vEventId = rescanFloorEventId ?? lastEventId
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
		if records.count == 0 {
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
			// floor 0: an interrupted walk makes the next launch start over
			kickRescanSubtrees(inPaths: vRoots, inFloorEventId: 0, inAnnounce: true)
			return
		}
		startWatching(inSinceWhen: lastEventId)
		// roots added since the cache was written have never been walked
		// (an unmounted one is walked when its volume mounts)
		let vFloor = lastEventId
		readIndex({ vState in
			vRoots.filter { !vState.contains(inPath: $0) && VolumeManager.isReachable(inPath: $0) }
		}) { [weak self] vMissing in
			guard !vMissing.isEmpty else { return }
			// nothing below a missing root is indexed: stream it in
			self?.kickRescanSubtrees(inPaths: vMissing, inFloorEventId: vFloor, inNewFolders: true, inAnnounce: true)
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
		let vProtected = prefs.protectedRoots
		guardConfig = (vRoots, vProtected)
		watcher.start(
			inRoots: vRoots,
			inSinceWhen: FSEventStreamEventId(inSinceWhen)
		) { [weak self] vChanges in
			guard vPending.append(inChanges: vChanges) else { return }
			vQueue.asyncAfter(deadline: .now() + vPending.coalesceDelay) { [weak self] in
				AppModel.flush(inPending: vPending, inExclusions: vMatcher,
							   inRoots: vRoots, inProtected: vProtected, inModel: self)
			}
		}
	}

	// resolves everything pending (on the calling background queue) and
	// merges the result on main. The roots are checked first, so changes
	// below an unmounted one are ignored (see RootGuard).
	private nonisolated static func flush(inPending: PendingChanges,
										  inExclusions: ExclusionMatcher,
										  inRoots: [String],
										  inProtected: [String],
										  inModel: AppModel?) {
		let vChanges = inPending.drain()
		// an early catch-up flush may already have taken everything
		guard !vChanges.isEmpty else { return }
		let vGuard = RootGuard.current(inRoots: inRoots, inProtected: inProtected)
		let vResolved = IndexState.resolve(inChanges: vChanges, inExclusions: inExclusions, inGuard: vGuard)
		DispatchQueue.main.async { [weak inModel] in
			inModel?.applyResolvedChanges(inResolved: vResolved, inGuard: vGuard)
		}
	}

	// adapts the update cadence to the visibility level (delays from
	// Settings > Performance). Longer collection windows when nobody looks
	// mean fewer wake-ups and fewer stats, since repeated writes to one file
	// collapse into one check. When the app becomes more visible (or a
	// delay is shortened), pending changes are applied right away.
	private func activityChanged(inLevel: AppActivity.Level) {
		// reader mode: a reload skipped while hidden happens now
		if inLevel != .hidden && pendingReaderReload && !isIndexer {
			pendingReaderReload = false
			reloadFromCache()
		}
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
		let (vRoots, vProtected) = guardConfig
		indexQueue.async { [weak self] in
			AppModel.flush(inPending: vPending, inExclusions: vMatcher,
						   inRoots: vRoots, inProtected: vProtected, inModel: self)
		}
	}

	// saves the index every kAutosaveSeconds while it has unsaved changes
	private func startAutosaveTimer() {
		autosaveTimer?.invalidate()
		// .common mode so the timer fires even while SwiftUI is busy
		let vTimer = Timer(timeInterval: kAutosaveSeconds, repeats: true) { [weak self] _ in
			Task { @MainActor in
				guard let vSelf = self, vSelf.isAutosaveDue else { return }
				vSelf.saveCache()
			}
		}
		RunLoop.main.add(vTimer, forMode: .common)
		autosaveTimer = vTimer
	}

	// merges a resolved set of FSEvents changes into the index (pure
	// in-memory work; the stats were done off-main by IndexState.resolve)
	private func applyResolvedChanges(inResolved: ResolvedChanges, inGuard: RootGuard = RootGuard()) {
		guard isIndexer else { return }
		let vEventIdBefore = lastEventId
		let vRoots = watchedRoots
		mutateIndex({ vState in
			vState.apply(inChanges: inResolved, inRoots: vRoots, inGuard: inGuard)
		}) { [weak self] vResult in
			guard let vSelf = self else { return }
			vSelf.lastEventId = max(vSelf.lastEventId, inResolved.maxEventId)
			vSelf.noteKept(inRoots: vResult.spared)
			if vResult.changed {
				vSelf.dirty = true
				vSelf.publishRecords()
			}
			if !vResult.rescans.isEmpty {
				vSelf.kickRescanSubtrees(inPaths: vResult.rescans, inFloorEventId: vEventIdBefore)
			}
			if !vResult.newFolders.isEmpty {
				vSelf.kickRescanSubtrees(inPaths: vResult.newFolders, inFloorEventId: vEventIdBefore, inNewFolders: true)
			}
			// persist right after a relaunch replay finishes so the next
			// launch resumes from here instead of replaying it again
			if inResolved.historyDone {
				NSLog("[Allofit GUI] FSEvents history replay done, saving cache")
				vSelf.saveCache(inForce: true)
			}
		}
	}

	// re-walks the given subtrees in the background, then swaps their
	// content in on main. Used for kernel-requested rescans, folders that
	// were moved/renamed into the tree, and newly added roots.
	// inFloorEventId is saved instead of lastEventId until the walk is
	// merged. inNewFolders: the folders just appeared, so their records are
	// merged without the O(n) removal pass of a kernel-requested rescan.
	// inAnnounce lists the walk in `scans` (root folders only: the small
	// folders appearing all the time would make the status bar flicker)
	private func kickRescanSubtrees(inPaths: [String], inFloorEventId: UInt64, inNewFolders: Bool = false, inAnnounce: Bool = false) {
		// a walk still waiting in the queue already covers its folders: one
		// that hasn't started reads them as they'll be then. Under heavy
		// file activity macOS can ask for the same rescan (a whole root)
		// in batch after batch, which would queue full walks back to back.
		// A rescan covers new folders too (it replaces), not the reverse.
		let vRoots = SubtreeMatcher.minimalRoots(inPaths: inPaths).filter { vPath in
			!queuedWalks.contains { vQueued in
				(vQueued.isRescan || inNewFolders) && RootGuard.isAtOrBelow(inPath: vPath, inRoot: vQueued.path)
			}
		}
		guard !vRoots.isEmpty else { return }
		let vQueued = vRoots.map { (path: $0, isRescan: !inNewFolders) }
		queuedWalks.append(contentsOf: vQueued)
		if inAnnounce {
			for vRoot in vRoots where !scans.contains(where: { $0.path == vRoot }) {
				scans.append(ScanProgress(path: vRoot, found: 0))
			}
		}
		let vMatcher = ExclusionMatcher(inExclusions: prefs.excludedPaths)
		let vGeneration = indexGeneration
		rescanFloorEventId = min(rescanFloorEventId ?? inFloorEventId, inFloorEventId)
		rescansInFlight += 1
		let vStreamSeconds = kWalkStreamSeconds
		let (vGuardRoots, vProtected) = guardConfig
		// own queue: a long walk (a whole network share) must not hold up
		// the FSEvents updates resolved on indexQueue
		walkQueue.async { [weak self] in
			// started: later requests need a walk of their own again
			DispatchQueue.main.async {
				self?.queuedWalks.removeAll { vEntry in
					vQueued.contains { $0.path == vEntry.path && $0.isRescan == vEntry.isRescan }
				}
			}
			var vRecords: [FileRecord] = []
			var vLastStream = Date()
			var vLastProgress = Date()
			// the walked folders' own entries are only merged at the very end,
			// so an interrupted walk leaves them "missing" and gets redone
			let vRootIds = Set(vRoots.map { FileRecord.pathHash($0) })
			var vHeldRoots: [FileRecord] = []
			for vPath in vRoots {
				var vFound = 0
				// per-subtree autoreleasepool keeps the walk's autoreleased
				// URL/stat objects from accumulating across subtrees
				autoreleasepool {
					FileIndexer.walkRoot(inRoot: URL(fileURLWithPath: vPath), inExclusions: vMatcher) { vBatch in
						vRecords.append(contentsOf: vBatch)
						vFound += vBatch.count
						if inAnnounce && Date().timeIntervalSince(vLastProgress) >= 0.5 {
							vLastProgress = Date()
							let vCount = vFound
							DispatchQueue.main.async {
								self?.updateScan(inPath: vPath, inFound: vCount)
							}
						}
						// new folders / roots: nothing below them is indexed
						// yet, so what's found so far can be shown right away
						guard inNewFolders, Date().timeIntervalSince(vLastStream) >= vStreamSeconds else { return }
						vLastStream = Date()
						vHeldRoots.append(contentsOf: vRecords.filter { vRootIds.contains($0.id) })
						let vChunk = vRecords.filter { !vRootIds.contains($0.id) }
						vRecords = []
						DispatchQueue.main.async {
							self?.mergeWalked(inRecords: vChunk, inGeneration: vGeneration)
						}
					}
				}
			}
			let vFinal = vRecords + vHeldRoots
			// checked after the walk: a share unmounted meanwhile looks empty
			let vGuard = RootGuard.current(inRoots: vGuardRoots, inProtected: vProtected)
			DispatchQueue.main.async {
				guard let vSelf = self else { return }
				// the walk counts as done (and the saved event id may move
				// past it) only once its records are in the index
				let vFinish = { [weak vSelf] in
					guard let vSelf = vSelf else { return }
					if inAnnounce {
						vSelf.scans.removeAll { vRoots.contains($0.path) }
					}
					vSelf.rescansInFlight -= 1
					if vSelf.rescansInFlight <= 0 {
						vSelf.rescansInFlight = 0
						vSelf.rescanFloorEventId = nil
					}
				}
				guard vSelf.isIndexer, vSelf.indexGeneration == vGeneration else {
					vFinish()
					return
				}
				if inNewFolders {
					vSelf.mergeWalked(inRecords: vFinal, inGeneration: vGeneration, inFinally: vFinish)
				} else {
					vSelf.mutateIndex({ vState in
						vState.replaceSubtrees(inRoots: vRoots, inRecords: vFinal, inGuard: vGuard)
					}, inFinally: vFinish) { [weak vSelf] vSpared in
						vSelf?.noteKept(inRoots: vSpared)
						vSelf?.dirty = true
						vSelf?.publishRecords()
					}
				}
			}
		}
	}

	// records protected roots whose wipe was just refused
	private func noteKept(inRoots: [String]) {
		guard !inRoots.isEmpty else { return }
		for vRoot in inRoots {
			NSLog("[Allofit GUI] protected root %@: refused an update that would remove almost all of it", vRoot)
			keptRoots[vRoot] = Date()
		}
	}

	// a volume was mounted: roots on it that are already indexed are
	// re-read (their files may have changed while it was away, and changes
	// made from other computers to a share are never reported), and roots
	// never indexed are walked. The watcher restarts so it covers the volume.
	private func volumeMounted(inPath: String) {
		guard isIndexer, !isIndexing, !isLoadingCache else { return }
		let vRoots = VolumeManager.effectiveRoots(inPreferences: prefs).map { $0.path }
		let vOnVolume = vRoots.filter {
			RootGuard.isAtOrBelow(inPath: $0, inRoot: inPath) && VolumeManager.isReachable(inPath: $0)
		}
		guard !vOnVolume.isEmpty else { return }
		NSLog("[Allofit GUI] volume mounted at %@, re-reading %d root(s)", inPath, vOnVolume.count)
		let vSinceId = rescanFloorEventId ?? lastEventId
		watcher.stop()
		startWatching(inSinceWhen: vSinceId)
		readIndex({ vState in
			vOnVolume.filter { vState.contains(inPath: $0) }
		}) { [weak self] vKnown in
			let vNew = vOnVolume.filter { !vKnown.contains($0) }
			if !vKnown.isEmpty {
				self?.kickRescanSubtrees(inPaths: vKnown, inFloorEventId: vSinceId, inAnnounce: true)
			}
			if !vNew.isEmpty {
				self?.kickRescanSubtrees(inPaths: vNew, inFloorEventId: vSinceId, inNewFolders: true, inAnnounce: true)
			}
		}
	}

	// publishes the progress of an announced walk
	private func updateScan(inPath: String, inFound: Int) {
		guard let vIndex = scans.firstIndex(where: { $0.path == inPath }) else { return }
		scans[vIndex].found = inFound
	}

	// adds walked records below folders that weren't indexed (no removal
	// pass, off the main thread), unless the index was replaced since the
	// walk started. inFinally runs on main once done, in every case.
	private func mergeWalked(inRecords: [FileRecord], inGeneration: Int, inFinally: (() -> Void)? = nil) {
		guard isIndexer, indexGeneration == inGeneration, !inRecords.isEmpty else {
			inFinally?()
			return
		}
		mutateIndex({ vState in
			vState.mergeNewFolders(inRecords: inRecords)
		}, inFinally: inFinally) { [weak self] _ in
			self?.dirty = true
			self?.publishRecords()
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
		// replay point: changes still queued, and those whose subtree walks
		// are running (dropped below), are replayed from here
		let vSnapshotEventId = rescanFloorEventId ?? lastEventId
		watcher.stop()
		// walks started for the old configuration don't merge any more
		// (one for a root just removed would bring its entries back)
		indexGeneration &+= 1
		mutateIndex({ vState in
			let vRemoved = vState.prune(inRoots: vRootSet, inExclusions: vMatcher, inIsHidden: FileIndexer.isHidden)
			let vMissing = vRoots.filter { !vState.contains(inPath: $0) && VolumeManager.isReachable(inPath: $0) }
			return (vRemoved, vMissing)
		}) { [weak self] vResult in
			guard let vSelf = self, vSelf.isIndexer else { return }
			NSLog("[Allofit GUI] reconcile: %d records pruned", vResult.0)
			vSelf.dirty = true
			vSelf.publishRecords()
			vSelf.lastEventId = vSnapshotEventId
			vSelf.startWatching(inSinceWhen: vSnapshotEventId)
			if !vResult.1.isEmpty {
				vSelf.kickRescanSubtrees(inPaths: vResult.1, inFloorEventId: vSnapshotEventId, inNewFolders: true, inAnnounce: true)
			}
		}
	}

	// drops paths (and what's below them) from the index right away. Used
	// after Move to Trash from Allofit: the watcher ignores this process's
	// own file operations, so FSEvents would never report the removal
	func forget(inPaths: [String]) {
		guard isIndexer, !inPaths.isEmpty else { return }
		mutateIndex({ vState in
			vState.removeSubtrees(inPaths: inPaths)
		}) { [weak self] vRemoved in
			guard vRemoved > 0 else { return }
			self?.dirty = true
			self?.publishRecords()
		}
	}

	// (re)adds paths this app created or moved back itself (undo of Move to
	// Trash), which FSEvents doesn't report to it. Resolved like FSEvents
	// changes, so restored folders get walked too.
	func notice(inPaths: [String]) {
		guard isIndexer, !inPaths.isEmpty else { return }
		let vChanges = inPaths.map { FSChange(path: $0, flags: 0, eventId: 0) }
		let vMatcher = ExclusionMatcher(inExclusions: prefs.excludedPaths)
		indexQueue.async { [weak self] in
			let vResolved = IndexState.resolve(inChanges: vChanges, inExclusions: vMatcher)
			DispatchQueue.main.async {
				self?.applyResolvedChanges(inResolved: vResolved)
			}
		}
	}

	// ===========================
	// MARK: Reader mode
	// ===========================

	// follows the cache written by another indexer (service or second instance)
	private func startReaderMode() {
		let vUrl = IndexStore.cacheURL(forServiceMode: bootMode)
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
		guard !isIndexer else { return }
		// nobody looks: reload once a window shows up again
		if AppActivity.shared.level == .hidden {
			pendingReaderReload = true
			return
		}
		let vNow = Date()
		if let vLast = lastReloadAt, vNow.timeIntervalSince(vLast) < kMinReloadInterval {
			// throttled: catch up when the interval ends instead of
			// dropping the change (the mtime poll has already seen it)
			if !pendingReaderReload {
				pendingReaderReload = true
				let vWait = kMinReloadInterval - vNow.timeIntervalSince(vLast)
				DispatchQueue.main.asyncAfter(deadline: .now() + vWait) { [weak self] in
					guard let vSelf = self, vSelf.pendingReaderReload else { return }
					vSelf.pendingReaderReload = false
					vSelf.reloadFromCache()
				}
			}
			return
		}
		pendingReaderReload = false
		lastReloadAt = vNow
		let vUrl = IndexStore.cacheURL(forServiceMode: bootMode)
		let vCurrentEventId = lastEventId
		let vCurrentCount = records.count
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

	// installs a whole new index (cache load, reindex, reload). Its records
	// show at once; changes queued before it are dropped (stale generation)
	private func replaceIndex(inState: IndexState) {
		records = inState.records
		indexGeneration &+= 1
		let vBox = indexBox
		mutateQueue.async {
			vBox.state = inState
		}
		publishRecords()
	}

	// runs inWork on the index on mutateQueue (after every change queued
	// before it), then on main installs the resulting records and calls
	// inDone with inWork's result. When the index was replaced meanwhile
	// (replaceIndex, configuration change), the result is stale: neither
	// happens. inFinally runs on main in every case.
	private func mutateIndex<R>(_ inWork: @escaping (inout IndexState) -> R,
								inFinally: (() -> Void)? = nil,
								inDone: @escaping (R) -> Void) {
		let vBox = indexBox
		let vGeneration = indexGeneration
		mutateQueue.async { [weak self] in
			let vResult = inWork(&vBox.state)
			let vRecords = vBox.state.records
			DispatchQueue.main.async {
				defer { inFinally?() }
				guard let vSelf = self, vSelf.indexGeneration == vGeneration else { return }
				vSelf.records = vRecords
				inDone(vResult)
			}
		}
	}

	// answers inWork from the index on mutateQueue (after every change
	// queued before it), then calls inDone on main with the answer
	private func readIndex<R>(_ inWork: @escaping (IndexState) -> R,
							  inDone: @escaping (R) -> Void) {
		let vBox = indexBox
		mutateQueue.async {
			let vResult = inWork(vBox.state)
			DispatchQueue.main.async {
				inDone(vResult)
			}
		}
	}

	// notifies observers that the records changed
	private func publishRecords() {
		lastIndexChangeAt = Date()
		if indexedCount != records.count {
			indexedCount = records.count
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
