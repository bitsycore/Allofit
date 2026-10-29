import Foundation

// ResolvedChanges is a coalesced set of FSEvents changes whose filesystem
// lookups (stat) are already done, so merging it into an IndexState is pure
// in-memory bookkeeping. Built off the main thread by IndexState.resolve.
struct ResolvedChanges: Sendable {
	// fresh records for reported paths that exist and are indexable
	var upserts: [FileRecord] = []
	// reported paths that are gone (or no longer indexable: hidden, excluded)
	var removals: [String] = []
	// subtrees the kernel asked us to rescan (history lost / coalesced)
	var rescans: [String] = []
	// highest FSEvents id covered by this set of changes
	var maxEventId: UInt64 = 0
	// true when the end-of-replay marker was part of this set
	var historyDone = false
}

// IndexState is the in-memory index: the record array plus an id -> position
// lookup. Records are kept in no particular order (search results are sorted
// on demand), which lets removals swap the last element into the hole in O(1)
// instead of shifting the array and rebuilding the whole lookup.
//
// Indexing rules shared by the initial walk and live updates:
//   - a record is only kept if its parent directory is itself indexed (or it
//     is a root). That mirrors the walker skipping hidden directories,
//     package contents and exclusions without re-checking every ancestor.
//   - removing a directory removes everything below it (a folder moved to the
//     Trash only produces one FSEvents entry for the folder itself).
//   - a directory that appears (created, moved or renamed in) is rescanned,
//     since FSEvents does not report the entries moved along with it.
//
// Value type: callers own it on one thread (AppModel on main, the service
// under its lock).
struct IndexState {

	// all indexed entries, unordered
	// (chunked: snapshots are cheap and a change copies only one chunk)
	private(set) var records = RecordStore()
	// FileRecord.id -> position in records
	private(set) var positions: [UInt64: Int] = [:]

	// builds the state from a list of records, dropping duplicate paths
	init(inRecords: [FileRecord] = []) {
		positions.reserveCapacity(inRecords.count)
		for vRecord in inRecords where positions[vRecord.id] == nil {
			positions[vRecord.id] = records.count
			records.append(vRecord)
		}
	}

	// number of indexed entries
	var count: Int { records.count }

	// true when the given absolute path is indexed
	func contains(inPath: String) -> Bool {
		return positions[FileRecord.pathHash(inPath)] != nil
	}

	// ===========================
	// MARK: Mutations
	// ===========================

	// inserts or replaces a record; returns true if the index changed
	@discardableResult
	mutating func upsert(_ inRecord: FileRecord) -> Bool {
		if let vPos = positions[inRecord.id] {
			if records[vPos] == inRecord { return false }
			records[vPos] = inRecord
			return true
		}
		positions[inRecord.id] = records.count
		records.append(inRecord)
		return true
	}

	// removes the records at the given positions (swap-with-last, O(k))
	private mutating func remove(inPositions: [Int]) {
		for vPos in inPositions.sorted(by: >) {
			let vRemovedId = records[vPos].id
			let vLast = records.count - 1
			if vPos != vLast {
				let vMoved = records[vLast]
				records[vPos] = vMoved
				positions[vMoved.id] = vPos
			}
			records.removeLast()
			positions.removeValue(forKey: vRemovedId)
		}
	}

	// removes each path and, for directories, everything below it.
	// Returns the number of records removed.
	@discardableResult
	mutating func removeSubtrees(inPaths: [String]) -> Int {
		let vPositions = subtreePositions(inPaths: inPaths)
		remove(inPositions: Array(vPositions))
		return vPositions.count
	}

	// positions of the records removeSubtrees(inPaths:) would remove
	private func subtreePositions(inPaths: [String]) -> Set<Int> {
		var vPositions = Set<Int>()
		var vDirPrefixes: [String] = []
		for vPath in inPaths {
			guard let vPos = positions[FileRecord.pathHash(vPath)] else { continue }
			vPositions.insert(vPos)
			if records[vPos].isDirectory {
				vDirPrefixes.append(vPath)
			}
		}
		if !vDirPrefixes.isEmpty {
			let vMatcher = SubtreeMatcher(inRoots: vDirPrefixes)
			for (vPos, vRecord) in records.enumerated() where vMatcher.containsChild(inParentPath: vRecord.parentPath) {
				vPositions.insert(vPos)
			}
		}
		return vPositions
	}

	// number of records at or below inRoot, and at or below one of
	// inWithin's folders when given
	func count(inRoot: String, inWithin: SubtreeMatcher? = nil) -> Int {
		let vRoot = SubtreeMatcher(inRoots: [inRoot])
		var vCount = 0
		for vRecord in records where vRoot.covers(inRecord: vRecord) {
			if let vWithin = inWithin, !vWithin.covers(inRecord: vRecord) { continue }
			vCount += 1
		}
		return vCount
	}

