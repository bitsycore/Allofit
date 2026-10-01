import Foundation
import Testing
@testable import Allofit

// Tests for the index bookkeeping rules (IndexState), stable ids, the
// top-N result selection and the cache file round trip.
@Suite("IndexState")
struct IndexStateTests {

	// shorthand for a file record at an absolute path
	static func file(_ inPath: String, size inSize: Int64 = 0) -> FileRecord {
		let vUrl = URL(fileURLWithPath: inPath)
		return FileRecord(
			name: vUrl.lastPathComponent,
			parentPath: vUrl.deletingLastPathComponent().path,
			size: inSize,
			dateCreated: Date(timeIntervalSince1970: 1),
			dateModified: Date(timeIntervalSince1970: 1),
			isDirectory: false
		)
	}

	// shorthand for a directory record at an absolute path
	static func dir(_ inPath: String) -> FileRecord {
		let vUrl = URL(fileURLWithPath: inPath)
		return FileRecord(
			name: vUrl.lastPathComponent,
			parentPath: vUrl.deletingLastPathComponent().path,
			size: 0,
			dateCreated: Date(timeIntervalSince1970: 1),
			dateModified: Date(timeIntervalSince1970: 1),
			isDirectory: true
		)
	}

	// sorted full paths of the state, for readable comparisons
	static func paths(_ inState: IndexState) -> [String] {
		return inState.records.map { $0.fullPath }.sorted()
	}

	// a small tree rooted at /r
	static func sampleState() -> IndexState {
		return IndexState(inRecords: [
			dir("/r"),
			dir("/r/a"),
			file("/r/a/1.txt"),
			dir("/r/a/b"),
			file("/r/a/b/2.txt"),
			file("/r/c.txt")
		])
	}

	@Test func idIsStableAndMatchesPathHash() {
		let vRecord = Self.file("/Users/me/x.txt")
		#expect(vRecord.id == FileRecord.pathHash("/Users/me/x.txt"))
		#expect(FileRecord.pathHash(inParent: "/", inName: "etc") == FileRecord.pathHash("/etc"))
	}

	@Test func duplicatesAreDropped() {
		let vState = IndexState(inRecords: [Self.file("/r/x"), Self.file("/r/x")])
		#expect(vState.count == 1)
	}

	@Test func removingADirectoryRemovesItsSubtree() {
		var vState = Self.sampleState()
		let vRemoved = vState.removeSubtrees(inPaths: ["/r/a"])
		#expect(vRemoved == 4)
		#expect(Self.paths(vState) == ["/r", "/r/c.txt"])
		// lookup stays consistent after swap-removal
		for (vPos, vRecord) in vState.records.enumerated() {
			#expect(vState.positions[vRecord.id] == vPos)
		}
	}

	@Test func siblingWithSharedPrefixIsKept() {
		var vState = IndexState(inRecords: [Self.dir("/r"), Self.dir("/r/a"), Self.file("/r/a/x"), Self.file("/r/ab")])
		vState.removeSubtrees(inPaths: ["/r/a"])
		#expect(Self.paths(vState) == ["/r", "/r/ab"])
	}

	@Test func applyRequiresAnIndexedParentAndRescansNewFolders() {
		var vState = Self.sampleState()
		var vChanges = ResolvedChanges()
		vChanges.upserts = [
			Self.file("/r/a/new.txt"),           // parent indexed: accepted
			Self.file("/r/hidden/x.txt"),        // parent not indexed: dropped
			Self.dir("/r/moved"),                // new folder: accepted + rescanned
			Self.file("/r/moved/inside.txt")     // its parent arrives in the same batch
		]
		let vResult = vState.apply(inChanges: vChanges, inRoots: ["/r"])
		#expect(vResult.changed)
		#expect(vResult.rescans == ["/r/moved"])
		#expect(vState.contains(inPath: "/r/a/new.txt"))
		#expect(!vState.contains(inPath: "/r/hidden/x.txt"))
		#expect(vState.contains(inPath: "/r/moved/inside.txt"))
	}

	@Test func renameRemovesOldSubtree() {
		var vState = Self.sampleState()
		var vChanges = ResolvedChanges()
		vChanges.removals = ["/r/a"]
		vChanges.upserts = [Self.dir("/r/renamed")]
		let vResult = vState.apply(inChanges: vChanges, inRoots: ["/r"])
		#expect(!vState.contains(inPath: "/r/a/b/2.txt"))
		#expect(vResult.rescans == ["/r/renamed"])
	}

