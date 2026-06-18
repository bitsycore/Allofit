// swift-tools-version: 6.0
import PackageDescription

// Allofit is a macOS file search utility inspired by voidtools "Everything".
// It builds an in-memory index of filesystem entries and offers instant
// wildcard search, real-time updates via FSEvents, drag-and-drop and Quick Look.
//
// Deployment target is macOS 15 (Sequoia) so users on 15 and 26 can both run
// it. Apple skipped 16-25 with the year-aligned renumbering, so .v15 is "one
// macOS version below 26".
//
// Language mode stays at Swift 5: we compile with the Swift 6 toolchain to
// get the latest SDK and language features, but skip the strict-concurrency
// runtime checks which were turning into hard traps on launch.
let package = Package(
	name: "Allofit",
	platforms: [
		.macOS(.v15)
	],
	products: [
		.executable(name: "Allofit", targets: ["Allofit"])
	],
	targets: [
		.executableTarget(
			name: "Allofit",
			path: "sources",
			swiftSettings: [
				.swiftLanguageMode(.v5)
			]
		)
	]
)
