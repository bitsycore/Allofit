import Foundation

// ExclusionMatcher tests filesystem paths against a configured exclusion list.
// A path is excluded when it matches an exclusion exactly or sits beneath one
// of the configured prefix directories.
struct ExclusionMatcher {

	// normalized exclusion prefixes (no trailing slash, tilde expanded)
	private let prefixes: [String]

	// builds a matcher from raw user-entered exclusion strings
	init(inExclusions: [String]) {
		prefixes = inExclusions.map { vRaw in
			let vExpanded = (vRaw as NSString).expandingTildeInPath
			let vStandard = (vExpanded as NSString).standardizingPath
			if vStandard.hasSuffix("/") && vStandard.count > 1 {
				return String(vStandard.dropLast())
			}
			return vStandard
		}
	}

	// returns true when inPath matches an exclusion exactly or is below one
	func isExcluded(inPath: String) -> Bool {
		if prefixes.isEmpty { return false }
		let vPath = (inPath as NSString).standardizingPath
		for vEx in prefixes {
			if vPath == vEx { return true }
			if vPath.hasPrefix(vEx + "/") { return true }
		}
		return false
	}
}
