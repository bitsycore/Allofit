import Foundation
import CoreServices
import Darwin

// AllofitService is the headless runtime invoked by launchd when the binary
// is launched with the --service argument. It resumes from its cache (or
// builds an initial index), then listens to FSEvents and writes the cache to
// disk every few seconds.
//
// Holds a POSIX advisory lock on indexer.lock so a stray second instance
// (a leftover launchd job, or someone running --service manually) exits
// quietly instead of fighting for the cache file.
enum AllofitService {

	// Shared mutable state across the FSEvents callback queue and the
	// autosave loop. Wrapped in a class so closures capture by reference
	// and Swift 6's @Sendable closures can hold it cleanly. @unchecked
	// Sendable because every access goes through the NSLock below.
	private final class State: @unchecked Sendable {
		// the in-memory index (same rules as the GUI's built-in indexer)
		var index = IndexState()
		// true when the index changed since the last save
		var dirty: Bool = false
		// FSEvents id the index is complete up to. 0 while an initial walk
		// is in progress, so a partial cache saved mid-scan is never taken
		// for a complete one on the next start.
		var lastEventId: UInt64 = 0
		// guards every field above
		let lock = NSLock()
	}

	// runs the indexer/watcher loop forever (never returns)
	static func run() -> Never {
		// ensure files we create are world-readable (root daemon writes the
		// cache; the GUI runs as the user and must be able to read it)
		umask(0o022)
		NSLog("[Allofit] service starting (uid=\(getuid()))")

		// figure out whether we are the root daemon writing to /Library or
		// the user agent writing to ~/Library, then acquire the lock
		let vIsSystem = ProcessInfo.processInfo.environment["ALLOFIT_SYSTEM_INDEX"] == "1"
		let vLock = IndexerLock(path: IndexStore.lockURL(forSystem: vIsSystem).path)
		if !vLock.tryLock() {
			let vHolder = IndexerLock.readHolderPid(path: vLock.path).map(String.init) ?? "unknown"
			NSLog("[Allofit] another indexer is running (pid \(vHolder)), exiting")
			exit(0)
		}

		let vPrefs = Preferences.shared
		let vRoots = VolumeManager.effectiveRoots(inPreferences: vPrefs).map { $0.path }
		let vRootSet = Set(vRoots)
		let vMatcher = ExclusionMatcher(inExclusions: vPrefs.excludedPaths)
		// log the actual configuration so the user can verify owner-prefs sync
		// (root daemon reads from /Users/<owner>/Library/Preferences/...)
		NSLog("[Allofit] roots: %@", vRoots.joined(separator: ", "))
		NSLog("[Allofit] excluded paths (%d): %@",
			  vPrefs.excludedPaths.count,
			  vPrefs.excludedPaths.joined(separator: ", "))

		let vState = State()

		// fast resume: load the cache, drop what no longer matches the
		// configuration and replay FSEvents from the saved id. Only roots
		// missing from the cache are walked. Without a usable cache (none,
		// incomplete, or an id from another FSEvents database) every root
		// is walked from scratch.
		let vCurrentId = UInt64(FSEventsGetCurrentEventId())
		var vSinceId = vCurrentId
		var vToScan = vRoots
		if let vCache = IndexStore.load(), vCache.lastEventId > 0, vCache.lastEventId <= vCurrentId {
			var vIndex = IndexState(inRecords: vCache.records)
			let vPruned = vIndex.prune(inRoots: vRootSet, inExclusions: vMatcher, inIsHidden: FileIndexer.isHidden)
			vToScan = vRoots.filter { !vIndex.contains(inPath: $0) }
			vSinceId = vCache.lastEventId
			vState.index = vIndex
			vState.dirty = vPruned > 0
			NSLog("[Allofit] resumed %d records from cache (%d pruned), replaying from event %llu",
				  vIndex.count, vPruned, vSinceId)
		}

		// periodic save loop, started before any walk so that a long initial
		// scan publishes partial progress for the GUI
		startAutosaveLoop(inState: vState)

		// walk whatever the cache doesn't cover. The batch callback runs in
		// its own autoreleasepool so the autoreleased NSURL / NSDate /
		// NSNumber from the enumeration don't pile up until the whole scan
		// finishes - on a million-file scan that peaked well over a gig.
		if !vToScan.isEmpty {
			for vRoot in vToScan {
				autoreleasepool {
					NSLog("[Allofit] scanning %@", vRoot)
					FileIndexer.walkRoot(inRoot: URL(fileURLWithPath: vRoot), inExclusions: vMatcher) { vBatch in
						autoreleasepool {
							vState.lock.lock()
							for vRecord in vBatch {
								vState.index.upsert(vRecord)
							}
							vState.dirty = true
							vState.lock.unlock()
						}
					}
				}
			}
			vState.lock.lock()
			let vCount = vState.index.count
			vState.lock.unlock()
			NSLog("[Allofit] scan complete (%d entries)", vCount)
		}
		// the index is now complete up to vSinceId: replaying from there
		// fills in whatever happened during the walk
		vState.lock.lock()
		vState.lastEventId = vSinceId
		vState.dirty = true
		vState.lock.unlock()

		// FSEvents watcher. The callbacks of one stream run serially on
		// its dispatch queue, so resolve / apply / rescan never overlap.
		let vWatcher = FileWatcher()
		NSLog("[Allofit] starting FSEvents watcher on %d root(s)", vRoots.count)
		vWatcher.start(
			inRoots: vRoots,
			inSinceWhen: FSEventStreamEventId(vSinceId)
		) { vChanges in
			autoreleasepool {
				// stat() outside the lock so the autosave isn't blocked
				let vResolved = IndexState.resolve(inChanges: vChanges, inExclusions: vMatcher)
				vState.lock.lock()
				let vResult = vState.index.apply(inChanges: vResolved, inRoots: vRootSet)
				vState.lastEventId = max(vState.lastEventId, vResolved.maxEventId)
				if vResult.changed { vState.dirty = true }
				vState.lock.unlock()
				if vResolved.historyDone {
					NSLog("[Allofit] FSEvents history replay done")
					vState.lock.lock()
					vState.dirty = true
					vState.lock.unlock()
				}

				// folders moved in, or history lost: walk them again
				if !vResult.rescans.isEmpty {
					NSLog("[Allofit] rescanning %d subtree(s)", vResult.rescans.count)
					var vFresh: [FileRecord] = []
					for vPath in vResult.rescans {
						vFresh.append(contentsOf: FileIndexer.indexRoot(
							inRoot: URL(fileURLWithPath: vPath),
							inExclusions: vMatcher
						))
					}
					vState.lock.lock()
					vState.index.replaceSubtrees(inRoots: vResult.rescans, inRecords: vFresh)
					vState.dirty = true
					vState.lock.unlock()
				}
			}
		}

		// block forever on the runloop so launchd keeps us alive
		RunLoop.current.run()
		exit(0)
	}

