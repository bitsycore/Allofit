// swift-tools-version: 5.9
import PackageDescription

// Allofit is a macOS file search utility inspired by voidtools "Everything".
// It builds an in-memory index of filesystem entries and offers instant
// wildcard search, real-time updates via FSEvents, drag-and-drop and Quick Look.
let package = Package(
	name: "Allofit",
	platforms: [
		.macOS(.v14)
	],
	products: [
		.executable(name: "Allofit", targets: ["Allofit"])
	],
	targets: [
		.executableTarget(
			name: "Allofit",
			path: "Sources/Allofit"
		)
	]
)