	@Test func unchangedUpsertIsNotAChange() {
		var vState = Self.sampleState()
		var vChanges = ResolvedChanges()
		vChanges.upserts = [Self.file("/r/c.txt")]
		#expect(!vState.apply(inChanges: vChanges, inRoots: ["/r"]).changed)
	}

	@Test func pruneDropsOrphansExclusionsAndOldRoots() {
		var vState = Self.sampleState()
		// orphan: parent /r/hidden is not indexed
		vState.upsert(Self.file("/r/hidden/x.txt"))
		// leftover of a root that is no longer configured
		vState.upsert(Self.dir("/old"))
		vState.upsert(Self.file("/old/y.txt"))
		let vRemoved = vState.prune(inRoots: ["/r"], inExclusions: ExclusionMatcher(inExclusions: ["/r/a/b"]))
		#expect(vRemoved == 5)
		#expect(Self.paths(vState) == ["/r", "/r/a", "/r/a/1.txt", "/r/c.txt"])
	}

	@Test func pruneDropsHiddenEntries() {
		var vState = Self.sampleState()
		vState.upsert(Self.dir("/r/Library"))
		vState.upsert(Self.file("/r/Library/deep.txt"))
		vState.upsert(Self.dir("/r/a/.git"))
		vState.upsert(Self.file("/r/a/.git/HEAD"))
		let vRemoved = vState.prune(
			inRoots: ["/r"],
			inExclusions: ExclusionMatcher(inExclusions: []),
			inIsHidden: { $0 == "/r/Library" }
		)
		#expect(vRemoved == 4)
		#expect(Self.paths(vState) == Self.paths(Self.sampleState()))
	}

	@Test func composedAndDecomposedNamesShareAnId() {
		let vComposed = Self.file("/r/Envoy\u{00E9}s.msf")
		let vDecomposed = Self.file("/r/Envoye\u{0301}s.msf")
		#expect(vComposed.id == vDecomposed.id)
		#expect(IndexState(inRecords: [vComposed, vDecomposed]).count == 1)
		#expect(FileRecord.pathHash("/r/Envoye\u{0301}s.msf") == vComposed.id)
	}

	@Test func replaceSubtreesSwapsContent() {
		var vState = Self.sampleState()
		vState.replaceSubtrees(inRoots: ["/r/a"], inRecords: [Self.dir("/r/a"), Self.file("/r/a/fresh.txt")])
		#expect(Self.paths(vState) == ["/r", "/r/a", "/r/a/fresh.txt", "/r/c.txt"])
	}

	@Test func minimalRootsDropsNestedPaths() {
		let vRoots = SubtreeMatcher.minimalRoots(inPaths: ["/a/b", "/a", "/a b/c", "/a", "/c"])
		#expect(vRoots.sorted() == ["/a", "/a b/c", "/c"])
	}

	@Test func topSelectionMatchesFullSort() {
		let vRecords = (0..<5000).map { Self.file("/r/f\($0 % 977)-\($0).txt", size: Int64(($0 * 7919) % 1013)) }
		let vPositions = (0..<Int32(vRecords.count)).map { $0 }
		for vSort in FileSortDescriptor.allCases {
			let vTop = ResultSorter.top(inRecords: vRecords, inPositions: vPositions, inLimit: 100, inDescriptor: vSort)
			let vFull = ResultSorter.top(inRecords: vRecords, inPositions: vPositions, inLimit: vRecords.count, inDescriptor: vSort)
			#expect(vTop.map(\.id) == Array(vFull.prefix(100)).map(\.id), "sort \(vSort.rawValue)")
		}
	}

	@Test func cacheRoundTrip() throws {
		let vUrl = FileManager.default.temporaryDirectory
			.appendingPathComponent("allofit-test-\(UUID().uuidString).bin")
		defer { try? FileManager.default.removeItem(at: vUrl) }
		let vRecords = Self.sampleState().records
		IndexStore.save(inRecords: vRecords, inLastEventId: 42, to: vUrl)
		let vLoaded = try #require(IndexStore.load(from: vUrl))
		#expect(vLoaded.lastEventId == 42)
		#expect(vLoaded.records == vRecords)
	}
}
