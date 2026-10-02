import Foundation

// FileIndexer walks a filesystem root and emits lightweight FileRecord entries.
// It is a stateless utility so it can be invoked safely from any thread.
//
// Pre-fetching a fixed set of URLResourceKey values lets FileManager batch the
// attribute reads through getattrlistbulk under the hood, which is the macOS
// equivalent of the bulk MFT scan that makes voidtools Everything so fast.
enum FileIndexer {

	// the set of resource keys we ask for up front so they are pre-fetched in bulk
	static let kPrefetchKeys: [URLResourceKey] = [
		.isDirectoryKey,
		.fileSizeKey,
		.creationDateKey,
		.contentModificationDateKey,
		.isHiddenKey
	]
	// same keys as a Set, built once instead of per record
	private static let kPrefetchKeySet = Set(kPrefetchKeys)

	// recursively walks inRoot, yielding records in batches via inBatch.
	// The batched form lets long scans publish partial progress: the daemon
	// can have its autosave write what it has so far while the rest of the
	// filesystem is still being walked. Excluded paths and their descendants
	// are pruned from the output, as are hidden entries and package contents.
	static func walkRoot(inRoot: URL,
						  inExclusions: ExclusionMatcher? = nil,
						  inBatchSize: Int = 2000,
						  inBatch: (_ inRecords: [FileRecord]) -> Void) {
		// exclude the root itself
		if let vMatcher = inExclusions, vMatcher.isExcluded(inPath: inRoot.path) {
			return
		}

		guard let vEnumerator = FileManager.default.enumerator(
			at: inRoot,
			includingPropertiesForKeys: kPrefetchKeys,
			options: [.skipsHiddenFiles, .skipsPackageDescendants],
			errorHandler: { (_, _) in true }
		) else {
			return
		}

		var vBatch: [FileRecord] = []
		vBatch.reserveCapacity(inBatchSize)
		// one String per directory instead of one per entry
		let vInterner = PathInterner()

		// include the root directory itself in the first batch
		if let vRootRecord = makeRecord(inURL: inRoot, inInterner: vInterner) {
			vBatch.append(vRootRecord)
		}

		// Per-iteration autoreleasepool: every URL pulled from the
		// enumerator + every resourceValues() read autoreleases an
		// NSURL / NSDate / NSNumber. Without this drain a million-file
		// walk would let those accumulate into hundreds of MB of dead
		// allocations until the enclosing async block exited - and the
		// daemon's enclosing block never exits.
		for vCase in vEnumerator {
			autoreleasepool {
				guard let vURL = vCase as? URL else { return }

				// short-circuit excluded entries (and don't descend into them)
				if let vMatcher = inExclusions, vMatcher.isExcluded(inPath: vURL.path) {
					let vIsDir = (try? vURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
					if vIsDir { vEnumerator.skipDescendants() }
					return
				}

				if let vRecord = makeRecord(inURL: vURL, inInterner: vInterner, inFresh: false) {
					vBatch.append(vRecord)
					if vBatch.count >= inBatchSize {
						inBatch(vBatch)
						vBatch.removeAll(keepingCapacity: true)
					}
				}
			}
		}
		if !vBatch.isEmpty {
			inBatch(vBatch)
		}
	}

	// true when the item at inPath has the hidden flag (UF_HIDDEN or a
	// dot-name) - the same test the walker's .skipsHiddenFiles applies
	static func isHidden(inPath: String) -> Bool {
		return autoreleasepool {
			let vValues = try? URL(fileURLWithPath: inPath).resourceValues(forKeys: [.isHiddenKey])
			return vValues?.isHidden ?? false
		}
	}

	// convenience wrapper that materializes the full record list. Used by the
	// GUI's in-process reindex and subtree rescans. For the daemon, prefer
	// walkRoot directly so the in-memory index grows incrementally and the
	// autosave can persist partial progress while the scan continues.
	static func indexRoot(inRoot: URL,
						  inExclusions: ExclusionMatcher? = nil,
						  inProgress: ((Int) -> Void)? = nil) -> [FileRecord] {
		var vRecords: [FileRecord] = []
		var vLastReport = Date.distantPast
		let kReportInterval: TimeInterval = 0.25
		walkRoot(inRoot: inRoot, inExclusions: inExclusions) { vBatch in
			vRecords.append(contentsOf: vBatch)
			let vNow = Date()
			if vNow.timeIntervalSince(vLastReport) >= kReportInterval {
				inProgress?(vRecords.count)
				vLastReport = vNow
			}
		}
		inProgress?(vRecords.count)
		return vRecords
	}

	// builds a FileRecord from a URL's resource values.
	// inFresh clears the URL's resource-value cache first so we always
	// re-stat the file - a file modified between two FSEvents batches would
	// otherwise silently return the cached pre-edit mtime. The walker passes
	// false because the enumerator's values were just bulk-fetched.
	// inSkipHidden returns nil for hidden entries (dot-files, UF_HIDDEN),
	// matching what the walker's .skipsHiddenFiles does. Callers wrap each
	// invocation in an autoreleasepool.
	static func makeRecord(inURL: URL,
						   inInterner: PathInterner? = nil,
						   inFresh: Bool = true,
						   inSkipHidden: Bool = false) -> FileRecord? {
		var vUrl = inURL
		if inFresh {
			vUrl.removeAllCachedResourceValues()
		}
		guard let vValues = try? vUrl.resourceValues(forKeys: kPrefetchKeySet) else {
			return nil
		}
		if inSkipHidden && (vValues.isHidden ?? false) {
			return nil
		}
		// live updates only: on a case-insensitive volume a case-only
		// rename (Foo -> foo) still resolves the old spelling, which would
		// leave a ghost "Foo" entry. If the name stored on disk differs from
		// the reported path by case only, the reported path is gone.
		if inSkipHidden, let vStored = try? vUrl.resourceValues(forKeys: [.nameKey]).name {
			let vReported = inURL.lastPathComponent
			// .nameKey shows a ":" in an HFS name as "/"; compare composed forms
			let vOnDisk = vStored.replacingOccurrences(of: "/", with: ":").precomposedStringWithCanonicalMapping
			let vAsReported = vReported.precomposedStringWithCanonicalMapping
			if vOnDisk != vAsReported && vOnDisk.lowercased() == vAsReported.lowercased() {
				return nil
			}
		}
		// name/parent come from the path (not .nameKey) so that
		// parentPath + "/" + name always round-trips to the watched path,
		// which is what the id and the parent-is-indexed rule rely on
		let vPath = inURL.path
		let vName: String
		let vParentRaw: String
		if vPath == "/" {
			vName = "/"
			vParentRaw = ""
		} else {
			vName = inURL.lastPathComponent
			vParentRaw = inURL.deletingLastPathComponent().path
		}
		let vParent = inInterner?.intern(vParentRaw)
		return FileRecord(
			name: vName,
			parentPath: vParent?.path ?? vParentRaw,
			parentLower: vParent?.folded,
			size: Int64(vValues.fileSize ?? 0),
			dateCreated: vValues.creationDate ?? .distantPast,
			dateModified: vValues.contentModificationDate ?? .distantPast,
			isDirectory: vValues.isDirectory ?? false
		)
	}
}

// PathInterner hands back one shared String instance per distinct value
// (plus its search form), so the thousands of records of a directory share
// a single parentPath / parentLower buffer instead of each holding a copy. Not thread-safe: use one
// per walk / load.
final class PathInterner {

	// distinct value -> (shared instance, shared search form)
	private var table: [String: (path: String, folded: String)] = [:]

	// returns the shared instance equal to inString and its search form
	func intern(_ inString: String) -> (path: String, folded: String) {
		if let vShared = table[inString] { return vShared }
		let vEntry = (path: inString, folded: FileRecord.sharedSearchForm(of: inString))
		table[inString] = vEntry
		return vEntry
	}
}