	// periodic save loop (background thread). 3-second check interval so
	// new files appear in the GUI within a few seconds of being created.
	// Every N saves we also compact the in-memory containers so Swift's
	// Array/Dict capacity (which only grows on churn, never auto-shrinks)
	// doesn't drift into multi-GB territory after a day of heavy file
	// activity. RSS is logged each save so the trajectory is visible.
	//
	// CRITICAL: each iteration runs inside its own autoreleasepool. The
	// outer GCD block has an autorelease pool that drains when the block
	// returns - which for our `while true` never happens. Without an
	// inner pool, every save's autoreleased NSData (returned by
	// .compressed(using: .lz4) and friends) accumulates forever and the
	// daemon's RSS grows by tens of MB per save (500MB+/min in practice).
	private static func startAutosaveLoop(inState: State) {
		DispatchQueue.global(qos: .utility).async {
			let kCompactEvery = 20
			var vSavesSinceCompact = 0
			while true {
				sleep(3)
				autoreleasepool {
					inState.lock.lock()
					let vShouldSave = inState.dirty
					let vSnapshot = inState.index.records
					let vEventId = inState.lastEventId
					inState.dirty = false
					inState.lock.unlock()
					if !vShouldSave { return }
					NSLog("[Allofit] autosaving %d records (RSS %.1f MB)",
						  vSnapshot.count, processFootprintMB())
					IndexStore.save(inRecords: vSnapshot, inLastEventId: vEventId)
					vSavesSinceCompact += 1
					if vSavesSinceCompact >= kCompactEvery {
						vSavesSinceCompact = 0
						compact(inState: inState)
					}
				}
			}
		}
	}

	// replaces the index with a copy whose capacity matches its content,
	// releasing the slack accumulated by days of churn
	private static func compact(inState: State) {
		let vBefore = processFootprintMB()
		inState.lock.lock()
		inState.index = inState.index.compacted()
		let vCount = inState.index.count
		inState.lock.unlock()
		NSLog("[Allofit] compacted (%d records, RSS %.1f → %.1f MB)",
			  vCount, vBefore, processFootprintMB())
	}

	// resident-memory size in MB matching Activity Monitor's "Memory" column
	// on modern macOS (Catalina+). phys_footprint is the kernel's accounting
	// of pages owned by the task minus shared/clean pages.
	private static func processFootprintMB() -> Double {
		var vInfo = task_vm_info_data_t()
		var vCount = mach_msg_type_number_t(
			MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
		)
		let vResult = withUnsafeMutablePointer(to: &vInfo) { vPtr in
			vPtr.withMemoryRebound(to: integer_t.self, capacity: Int(vCount)) { vIntPtr in
				task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), vIntPtr, &vCount)
			}
		}
		if vResult == KERN_SUCCESS {
			return Double(vInfo.phys_footprint) / (1024.0 * 1024.0)
		}
		return -1
	}
}
