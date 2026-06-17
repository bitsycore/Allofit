import Foundation
import CoreServices
import Darwin

// AllofitService is the headless runtime invoked by launchd when the binary
// is launched with the --service argument. It builds an initial index, then
// listens to FSEvents and writes the cache to disk every few seconds.
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
		var records: [FileRecord] = []
		var pathIndex: [String: Int] = [:]
		var dirty: Bool = false
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
		let vRoots = VolumeManager.effectiveRoots(inPreferences: vPrefs)
		let vMatcher = ExclusionMatcher(inExclusions: vPrefs.excludedPaths)
		// log the actual configuration so the user can verify owner-prefs sync
		// (root daemon reads from /Users/<owner>/Library/Preferences/...)
		NSLog("[Allofit] roots: %@", vRoots.map { $0.path }.joined(separator: ", "))
		NSLog("[Allofit] excluded paths (%d): %@",
			  vPrefs.excludedPaths.count,
			  vPrefs.excludedPaths.joined(separator: ", "))

		let vState = State()

		// initial scan: streaming the walker through the shared state lock so
		// the autosave thread (every 3s) can write partial progress while we
		// continue walking. Without this, large filesystems leave the cache
		// empty for many minutes and the GUI shows nothing.
		//
		// Both the per-root and per-batch callback bodies run inside their
		// own autoreleasepool so the autoreleased NSURL / NSDate / NSNumber
		// from the file enumeration don't pile up until the entire scan
		// finishes - on a million-file scan that "pile" was peaking at
		// well over a gig of dead allocations before the main thread's
		// runloop got a chance to drain.
		let vStartId = UInt64(FSEventsGetCurrentEventId())
		for vRoot in vRoots {
			autoreleasepool {
				NSLog("[Allofit] scanning %@", vRoot.path)
				FileIndexer.walkRoot(inRoot: vRoot, inExclusions: vMatcher) { vBatch in
					autoreleasepool {
						vState.lock.lock()
						for vRec in vBatch {
							if vMatcher.isExcluded(inPath: vRec.fullPath) { continue }
							if vState.pathIndex[vRec.fullPath] == nil {
								vState.pathIndex[vRec.fullPath] = vState.records.count
								vState.records.append(vRec)
							}
						}
						vState.dirty = true
						vState.lock.unlock()
					}
				}
				NSLog("[Allofit] scanned %@: %d total entries so far", vRoot.path, vState.records.count)
			}
		}
		// force one save right after the scan finishes, so the GUI sees a
		// stable count even if no FSEvents come in for a while afterwards
		IndexStore.save(inRecords: vState.records, inLastEventId: vStartId)
		NSLog("[Allofit] initial scan complete (%d entries)", vState.records.count)

		// FSEvents watcher
		let vWatcher = FileWatcher()
		NSLog("[Allofit] starting FSEvents watcher on %d root(s)", vRoots.count)
		vWatcher.start(
			inRoots: vRoots.map { $0.path },
			inSinceWhen: FSEventStreamEventId(vStartId)
		) { vChanges in
			NSLog("[Allofit] FSEvents batch: %d change(s) (sample: %@)",
				  vChanges.count,
				  vChanges.first?.path ?? "—")
			vState.lock.lock()
			defer { vState.lock.unlock() }
			var vRescanPrefixes: [String] = []
			var vAdded = 0
			var vUpdated = 0
			// batch removals into a set so we do one bulk allRecords pass
			// and rebuild pathIndex once per FSEvents batch, instead of
			// O(records) per individual removal - that nested rebuild was
			// dominating CPU and turning into the daemon's memory churn
			var vRemoved: Set<String> = []

			// Per-change autoreleasepool: a large FSEvents batch (e.g.
			// `rm -rf` of a deep tree) can deliver thousands of paths in
			// one callback. Each path's NSURL + reachability check + the
			// makeRecord internals autorelease - per-change drain keeps
			// peak memory bounded by a single record's worth, not the
			// whole batch.
			for vChange in vChanges {
				autoreleasepool {
					if vMatcher.isExcluded(inPath: vChange.path) { return }
					if vChange.mustScanSubDirs {
						vRescanPrefixes.append(vChange.path)
						return
					}
					// skip paths we've already queued for removal in this batch
					if vRemoved.contains(vChange.path) { return }
					let vUrl = URL(fileURLWithPath: vChange.path)
					let vExists = (try? vUrl.checkResourceIsReachable()) ?? false
					if vExists, let vRec = FileIndexer.makeRecord(inURL: vUrl) {
						if let vIdx = vState.pathIndex[vRec.fullPath] {
							vState.records[vIdx] = vRec
							vUpdated += 1
						} else {
							vState.pathIndex[vRec.fullPath] = vState.records.count
							vState.records.append(vRec)
							vAdded += 1
						}
					} else if vState.pathIndex[vChange.path] != nil {
						vRemoved.insert(vChange.path)
					}
				}
			}

			if !vRemoved.isEmpty {
				// single bulk removeAll + single pathIndex rebuild
				vState.records.removeAll { vRemoved.contains($0.fullPath) }
				rebuildPathIndex(vState)
			}

			if vAdded + vUpdated + vRemoved.count > 0 {
				NSLog("[Allofit] applied: +%d / ~%d / -%d (total %d)",
					  vAdded, vUpdated, vRemoved.count, vState.records.count)
			}

			if !vRescanPrefixes.isEmpty {
				NSLog("[Allofit] rescanning \(vRescanPrefixes.count) subtree(s) (history lost)")
				let vNormalized = vRescanPrefixes.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
				vState.records.removeAll { vRec in
					let vP = vRec.fullPath
					for vPre in vNormalized where vP == String(vPre.dropLast()) || vP.hasPrefix(vPre) {
						return true
					}
					return false
				}
				for vPath in vRescanPrefixes {
					let vList = FileIndexer.indexRoot(
						inRoot: URL(fileURLWithPath: vPath),
						inExclusions: vMatcher
					)
					vState.records.append(contentsOf: vList)
				}
				rebuildPathIndex(vState)
			}

			vState.dirty = true
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
		DispatchQueue.global(qos: .utility).async {
			let kCompactEvery = 20
			var vSavesSinceCompact = 0
			while true {
				sleep(3)
				autoreleasepool {
					vState.lock.lock()
					let vShouldSave = vState.dirty
					let vSnapshot = vState.records
					vState.dirty = false
					vState.lock.unlock()
					if !vShouldSave { return }
					NSLog("[Allofit] autosaving %d records (RSS %.1f MB)",
						  vSnapshot.count, processFootprintMB())
					IndexStore.save(
						inRecords: vSnapshot,
						inLastEventId: vWatcher.latestEventId
					)
					vSavesSinceCompact += 1
					if vSavesSinceCompact >= kCompactEvery {
						vSavesSinceCompact = 0
						compactContainers(vState)
					}
				}
			}
		}

		// block forever on the runloop so launchd keeps us alive
		RunLoop.current.run()
		exit(0)
	}

	// rebuilds pathIndex from records. Used after a bulk allRecords mutation
	// (batched removal or subtree rescan) - much cheaper than incrementally
	// maintaining pathIndex during the mutation, and the reserveCapacity
	// lets the dict size to its target without re-bucketing on each insert.
	private static func rebuildPathIndex(_ inState: State) {
		var vIndex: [String: Int] = [:]
		vIndex.reserveCapacity(inState.records.count)
		for (vI, vR) in inState.records.enumerated() {
			vIndex[vR.fullPath] = vI
		}
		inState.pathIndex = vIndex
	}

	// recreates records and pathIndex with capacities matched to their
	// actual element count. Swift Array/Dict only grow their backing
	// allocations under churn, never auto-shrink, so a daemon that's
	// been processing FSEvents for days can hold huge dead capacity
	// (records.capacity >> records.count) that shows up as multi-GB
	// RSS. Forcing fresh containers reclaims it.
	private static func compactContainers(_ inState: State) {
		inState.lock.lock()
		defer { inState.lock.unlock() }
		let vBefore = processFootprintMB()
		// Array(_:) creates a fresh array sized exactly to the source -
		// the old buffer's slack capacity is released
		let vCompactRecords = Array(inState.records)
		var vCompactIndex: [String: Int] = [:]
		vCompactIndex.reserveCapacity(vCompactRecords.count)
		for (vI, vR) in vCompactRecords.enumerated() {
			vCompactIndex[vR.fullPath] = vI
		}
		inState.records = vCompactRecords
		inState.pathIndex = vCompactIndex
		let vAfter = processFootprintMB()
		NSLog("[Allofit] compacted (%d records, RSS %.1f → %.1f MB)",
			  vCompactRecords.count, vBefore, vAfter)
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
