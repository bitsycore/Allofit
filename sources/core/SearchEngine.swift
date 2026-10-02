import Foundation

// SearchEngine matches a user query against FileRecords using voidtools
// Everything's query syntax:
//
//     foo bar          AND: both "foo" and "bar" appear in the name
//     *.png | *.jpg    OR: binds tighter than AND (Everything precedence)
//     !tmp             NOT: names that don't contain "tmp"
//     "my file"        quotes keep spaces inside a single term
//     Start*.pdf       wildcards: * any run, ? one character; a wildcard
//                      term must match the whole name (anchored)
//     src/main         a term containing "/" is matched against the full path
//     some/**/path     with wildcards, a path term matches whole folder
//                      names anywhere in the path: * stays inside one
//                      name, ** spans any number of folders (zero too).
//                      "photos/**/IMG_????.heic" or "src/**/build/" (a
//                      trailing / means "anything inside that folder")
//     ext:pdf;docx     extension list
//     file: folder:    restrict to files / folders (alone or as a prefix,
//                      e.g. folder:build)
//
// Matching is case- and normalization-insensitive and runs on raw UTF-8
// bytes (memmem / a byte-level glob) against the record's pre-lowercased
// name, so a full pass over a million records takes milliseconds.
struct SearchEngine: Sendable {

	// how a single term's text is matched
	private enum Pattern: Sendable {
		// case-folded UTF-8 needle searched anywhere in the target
		case substring([UInt8])
		// case-folded UTF-8 glob that must match the whole target
		case glob([UInt8])
		// case-folded path glob, aligned on folder boundaries
		case pathGlob([UInt8])
		// allowed extensions (case-folded, without the dot)
		case extensions([[UInt8]])
	}

	// one term of the query, e.g. `!folder:*.app`
	private struct Term: Sendable {
		// text pattern, nil for a bare file: / folder: modifier
		let pattern: Pattern?
		// true to match the full path instead of the name
		let matchesPath: Bool
		// required entry kind: true = folders only, false = files only
		let requiresDirectory: Bool?
		// true when the term was prefixed with "!"
		let negated: Bool
		// the term's text as typed (no "!" / modifier prefix), used to
		// emphasize matches in the results; empty for ext: and bare modifiers
		var text: String = ""
	}

	// literal pieces of the query to emphasize in the results, matched
	// case- and accent-insensitively against the displayed name / folder
	struct Highlights: Equatable, Sendable {
		// pieces to emphasize in names
		var name: [String] = []
		// pieces to emphasize in folder paths
		var path: [String] = []
	}

	// AND of OR-groups: every group must have at least one matching term
	private let groups: [[Term]]

	// builds an engine for the provided query string
	init(inQuery: String) {
		var vGroups: [[Term]] = []
		var vJoinNext = false
		for vToken in SearchEngine.tokenize(inQuery: inQuery) {
			if vToken == "|" {
				vJoinNext = !vGroups.isEmpty
				continue
			}
			guard let vTerm = SearchEngine.parseTerm(inToken: vToken) else { continue }
			if vJoinNext {
				vGroups[vGroups.count - 1].append(vTerm)
			} else {
				vGroups.append([vTerm])
			}
			vJoinNext = false
		}
		// cheap name-only groups first: path terms scan the folder path
		// too, so they only run on records that survived the name terms
		self.groups = vGroups.sorted { vA, vB in
			!vA.contains(where: { $0.matchesPath }) && vB.contains(where: { $0.matchesPath })
		}
	}

	// true when this engine has any pattern that will filter results
	var isActive: Bool { !groups.isEmpty }

	// what to emphasize in the results: the literal runs of every positive
	// name / path term (wildcards and folder separators split the runs)
	var highlights: Highlights {
		var vResult = Highlights()
		for vTerm in groups.joined() where !vTerm.negated && !vTerm.text.isEmpty {
			let vSeparators: Set<Character> = vTerm.matchesPath ? ["*", "?", "/"] : ["*", "?"]
			let vPieces = vTerm.text
				.split(whereSeparator: { vSeparators.contains($0) })
				.map(String.init)
				.filter { !$0.isEmpty }
			if vTerm.matchesPath {
				vResult.path.append(contentsOf: vPieces)
			} else {
				vResult.name.append(contentsOf: vPieces)
			}
		}
		return vResult
	}

	// returns true if the record satisfies every AND-group of the query
	func match(inRecord: FileRecord) -> Bool {
		for vGroup in groups {
			var vAny = false
			for vTerm in vGroup where SearchEngine.matches(inTerm: vTerm, inRecord: inRecord) {
				vAny = true
				break
			}
			if !vAny { return false }
		}
		return true
	}

