import Foundation
import CoreServices

// AllofitService is the headless runtime invoked by launchd when the binary
// is launched with the --service argument. It builds an initial index, then
// listens to FSEvents and writes the cache to disk every few seconds.
//
// Holds a POSIX advisory lock on indexer.lock so a stray second instance
// (a leftover launchd job, or someone running --service manually) exits
// quietly instead of fighting for the cache file.
enum AllofitService {

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

		// shared mutable state guarded by vStateLock
		var vRecords: [FileRecord] = []
		var vPathIndex: [String: Int] = [:]
		var vDirty = false
		let vStateLock = NSLock()

		// initial scan: streaming the walker through the shared state lock so
		// the autosave thread (every 3s) can write partial progress while we
		// continue walking. Without this, large filesystems leave the cache
		// empty for many minutes and the GUI shows nothing.
		let vStartId = UInt64(FSEventsGetCurrentEventId())
		for vRoot in vRoots {
			NSLog("[Allofit] scanning %@", vRoot.path)
			FileIndexer.walkRoot(inRoot: vRoot, inExclusions: vMatcher) { vBatch in
				vStateLock.lock()
				for vRec in vBatch {
					if vMatcher.isExcluded(inPath: vRec.fullPath) { continue }
					if vPathIndex[vRec.fullPath] == nil {
						vPathIndex[vRec.fullPath] = vRecords.count
						vRecords.append(vRec)
					}
				}
				vDirty = true
				vStateLock.unlock()
			}
			NSLog("[Allofit] scanned %@: %d total entries so far", vRoot.path, vRecords.count)
		}
		// force one save right after the scan finishes, so the GUI sees a
		// stable count even if no FSEvents come in for a while afterwards
		IndexStore.save(inRecords: vRecords, inLastEventId: vStartId)
		NSLog("[Allofit] initial scan complete (%d entries)", vRecords.count)

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
			vStateLock.lock()
			defer { vStateLock.unlock() }
			var vRescanPrefixes: [String] = []
			var vAdded = 0
			var vUpdated = 0
			var vRemovedCount = 0

			for vChange in vChanges {
				if vMatcher.isExcluded(inPath: vChange.path) { continue }
				if vChange.mustScanSubDirs {
					vRescanPrefixes.append(vChange.path)
					continue
				}
				let vUrl = URL(fileURLWithPath: vChange.path)
				let vExists = (try? vUrl.checkResourceIsReachable()) ?? false
				if vExists, let vRec = FileIndexer.makeRecord(inURL: vUrl) {
					if let vIdx = vPathIndex[vRec.fullPath] {
						vRecords[vIdx] = vRec
						vUpdated += 1
					} else {
						vPathIndex[vRec.fullPath] = vRecords.count
						vRecords.append(vRec)
						vAdded += 1
					}
				} else if let vIdx = vPathIndex[vChange.path] {
					vRecords.remove(at: vIdx)
					vPathIndex.removeAll(keepingCapacity: true)
					for (vI, vR) in vRecords.enumerated() {
						vPathIndex[vR.fullPath] = vI
					}
					vRemovedCount += 1
				}
			}
			if vAdded + vUpdated + vRemovedCount > 0 {
				NSLog("[Allofit] applied: +%d / ~%d / -%d (total %d)",
					  vAdded, vUpdated, vRemovedCount, vRecords.count)
			}

			if !vRescanPrefixes.isEmpty {
				NSLog("[Allofit] rescanning \(vRescanPrefixes.count) subtree(s) (history lost)")
				let vNormalized = vRescanPrefixes.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
				vRecords.removeAll { vRec in
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
					vRecords.append(contentsOf: vList)
				}
				vPathIndex.removeAll(keepingCapacity: true)
				for (vI, vR) in vRecords.enumerated() {
					vPathIndex[vR.fullPath] = vI
				}
			}

			vDirty = true
		}

		// periodic save loop (background thread). 3-second check interval so
		// new files appear in the GUI within a few seconds of being created,
		// instead of the 30-second window the previous revision had which
		// could read as "the service is not indexing new files".
		DispatchQueue.global(qos: .utility).async {
			while true {
				sleep(3)
				vStateLock.lock()
				let vShouldSave = vDirty
				let vSnapshot = vRecords
				vDirty = false
				vStateLock.unlock()
				if vShouldSave {
					NSLog("[Allofit] autosaving %d records", vSnapshot.count)
					IndexStore.save(
						inRecords: vSnapshot,
						inLastEventId: vWatcher.latestEventId
					)
				}
			}
		}

		// block forever on the runloop so launchd keeps us alive
		RunLoop.current.run()
		exit(0)
	}
}
