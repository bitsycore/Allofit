import Foundation

// SearchEngine matches a user query against a FileRecord's name.
//
// Without wildcards a query is a fast case-insensitive substring match.
// With * or ? wildcards it compiles to an anchored regex so "Start*.pdf"
// behaves like Everything: anchored at both ends and matched against the
// file name (not the full path).
//
// A query may contain "|" as a top-level OR separator, so:
//     *.png | *.jpg | *.gif
// matches anything ending in .png, .jpg or .gif. Whitespace around the
// pipes is ignored; empty alternatives are dropped.
struct SearchEngine {

	// one alternative of the OR-separated query
	private enum Submatcher {
		// pre-lowercased substring for case-insensitive contains()
		case substring(String)
		// compiled anchored regex translated from a *? wildcard pattern
		case regex(NSRegularExpression)
	}

	// all OR-alternatives; the query matches if any submatcher matches
	private let matchers: [Submatcher]

	// builds an engine for the provided query string
	init(inQuery: String) {
		let vTrimmed = inQuery.trimmingCharacters(in: .whitespacesAndNewlines)
		if vTrimmed.isEmpty {
			self.matchers = []
			return
		}
		// split on top-level pipes (no escape mechanism - pipe is reserved)
		let vParts = vTrimmed
			.split(separator: "|", omittingEmptySubsequences: true)
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
		var vResult: [Submatcher] = []
		for vPart in vParts {
			let vHasWildcards = vPart.contains("*") || vPart.contains("?")
			if !vHasWildcards {
				vResult.append(.substring(vPart.lowercased()))
			} else {
				let vPattern = SearchEngine.wildcardToRegex(inPattern: vPart)
				if let vRegex = try? NSRegularExpression(pattern: vPattern, options: [.caseInsensitive]) {
					vResult.append(.regex(vRegex))
				}
			}
		}
		self.matchers = vResult
	}

	// true when this engine has any pattern that will filter results
	var isActive: Bool { !matchers.isEmpty }

	// returns true if the record's name matches any of the OR-alternatives
	func match(inRecord: FileRecord) -> Bool {
		for vMatcher in matchers {
			switch vMatcher {
				case .substring(let vNeedle):
					if inRecord.nameLower.contains(vNeedle) { return true }
				case .regex(let vRegex):
					let vName = inRecord.name
					let vRange = NSRange(vName.startIndex..., in: vName)
					if vRegex.firstMatch(in: vName, options: [], range: vRange) != nil {
						return true
					}
			}
		}
		return false
	}

	// converts an Everything-style wildcard pattern into an anchored regex
	private static func wildcardToRegex(inPattern: String) -> String {
		var vResult = "^"
		for vChar in inPattern {
			switch vChar {
				case "*":
					vResult.append(".*")
				case "?":
					vResult.append(".")
				case ".", "+", "(", ")", "[", "]", "{", "}", "^", "$", "|", "\\":
					vResult.append("\\")
					vResult.append(vChar)
				default:
					vResult.append(vChar)
			}
		}
		vResult.append("$")
		return vResult
	}
}
