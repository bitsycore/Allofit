import Foundation

// ResultSorter orders the matching positions of a search. The full order of
// a large result takes a while (~0.2 s for 600k entries), so the first rows
// can be computed on their own: a bounded max-heap of the best N candidates
// is O(m log N), about one comparison per match once the heap is warm, which
// lets the top of the list appear before the complete sort finishes.
enum ResultSorter {

	// returns the first inLimit records of inPositions, ordered by inDescriptor
	static func top<C: RandomAccessCollection>(inRecords: C,
											   inPositions: [Int32],
											   inLimit: Int,
											   inDescriptor: FileSortDescriptor) -> [FileRecord]
	where C.Index == Int, C.Element == FileRecord {
		return topPositions(inRecords: inRecords, inPositions: inPositions, inLimit: inLimit, inDescriptor: inDescriptor)
			.map { inRecords[Int($0)] }
	}

	// same as top, returning positions into inRecords instead of copies
	static func topPositions<C: RandomAccessCollection>(inRecords: C,
														inPositions: [Int32],
														inLimit: Int,
														inDescriptor: FileSortDescriptor) -> [Int32]
	where C.Index == Int, C.Element == FileRecord {
		let vLess = comparator(for: inDescriptor)
		// strict weak order on positions, ties broken by id for stability
		let vBefore: (Int32, Int32) -> Bool = { vA, vB in
			let vRa = inRecords[Int(vA)]
			let vRb = inRecords[Int(vB)]
			if vLess(vRa, vRb) { return true }
			if vLess(vRb, vRa) { return false }
			return vRa.id < vRb.id
		}

		if inPositions.count <= inLimit {
			return inPositions.sorted(by: vBefore)
		}

		// max-heap (worst candidate on top) of the best inLimit seen so far
		var vHeap = Array(inPositions.prefix(inLimit))
		// restores the heap property downward from inStart
		func siftDown(_ inStart: Int) {
			var vI = inStart
			while true {
				let vLeft = 2 * vI + 1
				if vLeft >= vHeap.count { return }
				var vWorst = vLeft
				let vRight = vLeft + 1
				if vRight < vHeap.count && vBefore(vHeap[vLeft], vHeap[vRight]) { vWorst = vRight }
				if !vBefore(vHeap[vI], vHeap[vWorst]) { return }
				vHeap.swapAt(vI, vWorst)
				vI = vWorst
			}
		}
		for vI in stride(from: vHeap.count / 2 - 1, through: 0, by: -1) {
			siftDown(vI)
		}
		for vPos in inPositions[inLimit...] where vBefore(vPos, vHeap[0]) {
			vHeap[0] = vPos
			siftDown(0)
		}
		return vHeap.sorted(by: vBefore)
	}

	// primary ordering for each sort mode. Names compare on the folded form
	// (plain code-point order: fast, case-insensitive), path sorts by folder
	// then name.
	private static func comparator(for inDescriptor: FileSortDescriptor) -> (FileRecord, FileRecord) -> Bool {
		switch inDescriptor {
			case .nameAscending:
				return { $0.nameLower < $1.nameLower }
			case .nameDescending:
				return { $0.nameLower > $1.nameLower }
			case .sizeAscending:
				return { $0.size < $1.size }
			case .sizeDescending:
				return { $0.size > $1.size }
			case .createdAscending:
				return { $0.dateCreated < $1.dateCreated }
			case .createdDescending:
				return { $0.dateCreated > $1.dateCreated }
			case .modifiedAscending:
				return { $0.dateModified < $1.dateModified }
			case .modifiedDescending:
				return { $0.dateModified > $1.dateModified }
			case .pathAscending:
				return { $0.parentPath != $1.parentPath ? $0.parentPath < $1.parentPath : $0.nameLower < $1.nameLower }
			case .pathDescending:
				return { $0.parentPath != $1.parentPath ? $0.parentPath > $1.parentPath : $0.nameLower > $1.nameLower }
		}
	}
}
