import Foundation

// ServiceInstaller writes a launchd plist for the background indexer.
// Two scopes are supported:
//   * userAgent  -> ~/Library/LaunchAgents (no admin needed)
//   * rootDaemon -> /Library/LaunchDaemons (requires administrator password)
// In root mode the daemon can scan every readable file on the disk; the user
// still needs to grant Full Disk Access in System Settings the first time.
enum ServiceInstaller {

	// launchd job label shared by both scopes (mirrors the .app bundle id
	// with a .service suffix so the two are easy to correlate in `launchctl`)
	static let kLabel = "com.bitsycore.allofit.service"

	// installation scope
	enum Scope {
		case userAgent
		case rootDaemon
	}

	// errors surfaced to the UI
	enum InstallError: Error, LocalizedError {
		case binaryNotFound
		case authorizationFailed(String)
		case launchctlFailed(String)
		var errorDescription: String? {
			switch self {
				case .binaryNotFound: return "Could not resolve the Allofit binary path."
				case .authorizationFailed(let vMsg): return "Authorization failed: \(vMsg)"
				case .launchctlFailed(let vMsg): return "launchctl failed: \(vMsg)"
			}
		}
	}

	// installs (or replaces) the launchd plist for the given scope
	static func install(inScope: Scope) throws {
		let vBinary = try resolveBinaryPath()
		let vPlistData = try makePlistData(inBinary: vBinary, inScope: inScope)

		switch inScope {
			case .userAgent:
				let vTarget = userAgentPath()
				try? FileManager.default.createDirectory(
					at: vTarget.deletingLastPathComponent(),
					withIntermediateDirectories: true
				)
				try vPlistData.write(to: vTarget, options: .atomic)
				_ = runLaunchctl(inArgs: ["unload", vTarget.path])
				let vResult = runLaunchctl(inArgs: ["load", "-w", vTarget.path])
				if vResult.exitCode != 0 {
					throw InstallError.launchctlFailed(vResult.stderr.isEmpty ? "exit \(vResult.exitCode)" : vResult.stderr)
				}

			case .rootDaemon:
				let vTmp = FileManager.default.temporaryDirectory
					.appendingPathComponent("\(kLabel).plist")
				try vPlistData.write(to: vTmp, options: .atomic)
				let vTarget = rootDaemonPath()
				let vScript = """
				cp \(shellQuote(inString: vTmp.path)) \(shellQuote(inString: vTarget.path)) \
				&& chown root:wheel \(shellQuote(inString: vTarget.path)) \
				&& chmod 644 \(shellQuote(inString: vTarget.path)) \
				; /bin/launchctl bootout system \(shellQuote(inString: vTarget.path)) 2>/dev/null \
				; /bin/launchctl bootstrap system \(shellQuote(inString: vTarget.path))
				"""
				try runWithAdminPrivileges(inScript: vScript)
		}
	}

	// removes the launchd plist for the given scope
	static func uninstall(inScope: Scope) throws {
		switch inScope {
			case .userAgent:
				let vTarget = userAgentPath()
				_ = runLaunchctl(inArgs: ["unload", vTarget.path])
				try? FileManager.default.removeItem(at: vTarget)

			case .rootDaemon:
				let vTarget = rootDaemonPath()
				let vScript = "/bin/launchctl bootout system \(shellQuote(inString: vTarget.path)) 2>/dev/null ; rm -f \(shellQuote(inString: vTarget.path))"
				try runWithAdminPrivileges(inScript: vScript)
		}
	}

	// returns true when the plist file exists for the given scope
	static func isInstalled(inScope: Scope) -> Bool {
		switch inScope {
			case .userAgent: return FileManager.default.fileExists(atPath: userAgentPath().path)
			case .rootDaemon: return FileManager.default.fileExists(atPath: rootDaemonPath().path)
		}
	}

	// stops the service, removes the cache file, and starts the service again
	// as a single privileged operation. Necessary for the root daemon because
	// the cache file is owned by root and the daemon would otherwise just
	// rewrite it from its in-memory copy on the next autosave.
	static func clearCacheAndRestart(inScope: Scope, inCacheURL: URL) throws {
		switch inScope {
			case .userAgent:
				let vPlist = userAgentPath().path
				_ = runLaunchctl(inArgs: ["unload", vPlist])
				try? FileManager.default.removeItem(at: inCacheURL)
				let vResult = runLaunchctl(inArgs: ["load", "-w", vPlist])
				if vResult.exitCode != 0 {
					throw InstallError.launchctlFailed(vResult.stderr)
				}
			case .rootDaemon:
				let vPlist = rootDaemonPath().path
				let vCache = inCacheURL.path
				let vScript = "/bin/launchctl bootout system \(shellQuote(inString: vPlist)) 2>/dev/null ; rm -f \(shellQuote(inString: vCache)) ; /bin/launchctl bootstrap system \(shellQuote(inString: vPlist))"
				try runWithAdminPrivileges(inScript: vScript)
		}
	}