	// ===========================
	// MARK: Parsing
	// ===========================

	// splits the query on whitespace (outside quotes) and isolates "|"
	// separators. Quotes are removed; their content stays one token.
	private static func tokenize(inQuery: String) -> [String] {
		var vTokens: [String] = []
		var vCurrent = ""
		var vInQuotes = false
		// flushes the token being built, if any
		func flush() {
			if !vCurrent.isEmpty { vTokens.append(vCurrent) }
			vCurrent = ""
		}
		for vChar in inQuery {
			if vChar == "\"" {
				vInQuotes.toggle()
			} else if vInQuotes {
				vCurrent.append(vChar)
			} else if vChar.isWhitespace {
				flush()
			} else if vChar == "|" {
				flush()
				vTokens.append("|")
			} else {
				vCurrent.append(vChar)
			}
		}
		flush()
		return vTokens
	}

	// parses one token into a term; nil when the token carries nothing
	private static func parseTerm(inToken: String) -> Term? {
		var vText = Substring(inToken)
		var vNegated = false
		while vText.hasPrefix("!") {
			vNegated.toggle()
			vText = vText.dropFirst()
		}

		var vRequiresDir: Bool?
		let vLower = vText.lowercased()
		if vLower.hasPrefix("folder:") {
			vRequiresDir = true
			vText = vText.dropFirst("folder:".count)
		} else if vLower.hasPrefix("file:") {
			vRequiresDir = false
			vText = vText.dropFirst("file:".count)
		}

		if vText.lowercased().hasPrefix("ext:") {
			let vExts = vText.dropFirst("ext:".count)
				.split(whereSeparator: { $0 == ";" || $0 == "," })
				.map { vExt -> [UInt8] in
					let vClean = vExt.hasPrefix(".") ? vExt.dropFirst() : vExt
					return Array(FileRecord.searchForm(of: String(vClean)).utf8)
				}
				.filter { !$0.isEmpty }
			if vExts.isEmpty && vRequiresDir == nil { return nil }
			return Term(
				pattern: vExts.isEmpty ? nil : .extensions(vExts),
				matchesPath: false,
				requiresDirectory: vRequiresDir,
				negated: vNegated
			)
		}

		if vText.isEmpty {
			// a bare modifier ("file:", "!folder:") still filters
			guard vRequiresDir != nil else { return nil }
			return Term(pattern: nil, matchesPath: false, requiresDirectory: vRequiresDir, negated: vNegated)
		}

		let vNeedle = Array(FileRecord.searchForm(of: String(vText)).utf8)
		let vHasWildcards = vText.contains("*") || vText.contains("?")
		let vIsPath = vText.contains("/")
		let vPattern: Pattern
		if vHasWildcards {
			vPattern = vIsPath ? .pathGlob(vNeedle) : .glob(vNeedle)
		} else {
			vPattern = .substring(vNeedle)
		}
		return Term(
			pattern: vPattern,
			matchesPath: vIsPath,
			requiresDirectory: vRequiresDir,
			negated: vNegated,
			text: String(vText)
		)
	}

	// ===========================
	// MARK: Matching
	// ===========================

	// evaluates one term (including its negation) against a record
	private static func matches(inTerm: Term, inRecord: FileRecord) -> Bool {
		var vResult = true
		if let vDir = inTerm.requiresDirectory, vDir != inRecord.isDirectory {
			vResult = false
		} else if let vPattern = inTerm.pattern {
			if inTerm.matchesPath {
				vResult = matchesPath(inPattern: vPattern, inFoldedParent: inRecord.parentLower, inFoldedName: inRecord.nameLower)
			} else {
				vResult = matches(inPattern: vPattern, inTarget: inRecord.nameLower)
			}
		}
		return inTerm.negated ? !vResult : vResult
	}

	// runs a pattern against an already case-folded name
	private static func matches(inPattern: Pattern, inTarget: String) -> Bool {
		var vTarget = inTarget
		return vTarget.withUTF8 { vBytes in
			switch inPattern {
				case .substring(let vNeedle):
					return containsBytes(inHaystack: vBytes, inNeedle: vNeedle)
				case .glob(let vGlob):
					return vGlob.withUnsafeBufferPointer { globMatch(inPattern: $0, inText: vBytes) }
				case .pathGlob(let vGlob):
					return vGlob.withUnsafeBufferPointer {
						pathGlobMatch(inPattern: $0, inText: JoinedBytes(inHead: UnsafeBufferPointer(start: nil, count: 0), inTail: vBytes))
					}
				case .extensions(let vExts):
					return hasExtension(inName: vBytes, inExtensions: vExts)
			}
		}
	}

