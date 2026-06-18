import Foundation

// Main is the binary's entry point. It routes between two modes based on
// command-line arguments: --service starts the headless indexer/watcher
// daemon, anything else launches the SwiftUI GUI application.
@main
struct Main {
	static func main() {
		if CommandLine.arguments.contains("--service") {
			AllofitService.run()
		} else {
			AllofitApp.main()
		}
	}
}
