import Foundation

// CLI dispatches sub-commands invoked from Main.swift before the GUI app
// boots. Lets the user install / uninstall / start / stop the background
// service and flip the GUI's service-mode preference without opening the
// Settings window.
//
// Usage shape:
//   Allofit                      launches the GUI (default)
//   Allofit --service            runs as the headless indexer (existing)
//   Allofit install <user|root>  installs the LaunchAgent or LaunchDaemon
//   Allofit uninstall [user|root]
//   Allofit start [user|root]
//   Allofit stop [user|root]
//   Allofit mode <none|user|root>  sets GUI Preferences.serviceMode
//   Allofit status                 prints install + run state
//   Allofit --help
enum CLI {

	// returns true when a CLI command was recognised and handled, in which
	// case Main.swift returns without booting the GUI. Returns false to
	// fall through to the SwiftUI app.
	static func handle(arguments inArgs: [String]) -> Bool {
		guard let vCmd = inArgs.first else { return false }
		let vRest = Array(inArgs.dropFirst())
		switch vCmd {
			case "-h", "--help":
				printHelp()
				return true
			case "install":
				runInstall(inArgs: vRest)
				return true
			case "uninstall":
				runUninstall(inArgs: vRest)
				return true
			case "start":
				runStart(inArgs: vRest)
				return true
			case "stop":
				runStop(inArgs: vRest)
				return true
			case "mode":
				runSetMode(inArgs: vRest)
				return true
			case "status":
				runStatus()
				return true
			default:
				return false
		}
	}

	// ===========================
	// MARK: Command implementations
	// ===========================

	// install <user|root> - copy the running binary to the daemon path and
	// register the launchd plist. Root scope prompts once for an admin
	// password via NSAppleScript inside ServiceInstaller.
	private static func runInstall(inArgs: [String]) {
		guard let vScope = parseScope(inArgs.first) else {
			fail("Usage: allofit install <user|root>")
		}
		print("==> Installing \(label(for: vScope))…")
		do {
			try ServiceInstaller.install(inScope: vScope)
			print("Installed.")
		} catch {
			fail("Install failed: \(error.localizedDescription)")
		}
	}

	// uninstall [user|root] - explicit scope, or every installed scope when
	// none is given (the typical "tear it all down" intent).
	private static func runUninstall(inArgs: [String]) {
		let vScopes = scopesToActOn(inArgs: inArgs, defaultMode: .everyInstalled)
		guard !vScopes.isEmpty else {
			print("Nothing to uninstall (no service installed).")
			return
		}
		for vScope in vScopes {
			print("==> Uninstalling \(label(for: vScope))…")
			do {
				try ServiceInstaller.uninstall(inScope: vScope)
				print("Uninstalled \(label(for: vScope)).")
			} catch {
				print("Uninstall failed for \(label(for: vScope)): \(error.localizedDescription)")
			}
		}
	}

	private static func runStart(inArgs: [String]) {
		let vScopes = scopesToActOn(inArgs: inArgs, defaultMode: .firstInstalled)
		guard !vScopes.isEmpty else {
			fail("No service installed. Use: allofit install <user|root>")
		}
		for vScope in vScopes {
			print("==> Starting \(label(for: vScope))…")
			do {
				try ServiceInstaller.start(inScope: vScope)
				print("Started.")
			} catch {
				fail("Start failed: \(error.localizedDescription)")
			}
		}
	}

	private static func runStop(inArgs: [String]) {
		let vScopes = scopesToActOn(inArgs: inArgs, defaultMode: .firstInstalled)
		guard !vScopes.isEmpty else {
			fail("No service installed.")
		}
		for vScope in vScopes {
			print("==> Stopping \(label(for: vScope))…")
			do {
				try ServiceInstaller.stop(inScope: vScope)
				print("Stopped.")
			} catch {
				fail("Stop failed: \(error.localizedDescription)")
			}
		}
	}

