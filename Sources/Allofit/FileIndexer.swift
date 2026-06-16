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
		.nameKey,
		.isDirectoryKey,
		.fileSizeKey,
		.creationDateKey,
		.contentModificationDateKey,
		.fileResourceIdentifierKey
	]

	// recursively walks inRoot, yielding records in batches via inBatch.
	// The batched form lets long scans publish partial progress: the daemon
	// can have its autosave write what it has so far while the rest of the
	// filesystem is still being walked. Excluded paths and their descendants
	// are pruned from the output.
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

		// include the root directory itself in the first batch
		if let vRootRecord = makeRecord(inURL: inRoot) {
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

				if let vRecord = makeRecord(inURL: vURL) {
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

	// convenience wrapper that materializes the full record list. Used by the
	// GUI's in-process reindex (which builds everything before swapping the
	// index in atomically). For the daemon, prefer walkRoot directly so the
	// in-memory index grows incrementally and the autosave can persist partial
	// progress while the scan continues.
	static func indexRoot(inRoot: URL,
						  inExclusions: ExclusionMatcher? = nil,
						  inProgress: ((Int) -> Void)? = nil) -> [FileRecord] {
		var vRecords: [FileRecord] = []
		vRecords.reserveCapacity(100_000)
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

	// builds a FileRecord from a URL's pre-fetched resource values.
	// Clears the URL's resource-value cache first so we always re-stat the
	// file - a file modified between two FSEvents batches would otherwise
	// silently return the cached pre-edit mtime. The whole body is wrapped
	// in autoreleasepool so the autoreleased NSDate / NSNumber / NSURL
	// objects returned by resourceValues() are released at function exit
	// rather than at the caller's pool drain.
	static func makeRecord(inURL: URL) -> FileRecord? {
		return autoreleasepool { () -> FileRecord? in
			makeRecord_impl(inURL: inURL)
		}
	}

	private static func makeRecord_impl(inURL: URL) -> FileRecord? {
		var vUrl = inURL
		vUrl.removeAllCachedResourceValues()
		guard let vValues = try? vUrl.resourceValues(forKeys: Set(kPrefetchKeys)) else {
			return nil
		}
		let vName = vValues.name ?? inURL.lastPathComponent
		let vParent = inURL.deletingLastPathComponent().path
		let vIsDir = vValues.isDirectory ?? false
		let vSize = Int64(vValues.fileSize ?? 0)
		let vCreated = vValues.creationDate ?? .distantPast
		let vModified = vValues.contentModificationDate ?? .distantPast
		// derive a stable identifier from the absolute path
		var vHasher = Hasher()
		vHasher.combine(inURL.path)
		let vId = UInt64(bitPattern: Int64(vHasher.finalize()))
		return FileRecord(
			id: vId,
			name: vName,
			parentPath: vParent,
			size: vSize,
			dateCreated: vCreated,
			dateModified: vModified,
			isDirectory: vIsDir
		)
	}
}
