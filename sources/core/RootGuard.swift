import Foundation

// RootGuard keeps the entries of a root from being wiped by mistake.
//
//   - Offline roots (a drive or network share that isn't mounted, or a root
//     folder that can't be reached) are frozen: macOS reports them as gone
//     and a rescan finds nothing, but that says nothing about their content,
//     so their entries stay as they were until the root is back.
//   - Protected roots (a per-folder setting) also refuse, while reachable,
//     any single update that would remove the root itself or almost all of
//     its entries: a share that mounts empty, a walk cut short by a network
//     error... Smaller changes go through as usual.
//
// Value type, built per batch of changes: building one with current(...)
// checks each root on the filesystem, so it's done off the main thread.
struct RootGuard: Sendable {

	// share of a protected root's entries one update may remove; more is refused
	static let kMaxRemovedShare = 0.9
	// protected roots with fewer entries than this aren't guarded (a nearly
	// empty folder can legitimately become empty)
	static let kMinimumEntries = 100

	// roots whose entries are kept whatever the changes say
	let offline: [String]
	// roots that refuse mass removals
	let protected: [String]

	// guard with the given offline and protected roots (no filesystem access)
	init(inOffline: [String] = [], inProtected: [String] = []) {
		offline = inOffline
		protected = inProtected
	}

	// guard for inRoots as they are right now: checks which can be reached.
	// inProtected are the protected roots, compared after canonicalization.
	static func current(inRoots: [String], inProtected: [String]) -> RootGuard {
		let vRootSet = Set(inRoots)
		let vProtected = inProtected
			.map { VolumeManager.canonicalPath(inPath: $0) }
			.filter { vRootSet.contains($0) }
		return RootGuard(inOffline: inRoots.filter { !VolumeManager.isReachable(inPath: $0) },
						 inProtected: vProtected)
	}

	// true when nothing is guarded
	var isEmpty: Bool { offline.isEmpty && protected.isEmpty }

	// true when inPath is an offline root or lies below one
	func isOffline(inPath: String) -> Bool {
		return offline.contains { Self.isAtOrBelow(inPath: inPath, inRoot: $0) }
	}

	// the protected root inPath is at or below, if any
	func protectedRoot(of inPath: String) -> String? {
		return protected.first { Self.isAtOrBelow(inPath: inPath, inRoot: $0) }
	}

	// the protected root that removing inPath would take away entirely
	// (inPath is that root or a folder above it), if any
	func protectedRootRemoved(by inPath: String) -> String? {
		return protected.first { Self.isAtOrBelow(inPath: $0, inRoot: inPath) }
	}

	// true when going from inBefore to inAfter entries is the kind of wipe a
	// protected root refuses
	static func isWipe(inBefore: Int, inAfter: Int) -> Bool {
		guard inBefore >= kMinimumEntries else { return false }
		return Double(inBefore - inAfter) > Double(inBefore) * kMaxRemovedShare
	}

	// the smallest removal that can be a wipe: below this, no need to count
	// the root's entries
	static let kMinimumWipe = Int(Double(kMinimumEntries) * kMaxRemovedShare)

	// true when inPath is inRoot or below it
	static func isAtOrBelow(inPath: String, inRoot: String) -> Bool {
		if inRoot == "/" || inPath == inRoot { return true }
		return inPath.hasPrefix(inRoot + "/")
	}
}