	// mode <none|user|root> - writes Preferences.serviceMode so the next GUI
	// launch boots in the chosen role. Doesn't install or start anything
	// itself; pair with `install` + `start` for a one-shot setup.
	private static func runSetMode(inArgs: [String]) {
		guard let vArg = inArgs.first else {
			fail("Usage: allofit mode <none|user|root>")
		}
		let vMode: Preferences.ServiceMode
		switch vArg {
			case "none", "off":
				vMode = .none
			case "user", "useragent":
				vMode = .userAgent
			case "root", "rootdaemon", "system", "admin":
				vMode = .rootDaemon
			default:
				fail("Unknown mode: \(vArg). Use one of: none, user, root")
		}
		// Write into both the bundle id and the SwiftPM/process domain so
		// the setting takes regardless of how the GUI is launched (drag
		// from /Applications uses the bundle id; `swift run Allofit` uses
		// the executable name).
		writeMode(vMode, toDomain: kBundleId)
		writeMode(vMode, toDomain: kProcessName)
		print("Service mode set to \(vMode.rawValue).")
	}

	private static func writeMode(_ inMode: Preferences.ServiceMode, toDomain inDomain: String) {
		guard let vDefaults = UserDefaults(suiteName: inDomain) else { return }
		vDefaults.set(inMode.rawValue, forKey: kServiceModeKey)
		vDefaults.synchronize()
	}

	private static func runStatus() {
		print("Bundle version: \(ServiceInstaller.bundleVersion())")
		for vScope in [ServiceInstaller.Scope.userAgent, .rootDaemon] {
			let vInstalled = ServiceInstaller.isInstalled(inScope: vScope)
			let vRunning = vInstalled && ServiceInstaller.isRunning(inScope: vScope)
			let vVersion = ServiceInstaller.installedVersion(inScope: vScope) ?? "—"
			let vState: String
			if vRunning {
				vState = "running"
			} else if vInstalled {
				vState = "installed (stopped)"
			} else {
				vState = "not installed"
			}
			print("\(label(for: vScope).padding(toLength: 14, withPad: " ", startingAt: 0)) \(vState)   v\(vVersion)")
		}
	}

	// ===========================
	// MARK: Helpers
	// ===========================

	private static let kBundleId = "com.bitsycore.allofit"
	private static let kProcessName = "Allofit"
	private static let kServiceModeKey = "Allofit.serviceMode"

	private enum ScopeResolution {
		case firstInstalled
		case everyInstalled
	}

	// Returns the scopes a command should operate on:
	//   - explicit `user`/`root` arg: just that one
	//   - no arg, firstInstalled mode: the single installed scope, if any
	//   - no arg, everyInstalled mode: all installed scopes
	private static func scopesToActOn(inArgs: [String], defaultMode: ScopeResolution) -> [ServiceInstaller.Scope] {
		if let vScope = parseScope(inArgs.first) {
			return [vScope]
		}
		let vAll: [ServiceInstaller.Scope] = [.userAgent, .rootDaemon]
		let vInstalled = vAll.filter { ServiceInstaller.isInstalled(inScope: $0) }
		switch defaultMode {
			case .firstInstalled:
				return vInstalled.first.map { [$0] } ?? []
			case .everyInstalled:
				return vInstalled
		}
	}

	private static func parseScope(_ inArg: String?) -> ServiceInstaller.Scope? {
		guard let vArg = inArg else { return nil }
		switch vArg {
			case "user", "useragent":
				return .userAgent
			case "root", "rootdaemon", "daemon", "system", "admin":
				return .rootDaemon
			default:
				return nil
		}
	}

	private static func label(for inScope: ServiceInstaller.Scope) -> String {
		switch inScope {
			case .userAgent: return "user agent"
			case .rootDaemon: return "root daemon"
		}
	}

	// prints a message to stderr and exits with status 1
	private static func fail(_ inMessage: String) -> Never {
		FileHandle.standardError.write(Data((inMessage + "\n").utf8))
		exit(1)
	}

	private static func printHelp() {
		print("""
		Usage: allofit [command [args]]

		Service control:
		  install <user|root>      Copy binary, register launchd plist, start the service.
		                           'root' prompts once for an admin password.
		  uninstall [user|root]    Stop and remove. Without an arg, uninstalls every
		                           installed scope.
		  start [user|root]        Start an installed service. Picks the only installed
		                           one when no arg is given.
		  stop [user|root]         Stop a running service.
		  mode <none|user|root>    Set the GUI's service-mode preference. Does NOT
		                           install anything itself.
		  status                   Show install + run state for both scopes.

		Other:
		  --service                Run as the headless indexer (used by launchd).
		  --help, -h               This message.

		With no arguments, launches the GUI.
		""")
	}
}
