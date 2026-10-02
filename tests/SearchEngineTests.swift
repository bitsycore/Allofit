import Foundation
import Testing
@testable import Allofit

// Tests for the Everything-style query syntax implemented by SearchEngine.
@Suite("SearchEngine")
struct SearchEngineTests {

	// builds a record from an absolute path
	static func record(_ inPath: String, isDirectory inIsDir: Bool = false) -> FileRecord {
		let vUrl = URL(fileURLWithPath: inPath)
		return FileRecord(
			name: vUrl.lastPathComponent,
			parentPath: vUrl.deletingLastPathComponent().path,
			size: 0,
			dateCreated: .distantPast,
			dateModified: .distantPast,
			isDirectory: inIsDir
		)
	}

	// true when the query matches the record at inPath
	static func matches(_ inQuery: String, _ inPath: String, isDirectory inIsDir: Bool = false) -> Bool {
		return SearchEngine(inQuery: inQuery).match(inRecord: record(inPath, isDirectory: inIsDir))
	}

	@Test func emptyQueryIsInactive() {
		#expect(!SearchEngine(inQuery: "   ").isActive)
		#expect(SearchEngine(inQuery: "a").isActive)
	}

	@Test func substringIsCaseInsensitive() {
		#expect(Self.matches("report", "/d/Annual REPORT 2024.pdf"))
		#expect(!Self.matches("report", "/d/summary.pdf"))
	}

	@Test func readmeExamples() {
		#expect(Self.matches("Start*.pdf", "/d/StartHere.pdf"))
		#expect(!Self.matches("Start*.pdf", "/d/Restart.pdf"))
		#expect(Self.matches("IMG_????.heic", "/d/IMG_1234.heic"))
		#expect(!Self.matches("IMG_????.heic", "/d/IMG_12345.heic"))
		#expect(Self.matches("*.png | *.jpg", "/d/a.jpg"))
		#expect(Self.matches("*.png|*.jpg", "/d/a.png"))
		#expect(!Self.matches("*.png | *.jpg", "/d/a.gif"))
	}

	@Test func spaceIsAnd() {
		#expect(Self.matches("app apk", "/d/myapp-release.apk"))
		#expect(!Self.matches("app apk", "/d/myapp-release.zip"))
	}

	@Test func orBindsTighterThanAnd() {
		// a AND (b OR c)
		#expect(Self.matches("osm *.apk|*.aab", "/d/osm-1.aab"))
		#expect(!Self.matches("osm *.apk|*.aab", "/d/other.aab"))
	}

	@Test func notAndQuotes() {
		#expect(Self.matches("report !draft", "/d/report-final.pdf"))
		#expect(!Self.matches("report !draft", "/d/report-draft.pdf"))
		#expect(Self.matches("\"my file\"", "/d/this is my file.txt"))
		#expect(!Self.matches("\"my file\"", "/d/my other file.txt"))
		// wildcards still apply inside quotes
		#expect(Self.matches("\"*app*\" *.apk", "/d/osmapp.apk"))
	}

	@Test func extensionAndKindModifiers() {
		#expect(Self.matches("ext:pdf;docx", "/d/a.DOCX"))
		#expect(!Self.matches("ext:pdf;docx", "/d/a.doc"))
		#expect(Self.matches("folder:build", "/d/build", isDirectory: true))
		#expect(!Self.matches("folder:build", "/d/build.gradle"))
		#expect(Self.matches("file: build", "/d/build.gradle"))
		#expect(!Self.matches("file:", "/d/src", isDirectory: true))
	}

	@Test func pathSubstring() {
		#expect(Self.matches("sources/main", "/u/sources/main/app.swift"))
		#expect(!Self.matches("sources/main", "/u/sources/test/app.swift"))
	}

	@Test func pathGlobWithDoubleStar() {
		let vQuery = "\"some/folder/**/path\" IMG_????.heic"
		#expect(Self.matches(vQuery, "/Users/me/some/folder/a/b/path/IMG_0001.heic"))
		// ** also matches zero folders
		#expect(Self.matches(vQuery, "/Users/me/some/folder/path/IMG_0001.heic"))
		// the name term still applies
		#expect(!Self.matches(vQuery, "/Users/me/some/folder/a/path/IMG_01.heic"))
		// folder names must match whole: "paths" is not "path"
		#expect(!Self.matches(vQuery, "/Users/me/some/folder/a/paths/IMG_0001.heic"))
		// must start on a folder boundary: "awesome" is not "some"
		#expect(!Self.matches(vQuery, "/Users/me/awesome/folder/a/path/IMG_0001.heic"))
	}

	@Test func pathGlobSingleStarStaysInOneFolder() {
		#expect(Self.matches("src/*/build/", "/p/src/app/build/out.o"))
		#expect(!Self.matches("src/*/build/", "/p/src/app/sub/build/out.o"))
		#expect(Self.matches("/p/src/**/*.o", "/p/src/a/b/out.o"))
		#expect(!Self.matches("/src/**/*.o", "/p/src/a/b/out.o"))
	}

	@Test func unicodeNormalizationAndCase() {
		// name stored decomposed (NFD), query typed composed (NFC)
		let vDecomposed = "Re\u{0301}sume\u{0301}.pdf"
		#expect(Self.matches("RÉSUMÉ", "/d/" + vDecomposed))
		#expect(Self.matches("r?sum?.pdf", "/d/" + vDecomposed))
	}

	@Test func highlightsKeepLiteralRuns() {
		let vHigh = SearchEngine(inQuery: "IMG_????.heic !draft \"some/folder/**/path\" ext:pdf").highlights
		#expect(vHigh.name == ["IMG_", ".heic"])
		#expect(vHigh.path == ["some", "folder", "path"])
	}

	@Test func filtersAreAndedWithTheQuery() {
		#expect(Self.matches(SearchFilter.pictures.apply(toQuery: "img"), "/d/img_1.HEIC"))
		#expect(!Self.matches(SearchFilter.pictures.apply(toQuery: "img"), "/d/img_1.txt"))
		#expect(Self.matches(SearchFilter.folders.apply(toQuery: ""), "/d/src", isDirectory: true))
		#expect(Self.matches(SearchFilter.applications.apply(toQuery: "xcode"), "/Applications/Xcode.app", isDirectory: true))
		#expect(!Self.matches(SearchFilter.applications.apply(toQuery: "xcode"), "/d/xcode.app.zip"))
		#expect(SearchFilter.everything.apply(toQuery: "a b") == "a b")
	}
}