	// ===========================
	// MARK: Internals
	// ===========================

	private static func userAgentPath() -> URL {
		return FileManager.default.homeDirectoryForCurrentUser
			.appendingPathComponent("Library/LaunchAgents/\(kLabel).plist")
	}

	private static func rootDaemonPath() -> URL {
		return URL(fileURLWithPath: "/Library/LaunchDaemons/\(kLabel).plist")
	}

	// resolves an absolute path to the currently running binary
	private static func resolveBinaryPath() throws -> String {
		let vArg0 = CommandLine.arguments[0]
		let vAbs = (vArg0 as NSString).standardizingPath
		if FileManager.default.fileExists(atPath: vAbs) { return vAbs }
		if let vUrl = Bundle.main.executableURL,
		   FileManager.default.fileExists(atPath: vUrl.path) {
			return vUrl.path
		}
		throw InstallError.binaryNotFound
	}

	// builds the launchd plist dictionary serialized as XML data
	private static func makePlistData(inBinary: String, inScope: Scope) throws -> Data {
		var vDict: [String: Any] = [
			"Label": kLabel,
			"ProgramArguments": [inBinary, "--service"],
			"RunAtLoad": true,
			"KeepAlive": true,
			"StandardOutPath": "/tmp/allofit-service.log",
			"StandardErrorPath": "/tmp/allofit-service.err",
			"ThrottleInterval": 10
		]
		if inScope == .rootDaemon {
			vDict["UserName"] = "root"
			// root daemon writes the cache to a system-wide location so any
			// user can read it (rw for root, r for everyone else). The owner
			// env vars let the daemon's Preferences.init read the GUI user's
			// plist directly - otherwise it would see /var/root's empty
			// defaults and only index a couple hundred system files.
			vDict["EnvironmentVariables"] = [
				"ALLOFIT_SYSTEM_INDEX": "1",
				"ALLOFIT_OWNER_USER": NSUserName(),
				"ALLOFIT_OWNER_HOME": FileManager.default.homeDirectoryForCurrentUser.path
			]
		}
		return try PropertyListSerialization.data(
			fromPropertyList: vDict,
			format: .xml,
			options: 0
		)
	}

	// invokes /bin/launchctl with the given arguments and captures output
	private static func runLaunchctl(inArgs: [String]) -> (exitCode: Int32, stdout: String, stderr: String) {
		let vProcess = Process()
		vProcess.executableURL = URL(fileURLWithPath: "/bin/launchctl")
		vProcess.arguments = inArgs
		let vOut = Pipe()
		let vErr = Pipe()
		vProcess.standardOutput = vOut
		vProcess.standardError = vErr
		do {
			try vProcess.run()
			vProcess.waitUntilExit()
		} catch {
			return (-1, "", "\(error)")
		}
		let vOutStr = String(data: vOut.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
		let vErrStr = String(data: vErr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
		return (vProcess.terminationStatus, vOutStr, vErrStr)
	}

	// runs a shell script with administrator privileges through AppleScript;
	// the system shows the standard password prompt the first time
	private static func runWithAdminPrivileges(inScript: String) throws {
		let vEscaped = inScript
			.replacingOccurrences(of: "\\", with: "\\\\")
			.replacingOccurrences(of: "\"", with: "\\\"")
		let vAppleScriptSource = "do shell script \"\(vEscaped)\" with administrator privileges"
		let vScript = NSAppleScript(source: vAppleScriptSource)
		var vErr: NSDictionary?
		let vResult = vScript?.executeAndReturnError(&vErr)
		if vResult == nil {
			let vMessage = vErr?[NSAppleScript.errorMessage] as? String ?? "unknown AppleScript error"
			throw InstallError.authorizationFailed(vMessage)
		}
	}

	// minimal POSIX-style single-quote escape
	private static func shellQuote(inString: String) -> String {
		return "'" + inString.replacingOccurrences(of: "'", with: "'\\''") + "'"
	}
}
