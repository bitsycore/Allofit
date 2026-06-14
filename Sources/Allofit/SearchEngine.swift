import Foundation

// SearchEngine matches a user query against a FileRecord's name.
// Without wildcards it does a fast case-insensitive substring match.
// With * and ? wildcards it compiles an anchored regular expression
// so "Start*.pdf" behaves the same way as in Everything: anchored at
// both ends and matched against the file name (not the full path).
struct SearchEngine {

	// compiled regular expression for wildcard queries (anchored)
	private let regex: NSRegularExpression?
	// pre-lowercased query for plain substring matching
	private let simpleQuery: String?

	// builds an engine for the provided query string
	init(inQuery: String) {
		let vTrimmed = inQuery.trimmingCharacters(in: .whitespacesAndNewlines)
		if vTrimmed.isEmpty {
			self.regex = nil
			self.simpleQuery = nil
			return
		}
		let vHasWildcards = vTrimmed.contains("*") || vTrimmed.contains("?")
		if !vHasWildcards {
			self.simpleQuery = vTrimmed.lowercased()
			self.regex = nil
		} else {
			self.simpleQuery = nil
			let vPattern = SearchEngine.wildcardToRegex(inPattern: vTrimmed)
			self.regex = try? NSRegularExpression(pattern: vPattern, options: [.caseInsensitive])
		}
	}

	// true when this engine has any pattern that will filter results
	var isActive: Bool { simpleQuery != nil || regex != nil }

	// returns true if the record's name matches the current query
	func match(inRecord: FileRecord) -> Bool {
		if let vSimple = simpleQuery {
			return inRecord.nameLower.contains(vSimple)
		}
		if let vRegex = regex {
			let vName = inRecord.name
			let vRange = NSRange(vName.startIndex..., in: vName)
			return vRegex.firstMatch(in: vName, options: [], range: vRange) != nil
		}
		return true
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
