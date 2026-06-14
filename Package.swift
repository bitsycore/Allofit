// swift-tools-version: 6.2
import PackageDescription

// Allofit is a macOS file search utility inspired by voidtools "Everything".
// It builds an in-memory index of filesystem entries and offers instant
// wildcard search, real-time updates via FSEvents, drag-and-drop and Quick Look.
//
// Targets macOS 26 so we can lean on the latest SwiftUI / Foundation surface
// without compatibility shims. Swift 6 strict concurrency is on by default.
let package = Package(
	name: "Allofit",
	platforms: [
		.macOS(.v26)
	],
	products: [
		.executable(name: "Allofit", targets: ["Allofit"])
	],
	targets: [
		.executableTarget(
			name: "Allofit",
			path: "Sources/Allofit",
			swiftSettings: [
				.swiftLanguageMode(.v6)
			]
		)
	]
)
