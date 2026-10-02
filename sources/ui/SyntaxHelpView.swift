import SwiftUI

// SyntaxHelpView is the search syntax cheat sheet shown by the "?" button
// next to the search field and by Help > Search Syntax.
struct SyntaxHelpView: View {

	// one example query and what it matches
	private struct Example: Identifiable {
		let query: String
		let meaning: String
		var id: String { query }
	}

	// the rows of the cheat sheet, same order as the README
	private let kExamples: [Example] = [
		Example(query: "report", meaning: "names containing \"report\" (case and accents ignored)"),
		Example(query: "annual report", meaning: "names containing both words (AND)"),
		Example(query: "*.png | *.jpg", meaning: "either one (OR, binds tighter than AND)"),
		Example(query: "report !draft", meaning: "without \"draft\" (NOT)"),
		Example(query: "\"my file\"", meaning: "quotes keep spaces in one term"),
		Example(query: "Start*.pdf", meaning: "* any characters, the whole name must match"),
		Example(query: "IMG_????.heic", meaning: "? exactly one character"),
		Example(query: "ext:pdf;docx", meaning: "by extension"),
		Example(query: "file:  folder:", meaning: "files or folders only (also as a prefix: folder:build)"),
		Example(query: "src/main", meaning: "a term with / matches the full path"),
		Example(query: "\"photos/**/\" *.heic", meaning: "** spans folders, * stays in one; trailing / = inside"),
	]

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			Text("Search syntax")
				.font(.headline)
			Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
				ForEach(kExamples) { vExample in
					GridRow {
						Text(vExample.query)
							.font(.system(.body, design: .monospaced))
							.textSelection(.enabled)
						Text(vExample.meaning)
							.foregroundColor(.secondary)
					}
				}
			}
			Divider()
			Text("↓ moves from the search field to the results, ↑ on the first row comes back. Hold ⌥ to freeze the list while files change.")
				.font(.caption)
				.foregroundColor(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
		.padding(16)
		.frame(width: 560)
	}
}
