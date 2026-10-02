import Foundation

// RecordStore holds the index's records in fixed-size chunks instead of one
// flat array. Copies (snapshots for searches and result lists) only share
// chunk buffers, and a mutation copies just the chunk it touches: changing
// one record while a snapshot is alive costs ~1.6 MB instead of the whole
// 60+ MB index. That lets every window keep its results as plain positions
// into a snapshot, at 4 bytes per row.
struct RecordStore: RandomAccessCollection, MutableCollection, Sendable {

	// records per chunk: 2^kShift
	static let kShift = 14
	// chunk size and index mask derived from kShift
	static let kChunkSize = 1 << kShift
	static let kMask = kChunkSize - 1

	// the records, kChunkSize per chunk (the last one may be shorter)
	private var chunks: [[FileRecord]] = []
	// total number of records
	private(set) var count: Int = 0

	// empty store
	init() {}

	// store holding inRecords, in order
	init<S: Sequence>(_ inRecords: S) where S.Element == FileRecord {
		for vRecord in inRecords {
			append(vRecord)
		}
	}

	// first index (always 0)
	var startIndex: Int { 0 }
	// one past the last index
	var endIndex: Int { count }

	// record at inPosition
	subscript(inPosition: Int) -> FileRecord {
		get { chunks[inPosition >> Self.kShift][inPosition & Self.kMask] }
		set { chunks[inPosition >> Self.kShift][inPosition & Self.kMask] = newValue }
	}

	// number of chunks
	var chunkCount: Int { chunks.count }

	// the records of chunk inIndex (store positions inIndex << kShift and
	// up). Hot loops walk chunks to read records with plain array access.
	func chunk(at inIndex: Int) -> [FileRecord] {
		return chunks[inIndex]
	}

	// adds a record at the end
	mutating func append(_ inRecord: FileRecord) {
		if chunks.isEmpty || chunks[chunks.count - 1].count == Self.kChunkSize {
			var vChunk: [FileRecord] = []
			vChunk.reserveCapacity(Self.kChunkSize)
			chunks.append(vChunk)
		}
		chunks[chunks.count - 1].append(inRecord)
		count += 1
	}

	// removes the last record
	mutating func removeLast() {
		chunks[chunks.count - 1].removeLast()
		count -= 1
		if chunks[chunks.count - 1].isEmpty {
			chunks.removeLast()
		}
	}
}

// ResultList is one window's search result: positions into a snapshot of
// the index, in display order. Cheap to keep around (4 bytes per row) and
// immune to later index changes, since the snapshot doesn't move.
struct ResultList: RandomAccessCollection, Sendable {

	// the index as it was when the search ran
	let store: RecordStore
	// positions of the matching records in store, sorted for display
	let positions: [Int32]

	// empty result
	init() {
		store = RecordStore()
		positions = []
	}

	// result for the given snapshot and positions
	init(inStore: RecordStore, inPositions: [Int32]) {
		store = inStore
		positions = inPositions
	}

	// first index (always 0)
	var startIndex: Int { 0 }
	// number of results
	var endIndex: Int { positions.count }

	// record shown at inRow
	subscript(inRow: Int) -> FileRecord {
		return store[Int(positions[inRow])]
	}

	// the same list without the records whose ids are in inIds
	func removing(inIds: Set<FileRecord.ID>) -> ResultList {
		return ResultList(inStore: store, inPositions: positions.filter { !inIds.contains(store[Int($0)].id) })
	}
}