	// runs a path pattern against folder + "/" + name without building the
	// joined string (both parts already case-folded)
	private static func matchesPath(inPattern: Pattern, inFoldedParent: String, inFoldedName: String) -> Bool {
		var vName = inFoldedName
		var vParent = inFoldedParent
		return vName.withUTF8 { vNameBytes in
			vParent.withUTF8 { vParentBytes in
				let vText = JoinedBytes(inHead: vParentBytes, inTail: vNameBytes)
				switch inPattern {
					case .substring(let vNeedle):
						return joinedContains(inText: vText, inNeedle: vNeedle)
					case .pathGlob(let vGlob), .glob(let vGlob):
						return vGlob.withUnsafeBufferPointer { pathGlobMatch(inPattern: $0, inText: vText) }
					case .extensions(let vExts):
						return hasExtension(inName: vNameBytes, inExtensions: vExts)
				}
			}
		}
	}

	// substring search over raw bytes
	private static func containsBytes(inHaystack: UnsafeBufferPointer<UInt8>, inNeedle: [UInt8]) -> Bool {
		if inNeedle.isEmpty { return true }
		if inNeedle.count > inHaystack.count { return false }
		return inNeedle.withUnsafeBufferPointer { vNeedle in
			memmem(inHaystack.baseAddress, inHaystack.count, vNeedle.baseAddress, vNeedle.count) != nil
		}
	}

