import Foundation

// Highlighter emphasizes the parts of a result's name or folder that the
// query matched, like Everything's bold highlights. Matching is case- and
// accent-insensitive on the displayed text, so it works on the original
// spelling (no index mapping from the folded search form).
enum Highlighter {

	// inText with every occurrence of each term marked strongly emphasized
	static func attributed(_ inText: String, inTerms: [String]) -> AttributedString {
		var vResult = AttributedString(inText)
		guard !inTerms.isEmpty else { return vResult }
		let vOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
		for vTerm in inTerms {
			var vSearch = inText.startIndex..<inText.endIndex
			while let vRange = inText.range(of: vTerm, options: vOptions, range: vSearch), !vRange.isEmpty {
				if let vAttrRange = Range(vRange, in: vResult) {
					vResult[vAttrRange].inlinePresentationIntent = .stronglyEmphasized
				}
				vSearch = vRange.upperBound..<inText.endIndex
			}
		}
		return vResult
	}
}
