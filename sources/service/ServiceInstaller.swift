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

	// errors surfaced to the ui
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

	// installs (or replaces) the launchd plist for the given scope. Also
	// copies the binary to a renamed location ("Allofit service") so the
	// daemon process shows up distinctly from the GUI in Activity Monitor /
	// `ps` - both used to be called "Allofit" because they share a binary.
	static func install(inScope: Scope) throws {
		let vBinary = try resolveBinaryPath()
		let vDaemonBinary = daemonBinaryPath(inScope: inScope)
		let vVersionFile = vDaemonBinary + ".version"
		let vVersionString = bundleVersion()
		let vPlistData = try makePlistData(inBinary: vDaemonBinary, inScope: inScope)

		switch inScope {
			case .userAgent:
				// user agent install: filesystem ops as the current user,
				// no sudo needed for either the binary copy or the plist
				let vDaemonDir = (vDaemonBinary as NSString).deletingLastPathComponent
				try? FileManager.default.createDirectory(
					atPath: vDaemonDir,
					withIntermediateDirectories: true
				)
				try? FileManager.default.removeItem(atPath: vDaemonBinary)
				try FileManager.default.copyItem(atPath: vBinary, toPath: vDaemonBinary)
				// sidecar .version file - lets the GUI show which build is
				// installed without having to run the copied binary
				try? vVersionString.write(
					toFile: vVersionFile,
					atomically: true,
					encoding: .utf8
				)

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
				// root daemon install: binary copy + plist install + boot
				// happen inside a single admin-priv script so the user
				// gets ONE password prompt covering all of it
				let vTmp = FileManager.default.temporaryDirectory
					.appendingPathComponent("\(kLabel).plist")
				try vPlistData.write(to: vTmp, options: .atomic)
				let vTarget = rootDaemonPath()
				let vDaemonDir = (vDaemonBinary as NSString).deletingLastPathComponent
				let vScript = """
				mkdir -p \(shellQuote(inString: vDaemonDir)) \
				&& rm -f \(shellQuote(inString: vDaemonBinary)) \
				&& cp \(shellQuote(inString: vBinary)) \(shellQuote(inString: vDaemonBinary)) \
				&& chown root:wheel \(shellQuote(inString: vDaemonBinary)) \
				&& chmod 755 \(shellQuote(inString: vDaemonBinary)) \
				&& printf '%s' \(shellQuote(inString: vVersionString)) > \(shellQuote(inString: vVersionFile)) \
				&& chmod 644 \(shellQuote(inString: vVersionFile)) \
				&& cp \(shellQuote(inString: vTmp.path)) \(shellQuote(inString: vTarget.path)) \
				&& chown root:wheel \(shellQuote(inString: vTarget.path)) \
				&& chmod 644 \(shellQuote(inString: vTarget.path)) \
				; /bin/launchctl bootout system \(shellQuote(inString: vTarget.path)) 2>/dev/null \
				; /bin/launchctl bootstrap system \(shellQuote(inString: vTarget.path))
				"""
				try runWithAdminPrivileges(inScript: vScript)
		}
	}

	// removes the launchd plist AND the renamed binary copy AND the
	// sidecar .version file for the given scope
	static func uninstall(inScope: Scope) throws {
		let vDaemonBinary = daemonBinaryPath(inScope: inScope)
		let vVersionFile = vDaemonBinary + ".version"
		switch inScope {
			case .userAgent:
				let vTarget = userAgentPath()
				_ = runLaunchctl(inArgs: ["unload", vTarget.path])
				try? FileManager.default.removeItem(at: vTarget)
				try? FileManager.default.removeItem(atPath: vDaemonBinary)
				try? FileManager.default.removeItem(atPath: vVersionFile)

			case .rootDaemon:
				let vTarget = rootDaemonPath()
				let vScript = """
				/bin/launchctl bootout system \(shellQuote(inString: vTarget.path)) 2>/dev/null \
				; rm -f \(shellQuote(inString: vTarget.path)) \(shellQuote(inString: vDaemonBinary)) \(shellQuote(inString: vVersionFile))
				"""
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

	// stops the running daemon for the given scope without uninstalling.
	// The plist file stays on disk so a later start() (or app relaunch
	// since RunAtLoad=true) brings it back. Use cases: temporary disable,
	// freeing FSEvents resources, or pre-flight before a manual reindex.
	static func stop(inScope: Scope) throws {
		switch inScope {
			case .userAgent:
				let vPlist = userAgentPath().path
				let vResult = runLaunchctl(inArgs: ["unload", vPlist])
				if vResult.exitCode != 0 {
					throw InstallError.launchctlFailed(vResult.stderr.isEmpty ? "exit \(vResult.exitCode)" : vResult.stderr)
				}
			case .rootDaemon:
				let vPlist = rootDaemonPath().path
				let vScript = "/bin/launchctl bootout system \(shellQuote(inString: vPlist))"
				try runWithAdminPrivileges(inScript: vScript)
		}
	}

	// starts a previously-installed but currently-stopped daemon.
	static func start(inScope: Scope) throws {
		switch inScope {
			case .userAgent:
				let vPlist = userAgentPath().path
				let vResult = runLaunchctl(inArgs: ["load", "-w", vPlist])
				if vResult.exitCode != 0 {
					throw InstallError.launchctlFailed(vResult.stderr.isEmpty ? "exit \(vResult.exitCode)" : vResult.stderr)
				}
			case .rootDaemon:
				let vPlist = rootDaemonPath().path
				let vScript = "/bin/launchctl bootstrap system \(shellQuote(inString: vPlist))"
				try runWithAdminPrivileges(inScript: vScript)
		}
	}

	// true if the daemon process for the given scope is currently alive.
	// We check by reading the indexer lock file's PID and probing with
	// kill(pid, 0) - cheaper and non-privileged compared to launchctl.
	static func isRunning(inScope: Scope) -> Bool {
		let vSystem = (inScope == .rootDaemon)
		let vLockPath = IndexStore.lockURL(forSystem: vSystem).path
		guard let vPid = IndexerLock.readHolderPid(path: vLockPath) else { return false }
		// signal 0 = check-only; EPERM means "process exists but we lack
		// permission to signal it", which is still "alive"
		let vRc = kill(vPid, 0)
		if vRc == 0 { return true }
		if vRc == -1 && errno == EPERM { return true }
		return false
	}

	// returns the version stamped into the installed daemon binary's
	// sidecar .version file (written at install time). nil if the
	// service isn't installed or the sidecar is missing/corrupt.
	static func installedVersion(inScope: Scope) -> String? {
		let vPath = daemonBinaryPath(inScope: inScope) + ".version"
		guard let vText = try? String(contentsOfFile: vPath, encoding: .utf8) else {
			return nil
		}
		let vTrimmed = vText.trimmingCharacters(in: .whitespacesAndNewlines)
		return vTrimmed.isEmpty ? nil : vTrimmed
	}

	// returns the version of the running .app bundle (what would be
	// installed if the user clicks Install right now)
	static func bundleVersion() -> String {
		return (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
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

	// Filesystem path where the daemon's binary is installed. We use a
	// renamed copy ("Allofit service") so the daemon process is named
	// differently from the GUI in Activity Monitor / ps - both used to
	// be just "Allofit" because they shared the same on-disk binary.
	// The filename embedded in argv[0] is what those tools display.
	static func daemonBinaryPath(inScope: Scope) -> String {
		switch inScope {
			case .userAgent:
				return NSHomeDirectory()
					+ "/Library/Application Support/Allofit/Allofit Service"
			case .rootDaemon:
				return "/Library/Application Support/Allofit/Allofit Service"
		}
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

	// runs a shell script with administrator privileges. Bridges
	// AdminShell.Error into ServiceInstaller.InstallError so the calling
	// SettingsView ui gets a single error type to surface.
	private static func runWithAdminPrivileges(inScript: String) throws {
		do {
			_ = try AdminShell.run(inScript)
		} catch let vErr as AdminShell.Error {
			throw InstallError.authorizationFailed(vErr.errorDescription ?? "\(vErr)")
		}
	}

	// shell-quote helper, delegating to the shared AdminShell quoter so
	// both call sites use the same escaping rules
	private static func shellQuote(inString: String) -> String {
		return AdminShell.quote(inString)
	}
}