	// substring search over folder + "/" + name: inside the folder part,
	// inside the name, or straddling the "/" between them
	private static func joinedContains(inText: JoinedBytes, inNeedle: [UInt8]) -> Bool {
		if containsBytes(inHaystack: inText.head, inNeedle: inNeedle) { return true }
		if containsBytes(inHaystack: inText.tail, inNeedle: inNeedle) { return true }
		if inNeedle.count < 2 || inNeedle.count > inText.count { return inNeedle.count == 1 && inText.hasSeparator && inNeedle[0] == UInt8(ascii: "/") }
		// window around the junction: up to needle-1 bytes on each side
		let vStart = max(0, inText.head.count - (inNeedle.count - 1))
		let vEnd = min(inText.count, inText.head.count + (inText.hasSeparator ? 1 : 0) + (inNeedle.count - 1))
		return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: vEnd - vStart) { vWindow in
			for vI in vStart..<vEnd {
				vWindow[vI - vStart] = inText[vI]
			}
			return containsBytes(inHaystack: UnsafeBufferPointer(vWindow), inNeedle: inNeedle)
		}
	}

	// true when the name's extension (after the last dot) is in the list
	private static func hasExtension(inName: UnsafeBufferPointer<UInt8>, inExtensions: [[UInt8]]) -> Bool {
		guard let vDot = inName.lastIndex(of: UInt8(ascii: ".")), vDot > 0 else { return false }
		let vExt = UnsafeBufferPointer(rebasing: inName[(vDot + 1)...])
		for vCandidate in inExtensions where vCandidate.count == vExt.count {
			if vCandidate.elementsEqual(vExt) { return true }
		}
		return false
	}

	// index of the next UTF-8 scalar start after inIndex
	private static func nextScalar(in inText: UnsafeBufferPointer<UInt8>, after inIndex: Int) -> Int {
		var vI = inIndex + 1
		while vI < inText.count && (inText[vI] & 0xC0) == 0x80 { vI += 1 }
		return vI
	}

	// same as nextScalar, over a joined folder + name
	private static func nextScalar(in inText: JoinedBytes, after inIndex: Int) -> Int {
		var vI = inIndex + 1
		while vI < inText.count && (inText[vI] & 0xC0) == 0x80 { vI += 1 }
		return vI
	}

	// anchored wildcard match: * = any run, ? = exactly one character.
	// Iterative with single-star backtracking (linear in practice).
	private static func globMatch(inPattern: UnsafeBufferPointer<UInt8>, inText: UnsafeBufferPointer<UInt8>) -> Bool {
		let kStar = UInt8(ascii: "*")
		let kQuestion = UInt8(ascii: "?")
		var vP = 0
		var vT = 0
		var vStarP = -1
		var vStarT = 0
		while vT < inText.count {
			if vP < inPattern.count && inPattern[vP] == kQuestion {
				vP += 1
				vT = nextScalar(in: inText, after: vT)
			} else if vP < inPattern.count && inPattern[vP] == kStar {
				vStarP = vP
				vStarT = vT
				vP += 1
			} else if vP < inPattern.count && inPattern[vP] == inText[vT] {
				vP += 1
				vT += 1
			} else if vStarP >= 0 {
				vStarT = nextScalar(in: inText, after: vStarT)
				vT = vStarT
				vP = vStarP + 1
			} else {
				return false
			}
		}
		while vP < inPattern.count && inPattern[vP] == kStar { vP += 1 }
		return vP == inPattern.count
	}

	// path glob: the pattern may start at any folder boundary of the path
	// (or only at the root when it starts with "/") and must end on one
	// (end of path, or a "/" in the path). A pattern ending with "/" matches
	// everything inside that folder.
	private static func pathGlobMatch(inPattern: UnsafeBufferPointer<UInt8>, inText: JoinedBytes) -> Bool {
		let kSlash = UInt8(ascii: "/")
		if inPattern.first == kSlash {
			return pathGlobFrom(inPattern: inPattern, inP: 0, inText: inText, inT: 0)
		}
		for vStart in 0..<inText.count where vStart == 0 || inText[vStart - 1] == kSlash {
			if pathGlobFrom(inPattern: inPattern, inP: 0, inText: inText, inT: vStart) { return true }
		}
		return false
	}

	// recursive matcher behind pathGlobMatch, starting at pattern index
	// inP and text index inT
	private static func pathGlobFrom(inPattern: UnsafeBufferPointer<UInt8>,
									 inP: Int,
									 inText: JoinedBytes,
									 inT: Int) -> Bool {
		let kSlash = UInt8(ascii: "/")
		let kStar = UInt8(ascii: "*")
		let kQuestion = UInt8(ascii: "?")
		var vP = inP
		var vT = inT
		while vP < inPattern.count {
			let vChar = inPattern[vP]
			if vChar == kStar {
				if vP + 1 < inPattern.count && inPattern[vP + 1] == kStar {
					// "**": any run of characters, folder separators included
					let vNext = vP + 2
					// "**/" also matches zero folders ("a/**/b" matches "a/b")
					if vNext < inPattern.count && inPattern[vNext] == kSlash,
					   pathGlobFrom(inPattern: inPattern, inP: vNext + 1, inText: inText, inT: vT) {
						return true
					}
					var vTry = vT
					while true {
						if pathGlobFrom(inPattern: inPattern, inP: vNext, inText: inText, inT: vTry) { return true }
						if vTry >= inText.count { return false }
						vTry += 1
					}
				}
				// "*": any run of characters inside one folder name
				var vTry = vT
				while true {
					if pathGlobFrom(inPattern: inPattern, inP: vP + 1, inText: inText, inT: vTry) { return true }
					if vTry >= inText.count || inText[vTry] == kSlash { return false }
					vTry = nextScalar(in: inText, after: vTry)
				}
			} else if vChar == kQuestion {
				if vT >= inText.count || inText[vT] == kSlash { return false }
				vT = nextScalar(in: inText, after: vT)
				vP += 1
			} else {
				if vT >= inText.count || inText[vT] != vChar { return false }
				vT += 1
				vP += 1
			}
		}
		// must stop on a folder boundary, unless the pattern ended with "/"
		return vT == inText.count || inText[vT] == kSlash || (vP > 0 && inPattern[vP - 1] == kSlash)
	}
}

// JoinedBytes presents folder bytes + "/" + name bytes as one read-only
// byte sequence, so path matching never allocates the joined path.
private struct JoinedBytes {

	// case-folded folder path ("" for none, "/" for the root)
	let head: UnsafeBufferPointer<UInt8>
	// case-folded name
	let tail: UnsafeBufferPointer<UInt8>
	// true when a "/" separates head and tail (not after "" or "/")
	let hasSeparator: Bool
	// total length including the separator
	let count: Int

	// joins a folder and a name
	init(inHead: UnsafeBufferPointer<UInt8>, inTail: UnsafeBufferPointer<UInt8>) {
		head = inHead
		tail = inTail
		hasSeparator = !inHead.isEmpty && !(inHead.count == 1 && inHead[0] == UInt8(ascii: "/"))
		count = inHead.count + (hasSeparator ? 1 : 0) + inTail.count
	}

	// byte at inIndex of the joined sequence
	subscript(inIndex: Int) -> UInt8 {
		if inIndex < head.count { return head[inIndex] }
		var vI = inIndex - head.count
		if hasSeparator {
			if vI == 0 { return UInt8(ascii: "/") }
			vI -= 1
		}
		return tail[vI]
	}
}