	// replaces everything at and below each root with the given records
	// (the result of re-walking those subtrees). Subtrees of an offline
	// root of inGuard are left as they are, as are those of a protected
	// root the new records would wipe. Returns the roots spared that way.
	@discardableResult
	mutating func replaceSubtrees(inRoots: [String],
								  inRecords: [FileRecord],
								  inGuard: RootGuard = RootGuard()) -> [String] {
		var vRoots = inRoots
		var vRecords = inRecords
		var vSpared: [String] = []
		if !inGuard.isEmpty {
			// a walked folder of an offline root found nothing real
			vRoots.removeAll { inGuard.isOffline(inPath: $0) }
			for vProtected in inGuard.protected {
				let vTouching = vRoots.filter {
					RootGuard.isAtOrBelow(inPath: $0, inRoot: vProtected) || RootGuard.isAtOrBelow(inPath: vProtected, inRoot: $0)
				}
				guard !vTouching.isEmpty else { continue }
				let vReplaced = SubtreeMatcher(inRoots: vTouching)
				let vRootMatcher = SubtreeMatcher(inRoots: [vProtected])
				let vBefore = count(inRoot: vProtected)
				let vRemoved = count(inRoot: vProtected, inWithin: vReplaced)
				let vAdded = vRecords.filter { vRootMatcher.covers(inRecord: $0) && vReplaced.covers(inRecord: $0) }.count
				if RootGuard.isWipe(inBefore: vBefore, inAfter: vBefore - vRemoved + vAdded) {
					vSpared.append(vProtected)
					vRoots.removeAll { vTouching.contains($0) }
				}
			}
			if vRoots.count != inRoots.count {
				let vKept = SubtreeMatcher(inRoots: vRoots)
				vRecords.removeAll { !vKept.covers(inRecord: $0) }
			}
		}
		guard !vRoots.isEmpty else { return vSpared }
		let vMatcher = SubtreeMatcher(inRoots: vRoots)
		var vPositions: [Int] = []
		for (vPos, vRecord) in records.enumerated() {
			if vMatcher.containsChild(inParentPath: vRecord.parentPath) || vMatcher.isRoot(inRecord: vRecord) {
				vPositions.append(vPos)
			}
		}
		remove(inPositions: vPositions)
		for vRecord in vRecords {
			upsert(vRecord)
		}
		return vSpared
	}

	// merges resolved FSEvents changes. Returns whether anything changed,
	// the subtrees that must be (re)walked (kernel-requested rescans plus
	// directories that newly appeared) and the protected roots of inGuard
	// whose wipe was refused. inRoots are the configured roots, whose own
	// records are allowed without an indexed parent.
	mutating func apply(inChanges: ResolvedChanges,
						inRoots: Set<String>,
						inGuard: RootGuard = RootGuard())
		-> (changed: Bool, rescans: [String], newFolders: [String], spared: [String]) {
		var vChanged = false
		var vRescans: [String] = []
		var vNewFolders: [String] = []

		// removals first: a rename shows up as old path gone + new path present
		let (vRemovals, vSpared) = guardRemovals(inPaths: inChanges.removals, inGuard: inGuard)
		if !vRemovals.isEmpty {
			vChanged = removeSubtrees(inPaths: vRemovals) > 0 || vChanged
		}

		// parents before children, so a new folder and its new files arriving
		// in the same batch are accepted in one pass
		let vUpserts = inChanges.upserts.sorted { $0.parentPath.utf8.count < $1.parentPath.utf8.count }
		for vRecord in vUpserts {
			let vIsRoot = inRoots.contains(vRecord.fullPath)
			guard vIsRoot || contains(inPath: vRecord.parentPath) else { continue }
			let vIsNew = positions[vRecord.id] == nil
			// a folder that just appeared is not added here: its walk adds
			// it (with its contents) once complete. Until then it looks
			// missing, so an interrupted walk is redone on the next launch
			// or replay instead of leaving a folder with partial contents.
			if vIsNew && vRecord.isDirectory {
				vNewFolders.append(vRecord.fullPath)
				continue
			}
			if upsert(vRecord) { vChanged = true }
		}

		// kernel rescans only for subtrees that belong to the index
		for vPath in inChanges.rescans where inRoots.contains(vPath) || contains(inPath: vPath) {
			vRescans.append(vPath)
		}
		let vMinimalRescans = SubtreeMatcher.minimalRoots(inPaths: vRescans)
		// a new folder inside a kernel rescan is walked by that rescan
		let vCovered = SubtreeMatcher(inRoots: vMinimalRescans)
		let vFolders = SubtreeMatcher.minimalRoots(inPaths: vNewFolders).filter { vFolder in
			!vMinimalRescans.contains(vFolder) && !vCovered.containsChild(inParentPath: (vFolder as NSString).deletingLastPathComponent)
		}
		return (vChanged, vMinimalRescans, vFolders, vSpared)
	}

