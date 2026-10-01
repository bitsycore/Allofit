import Foundation

// ExclusionMatcher tests filesystem paths against a configured exclusion list.
// A path is excluded when it matches an exclusion exactly or sits beneath one
// of the configured prefix directories.
//
// Called for every entry during a walk and for every record during a prune,
// so the check is a plain UTF-8 prefix compare: the paths it receives come
// from URL.path / FSEvents and are already standardized.
struct ExclusionMatcher: Sendable {

	// normalized exclusions (no trailing slash, tilde expanded)
	private let paths: [String]
	// the same exclusions with a trailing slash, as UTF-8 bytes
	private let prefixes: [[UInt8]]

	// builds a matcher from raw user-entered exclusion strings
	init(inExclusions: [String]) {
		paths = inExclusions.map { vRaw in
			let vExpanded = (vRaw as NSString).expandingTildeInPath
			let vStandard = (vExpanded as NSString).standardizingPath
			if vStandard.hasSuffix("/") && vStandard.count > 1 {
				return String(vStandard.dropLast())
			}
			return vStandard
		}
		prefixes = paths.map { Array(($0 == "/" ? "/" : $0 + "/").utf8) }
	}

	// returns true when inPath matches an exclusion exactly or is below one
	func isExcluded(inPath: String) -> Bool {
		if paths.isEmpty { return false }
		for (vI, vEx) in paths.enumerated() {
			if inPath == vEx { return true }
			if inPath.utf8.starts(with: prefixes[vI]) { return true }
		}
		return false
	}
}
