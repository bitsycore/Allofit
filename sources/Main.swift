import Foundation

// Main is the binary's entry point. Routes by command-line arguments:
//   --service                  run the headless indexer daemon
//   install / uninstall / ...  CLI service-control commands (see CLI.swift)
//   anything else / no args    launch the SwiftUI GUI
@main
struct Main {
	static func main() {
		let vArgs = Array(CommandLine.arguments.dropFirst())
		// No args: GUI mode. The Dock and Finder launch us with no args.
		if vArgs.isEmpty {
			AllofitApp.main()
			return
		}
		// Headless indexer daemon, invoked by launchd's plist.
		if vArgs.contains("--service") {
			AllofitService.run()
			return
		}
		// Anything else is a CLI command. Unknown commands print a hint
		// to stderr and exit 1 rather than silently launching the GUI.
		if !CLI.handle(arguments: vArgs) {
			FileHandle.standardError.write(Data(
				"Unknown command: \(vArgs.joined(separator: " "))\nUse --help for usage.\n".utf8
			))
			exit(1)
		}
	}
}