	// drops the removals that would wipe a protected root of inGuard: the
	// root itself (or a folder above it), or a batch taking more than
	// RootGuard.kMaxRemovedShare of its entries. Returns the removals to
	// apply and the roots spared.
	private func guardRemovals(inPaths: [String], inGuard: RootGuard) -> (kept: [String], spared: [String]) {
		guard !inGuard.protected.isEmpty, !inPaths.isEmpty else { return (inPaths, []) }
		var vKept: [String] = []
		var vByRoot: [String: [String]] = [:]
		var vSpared = Set<String>()
		for vPath in inPaths {
			if let vRoot = inGuard.protectedRootRemoved(by: vPath) {
				if contains(inPath: vRoot) { vSpared.insert(vRoot) }
			} else if let vRoot = inGuard.protectedRoot(of: vPath) {
				vByRoot[vRoot, default: []].append(vPath)
			} else {
				vKept.append(vPath)
			}
		}
		for (vRoot, vPaths) in vByRoot {
			let vRemoved = subtreePositions(inPaths: vPaths).count
			if vRemoved >= RootGuard.kMinimumWipe {
				let vBefore = count(inRoot: vRoot)
				if RootGuard.isWipe(inBefore: vBefore, inAfter: vBefore - vRemoved) {
					vSpared.insert(vRoot)
					continue
				}
			}
			vKept.append(contentsOf: vPaths)
		}
		return (vKept, Array(vSpared))
	}

	// adds the records found by walking folders that just appeared. Nothing
	// below such a folder can be indexed yet (except entries upserted from
	// the same FSEvents batch, which upsert replaces), so unlike
	// replaceSubtrees no O(n) removal pass over the whole index is needed.
	mutating func mergeNewFolders(inRecords: [FileRecord]) {
		for vRecord in inRecords {
			upsert(vRecord)
		}
	}

	// drops records that fall outside the current configuration: excluded
	// paths, entries under removed roots, entries whose parent isn't indexed,
	// and hidden entries the walker would have skipped (content added by
	// older versions' live updates). Hidden means a dot-name anywhere, or a
	// hidden flag (inIsHidden, e.g. ~/Library) on a folder directly under a
	// root - deeper folders aren't stat'ed so a prune stays cheap even on
	// network roots. Run on load and after the roots/exclusions change.
	// Returns the number removed.
	@discardableResult
	mutating func prune(inRoots: Set<String>,
						inExclusions: ExclusionMatcher,
						inIsHidden: ((String) -> Bool)? = nil) -> Int {
		// visit shallow entries first so a dropped directory takes its
		// descendants with it in the same pass
		let vOrder = records.indices.sorted {
			records[$0].parentPath.utf8.count < records[$1].parentPath.utf8.count
		}
		var vKept = Set<UInt64>()
		vKept.reserveCapacity(records.count)
		var vDrop: [Int] = []
		for vPos in vOrder {
			let vRecord = records[vPos]
			let vFull = vRecord.fullPath
			let vIsRoot = inRoots.contains(vFull)
			var vKeep = vIsRoot || vKept.contains(FileRecord.pathHash(vRecord.parentPath))
			if vKeep && !vIsRoot {
				if vRecord.name.hasPrefix(".") {
					vKeep = false
				} else if vRecord.isDirectory, inRoots.contains(vRecord.parentPath), let vCheck = inIsHidden {
					vKeep = !vCheck(vFull)
				}
			}
			if vKeep && !inExclusions.isExcluded(inPath: vFull) {
				vKept.insert(vRecord.id)
			} else {
				vDrop.append(vPos)
			}
		}
		remove(inPositions: vDrop)
		return vDrop.count
	}

	// returns a copy with array/dictionary capacity trimmed to the content.
	// Swift collections never shrink on their own, so after heavy churn
	// the slack can amount to hundreds of MB.
	func compacted() -> IndexState {
		var vResult = IndexState()
		vResult.records = RecordStore(records)
		vResult.positions = Dictionary(minimumCapacity: positions.count)
		for (vKey, vValue) in positions {
			vResult.positions[vKey] = vValue
		}
		return vResult
	}

	// ===========================
	// MARK: Change resolution
	// ===========================

	// resolves raw FSEvents changes against the filesystem. Each unique path
	// is stat'ed once however many times it was reported (a multi-day replay
	// repeats hot files thousands of times). Changes below an offline root of
	// inGuard are dropped: its volume isn't mounted, so its files only look
	// gone. Safe to call on any thread.
	static func resolve(inChanges: [FSChange],
						inExclusions: ExclusionMatcher,
						inGuard: RootGuard = RootGuard()) -> ResolvedChanges {
		var vResult = ResolvedChanges()
		var vSeen = Set<String>()
		var vRescanSeen = Set<String>()
		var vPaths: [String] = []
		for vChange in inChanges {
			vResult.maxEventId = max(vResult.maxEventId, UInt64(vChange.eventId))
			if vChange.isHistoryDone {
				vResult.historyDone = true
				continue
			}
			if vChange.isVolumeEvent || inGuard.isOffline(inPath: vChange.path) {
				continue
			}
			if vChange.mustScanSubDirs {
				if !inExclusions.isExcluded(inPath: vChange.path), vRescanSeen.insert(vChange.path).inserted {
					vResult.rescans.append(vChange.path)
				}
				continue
			}
			if vSeen.insert(vChange.path).inserted {
				vPaths.append(vChange.path)
			}
		}

		// package check cache: the walker doesn't descend into bundles, so
		// changes inside a .app / .photoslibrary / ... are dropped as well
		var vPackageCache: [String: Bool] = [:]
		for vPath in vPaths {
			// per-path pool: the URL + resourceValues objects autorelease
			autoreleasepool {
				if inExclusions.isExcluded(inPath: vPath) {
					vResult.removals.append(vPath)
					return
				}
				let vUrl = URL(fileURLWithPath: vPath)
				let vParent = vUrl.deletingLastPathComponent().path
				let vInPackage: Bool
				if let vCached = vPackageCache[vParent] {
					vInPackage = vCached
				} else {
					let vValues = try? URL(fileURLWithPath: vParent, isDirectory: true)
						.resourceValues(forKeys: [.isPackageKey])
					vInPackage = vValues?.isPackage ?? false
					vPackageCache[vParent] = vInPackage
				}
				if !vInPackage, let vRecord = FileIndexer.makeRecord(inURL: vUrl, inSkipHidden: true) {
					vResult.upserts.append(vRecord)
				} else {
					// normalized form (no trailing slash) so it hashes like the record
					vResult.removals.append(vUrl.path)
				}
			}
		}
		return vResult
	}
}

// SubtreeMatcher answers "is this entry at or below one of these
// directories?" using byte-level prefix checks on the parent path, so the
// O(n) passes over the index don't allocate a full path per record.
struct SubtreeMatcher {

	// root directories without trailing slash ("/" kept as is)
	private let roots: [String]
	// roots with a trailing slash, for descendant checks
	private let prefixes: [[UInt8]]
	// record ids of the roots themselves
	private let rootIds: Set<UInt64>

	// builds a matcher for the given directory paths
	init(inRoots: [String]) {
		roots = inRoots.map { ($0.count > 1 && $0.hasSuffix("/")) ? String($0.dropLast()) : $0 }
		prefixes = roots.map { Array(($0 == "/" ? "/" : $0 + "/").utf8) }
		rootIds = Set(roots.map { FileRecord.pathHash($0) })
	}

	// true if a record whose parent is inParentPath lies below a root
	// (the root directory's own record is matched by isRoot instead)
	func containsChild(inParentPath: String) -> Bool {
		for (vI, vRoot) in roots.enumerated() {
			if inParentPath == vRoot { return true }
			if inParentPath.utf8.starts(with: prefixes[vI]) { return true }
		}
		return false
	}

	// true if the record is one of the roots itself
	func isRoot(inRecord: FileRecord) -> Bool {
		return rootIds.contains(inRecord.id)
	}

	// true if the record is one of the roots or lies below one
	func covers(inRecord: FileRecord) -> Bool {
		return isRoot(inRecord: inRecord) || containsChild(inParentPath: inRecord.parentPath)
	}

	// removes duplicates and paths nested under another path of the list,
	// so overlapping subtrees are only walked once
	static func minimalRoots(inPaths: [String]) -> [String] {
		var vResult: [String] = []
		for vPath in Set(inPaths).sorted(by: { $0.utf8.count < $1.utf8.count }) {
			let vCovered = vResult.contains { vRoot in
				vRoot == "/" || vPath == vRoot || vPath.hasPrefix(vRoot + "/")
			}
			if !vCovered { vResult.append(vPath) }
		}
		return vResult
	}
}
