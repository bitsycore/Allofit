import SwiftUI
import AppKit

// SettingsView is the multi-tab Preferences window. It exposes roots,
// exclusions, mounted volume inclusion, background service installation,
// and on-disk cache management.
struct SettingsView: View {

	@EnvironmentObject var model: AppModel
	@EnvironmentObject var prefs: Preferences

	var body: some View {
		TabView {
			RootsTab()
				.tabItem { Label("Roots", systemImage: "folder") }
			ExclusionsTab()
				.tabItem { Label("Exclusions", systemImage: "minus.circle") }
			VolumesTab()
				.tabItem { Label("Volumes", systemImage: "externaldrive") }
			ServiceTab()
				.tabItem { Label("Service", systemImage: "gearshape.2") }
			CacheTab()
				.tabItem { Label("Cache", systemImage: "internaldrive") }
			DiagnosticsTab()
				.tabItem { Label("Diagnostics", systemImage: "stethoscope") }
		}
		.frame(width: 620, height: 480)
		.padding()
	}
}

// ===========================
// MARK: Roots tab
// ===========================

// RootsTab lets the user manage which directories are indexed.
private struct RootsTab: View {

	@EnvironmentObject var prefs: Preferences
	@EnvironmentObject var model: AppModel
	@State private var selection: String?

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			Text("Root folders to index")
				.font(.headline)
			List(prefs.rootPaths, id: \.self, selection: $selection) { vPath in
				Text(vPath)
			}
			.frame(minHeight: 200)

			HStack {
				Button("Add Folder…") { addFolder() }
				Button("Remove") { removeSelected() }
					.disabled(selection == nil)
				Spacer()
				Button("Reindex now") {
					Task { await model.performReindex() }
				}
				.disabled(model.isWorking || model.isIndexing)
			}
			if !model.workMessage.isEmpty {
				Text(model.workMessage)
					.font(.caption)
					.foregroundColor(.secondary)
			}
			Text("Changes take effect on the next reindex. In service mode this stops the daemon, deletes its cache, and restarts it so the fresh process re-scans from scratch.")
				.font(.caption)
				.foregroundColor(.secondary)
		}
	}

	// presents an Open panel to pick a folder, then appends it to rootPaths
	private func addFolder() {
		let vPanel = NSOpenPanel()
		vPanel.canChooseDirectories = true
		vPanel.canChooseFiles = false
		vPanel.allowsMultipleSelection = true
		if vPanel.runModal() == .OK {
			for vUrl in vPanel.urls where !prefs.rootPaths.contains(vUrl.path) {
				prefs.rootPaths.append(vUrl.path)
			}
		}
	}

	// removes the currently-selected root path
	private func removeSelected() {
		guard let vSel = selection else { return }
		prefs.rootPaths.removeAll { $0 == vSel }
		selection = nil
	}
}

// ===========================
// MARK: Exclusions tab
// ===========================

// ExclusionsTab manages the list of paths skipped while indexing.
private struct ExclusionsTab: View {

	@EnvironmentObject var prefs: Preferences
	@State private var selection: String?
	@State private var newExclusion: String = ""

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			Text("Folders excluded from indexing")
				.font(.headline)
			List(prefs.excludedPaths, id: \.self, selection: $selection) { vPath in
				Text(vPath)
			}
			.frame(minHeight: 180)

			HStack {
				TextField("Path or tilde-expanded path", text: $newExclusion)
					.textFieldStyle(.roundedBorder)
				Button("Add") {
					let vTrim = newExclusion.trimmingCharacters(in: .whitespaces)
					if !vTrim.isEmpty {
						let vExpanded = (vTrim as NSString).expandingTildeInPath
						if !prefs.excludedPaths.contains(vExpanded) {
							prefs.excludedPaths.append(vExpanded)
						}
						newExclusion = ""
					}
				}
				Button("Choose Folder…") { chooseFolder() }
			}
			HStack {
				Button("Remove Selected") { removeSelected() }
					.disabled(selection == nil)
				Spacer()
			}
			Text("Entries match exact paths and any descendants. Changes apply on next reindex.")
				.font(.caption)
				.foregroundColor(.secondary)
		}
	}

	private func chooseFolder() {
		let vPanel = NSOpenPanel()
		vPanel.canChooseDirectories = true
		vPanel.canChooseFiles = false
		vPanel.allowsMultipleSelection = true
		if vPanel.runModal() == .OK {
			for vUrl in vPanel.urls where !prefs.excludedPaths.contains(vUrl.path) {
				prefs.excludedPaths.append(vUrl.path)
			}
		}
	}

	private func removeSelected() {
		guard let vSel = selection else { return }
		prefs.excludedPaths.removeAll { $0 == vSel }
		selection = nil
	}
}

// ===========================
// MARK: Volumes tab
// ===========================

// VolumesTab controls whether mounted and network volumes are indexed.
private struct VolumesTab: View {

	@EnvironmentObject var prefs: Preferences
	@State private var detected: [VolumeManager.Volume] = []

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Mounted volumes")
				.font(.headline)

			Toggle("Include external local volumes (USB, Thunderbolt, etc.)",
				   isOn: $prefs.includeMountedVolumes)
			Toggle("Include network volumes (SMB, AFP, NFS)",
				   isOn: $prefs.includeNetworkVolumes)

			Divider()

			Text("Currently mounted")
				.font(.subheadline)
			if detected.isEmpty {
				Text("No external volumes detected.")
					.font(.callout)
					.foregroundColor(.secondary)
			} else {
				List(detected) { vVol in
					HStack {
						Image(systemName: vVol.isNetwork ? "network" : "externaldrive")
						VStack(alignment: .leading) {
							Text(vVol.name)
							Text(vVol.url.path)
								.font(.caption)
								.foregroundColor(.secondary)
						}
						Spacer()
						Text(vVol.isNetwork ? "network" : "local")
							.foregroundColor(.secondary)
							.font(.caption)
					}
				}
			}

			Button("Refresh") { detected = VolumeManager.mountedVolumes() }
			Spacer()
		}
		.onAppear { detected = VolumeManager.mountedVolumes() }
	}
}

// ===========================
// MARK: Service tab
// ===========================

// ServiceTab manages installation of the LaunchAgent or LaunchDaemon that
// keeps the index up to date while the GUI is closed.
private struct ServiceTab: View {

	@EnvironmentObject var prefs: Preferences
	@EnvironmentObject var model: AppModel

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Background service")
				.font(.headline)

			Picker("Mode", selection: $prefs.serviceMode) {
				Text("Off (GUI maintains the index)").tag(Preferences.ServiceMode.none)
				Text("User service (LaunchAgent, no admin needed)").tag(Preferences.ServiceMode.userAgent)
				Text("System service (LaunchDaemon as root, scans everything)").tag(Preferences.ServiceMode.rootDaemon)
			}
			.pickerStyle(.radioGroup)

			Group {
				switch prefs.serviceMode {
					case .none:
						Text("The GUI process indexes and saves the cache itself.")
							.foregroundColor(.secondary)
							.font(.callout)
					case .userAgent:
						Text("A LaunchAgent runs under your user account, even when Allofit is closed. It can only index files your user can read.")
							.foregroundColor(.secondary)
							.font(.callout)
					case .rootDaemon:
						Text("A LaunchDaemon runs as root. It can index every file on disk, but you must grant Full Disk Access to the binary in System Settings → Privacy & Security.")
							.foregroundColor(.secondary)
							.font(.callout)
				}
			}

			HStack {
				Button("Install") {
					Task { await model.performInstallService() }
				}
				.disabled(prefs.serviceMode == .none || model.isWorking)
				Button("Uninstall") {
					Task { await model.performUninstallService() }
				}
				.disabled(prefs.serviceMode == .none || model.isWorking)
				Spacer()
				if model.isWorking {
					ProgressView().controlSize(.small)
				}
				if !model.workMessage.isEmpty {
					Text(model.workMessage)
						.font(.caption)
						.foregroundColor(.secondary)
				}
			}

			Divider()

			Text(currentStatusText())
				.font(.caption)
				.foregroundColor(.secondary)
		}
	}

	private func currentStatusText() -> String {
		let vUser = ServiceInstaller.isInstalled(inScope: .userAgent) ? "installed" : "not installed"
		let vRoot = ServiceInstaller.isInstalled(inScope: .rootDaemon) ? "installed" : "not installed"
		return "User agent: \(vUser)   ·   Root daemon: \(vRoot)"
	}
}

// ===========================
// MARK: Cache tab
// ===========================

// CacheTab shows where the persisted index lives, how big it is, and offers
// shortcuts to reveal the file in Finder or wipe it (forcing a reindex).
private struct CacheTab: View {

	@EnvironmentObject var prefs: Preferences
	@EnvironmentObject var model: AppModel

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Index cache")
				.font(.headline)

			Group {
				LabeledContent("Location") {
					Text(currentCacheURL().path)
						.textSelection(.enabled)
						.font(.system(.callout, design: .monospaced))
				}
				LabeledContent("File exists") {
					Text(cacheFileExists() ? "yes" : "no")
						.font(.callout)
						.foregroundColor(cacheFileExists() ? .primary : .red)
				}
				LabeledContent("Size on disk") {
					Text(formatSize(inBytes: IndexStore.cacheFileSize(at: currentCacheURL())))
						.font(.callout)
						.monospacedDigit()
				}
				LabeledContent("Last modified") {
					Text(cacheFileMtime() ?? "—")
						.font(.callout)
						.monospacedDigit()
				}
				LabeledContent("Entries in memory") {
					Text("\(model.indexedCount)")
						.font(.callout)
						.monospacedDigit()
				}
				LabeledContent("This process") {
					Text(model.isIndexer ? "indexer (owns the cache)" : "reader (watches the cache)")
						.font(.callout)
						.foregroundColor(.secondary)
				}
			}

			Divider()

			HStack {
				Button("Reveal in Finder") {
					NSWorkspace.shared.activateFileViewerSelecting([currentCacheURL()])
				}
				Button("Open Folder") {
					NSWorkspace.shared.open(currentCacheURL().deletingLastPathComponent())
				}
				Button("Reload from disk") {
					model.forceReloadCache()
				}
				.disabled(model.isIndexer)
				.help("Manually re-read the cache file. Useful for verifying the daemon is updating it.")
				Spacer()
				if model.isWorking {
					ProgressView().controlSize(.small)
				}
				Button("Clear Cache", role: .destructive) {
					Task { await model.performClearCache() }
				}
				.disabled(model.isWorking)
			}

			if !model.workMessage.isEmpty {
				Text(model.workMessage)
					.font(.caption)
					.foregroundColor(.secondary)
			}

			Spacer()

			Text("Clearing the cache forces a full reindex. In service mode this stops the daemon, deletes its cache, and starts it again as a single privileged step (one password prompt).")
				.font(.caption)
				.foregroundColor(.secondary)
		}
	}

	// returns the cache URL appropriate for the configured service mode
	private func currentCacheURL() -> URL {
		return IndexStore.cacheURL(forServiceMode: prefs.serviceMode)
	}

	// true if the cache file exists on disk right now
	private func cacheFileExists() -> Bool {
		return FileManager.default.fileExists(atPath: currentCacheURL().path)
	}

	// returns the cache file's mtime as a short string, nil if missing
	private func cacheFileMtime() -> String? {
		guard let vAttrs = try? FileManager.default.attributesOfItem(atPath: currentCacheURL().path),
			  let vMtime = vAttrs[.modificationDate] as? Date
		else { return nil }
		let vFormatter = DateFormatter()
		vFormatter.dateStyle = .short
		vFormatter.timeStyle = .medium
		return vFormatter.string(from: vMtime)
	}

	// formats a byte count as a human-friendly short string
	private func formatSize(inBytes: Int64) -> String {
		if inBytes <= 0 { return "—" }
		let vF = ByteCountFormatter()
		vF.countStyle = .file
		return vF.string(fromByteCount: inBytes)
	}
}

// ===========================
// MARK: Diagnostics tab
// ===========================

// DiagnosticsTab shows live state of the indexer service: whether the
// daemon is running, what the GUI is reading, and the recent service log.
// All of this used to require dropping to Terminal - the tab consolidates
// it so the user can answer "is anything actually happening?" without
// leaving the GUI.
private struct DiagnosticsTab: View {

	@EnvironmentObject var prefs: Preferences
	@EnvironmentObject var model: AppModel
	@State private var daemonStatus: String = "—"
	@State private var serviceLogTail: String = "—"
	@State private var lastRefresh: Date = Date()

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			Text("Live diagnostics")
				.font(.headline)

			if prefs.serviceMode == .rootDaemon {
				fdaWarningPanel
			}

			Group {
				LabeledContent("GUI mode") {
					Text(model.isIndexer ? "indexer" : "reader")
						.font(.callout)
				}
				LabeledContent("Cache path (GUI)") {
					Text(IndexStore.cacheURL(forServiceMode: prefs.serviceMode).path)
						.font(.system(.caption, design: .monospaced))
						.textSelection(.enabled)
				}
				LabeledContent("Cache size") {
					Text(formatSize(IndexStore.cacheFileSize(at: IndexStore.cacheURL(forServiceMode: prefs.serviceMode))))
						.font(.callout)
						.monospacedDigit()
				}
				LabeledContent("Cache mtime") {
					Text(cacheMtimeString() ?? "—")
						.font(.callout)
						.monospacedDigit()
				}
				LabeledContent("Indexer lock holder") {
					Text(daemonStatus)
						.font(.callout)
						.foregroundColor(daemonStatus.contains("running") ? .primary : .red)
				}
				LabeledContent("Service plist") {
					Text(servicePlistStatus())
						.font(.callout)
				}
			}

			Divider()

			Text("Service log tail (/tmp/allofit-service.err)")
				.font(.subheadline)
			ScrollView {
				Text(serviceLogTail)
					.font(.system(.caption, design: .monospaced))
					.textSelection(.enabled)
					.frame(maxWidth: .infinity, alignment: .leading)
			}
			.frame(maxWidth: .infinity, minHeight: 140, maxHeight: 180)
			.background(Color(NSColor.textBackgroundColor))
			.border(Color.secondary.opacity(0.3))

			HStack {
				Button("Refresh now") { refresh() }
				Button("Open log") {
					NSWorkspace.shared.open(URL(fileURLWithPath: "/tmp/allofit-service.err"))
				}
				Spacer()
				Text("auto-refresh every 2s")
					.font(.caption)
					.foregroundColor(.secondary)
			}
		}
		.onAppear { refresh() }
		.onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
			refresh()
		}
	}

	// recomputes the daemon-process state and the log tail
	private func refresh() {
		Task.detached {
			let vStatus = await DiagnosticsTab.computeDaemonStatus(inMode: Preferences.shared.serviceMode)
			let vLog = DiagnosticsTab.readLogTail()
			await MainActor.run {
				self.daemonStatus = vStatus
				self.serviceLogTail = vLog
				self.lastRefresh = Date()
			}
		}
	}

	// reads the lock file's PID and checks whether that process is alive.
	// We use the lock file (world-readable on /Library/.../indexer.lock)
	// instead of `launchctl print system/...` because the latter needs root
	// and would require a password prompt every refresh.
	private static func computeDaemonStatus(inMode: Preferences.ServiceMode) async -> String {
		let vLockPath: String
		switch inMode {
			case .none:
				vLockPath = IndexStore.lockURL(forSystem: false).path
			case .userAgent:
				vLockPath = IndexStore.lockURL(forSystem: false).path
			case .rootDaemon:
				vLockPath = IndexStore.lockURL(forSystem: true).path
		}
		guard FileManager.default.fileExists(atPath: vLockPath) else {
			return "no lock file (\(vLockPath))"
		}
		guard let vPid = IndexerLock.readHolderPid(path: vLockPath) else {
			return "lock file present but empty"
		}
		// signal 0 - probe whether the pid exists without actually signalling
		let vRc = kill(vPid, 0)
		if vRc == 0 || (vRc == -1 && errno == EPERM) {
			return "running (pid \(vPid))"
		}
		return "stale lock (pid \(vPid) not running)"
	}

	// reads the last 30 lines of the service stderr log file
	private static func readLogTail() -> String {
		let vPath = "/tmp/allofit-service.err"
		guard let vData = try? Data(contentsOf: URL(fileURLWithPath: vPath)),
			  let vText = String(data: vData, encoding: .utf8)
		else {
			return "(log file not present at \(vPath))"
		}
		let vLines = vText.split(separator: "\n", omittingEmptySubsequences: false)
		let vTail = vLines.suffix(30)
		return vTail.joined(separator: "\n")
	}

	// describes which launchd plists exist on disk
	private func servicePlistStatus() -> String {
		let vUser = ServiceInstaller.isInstalled(inScope: .userAgent) ? "user ✓" : "user ✗"
		let vRoot = ServiceInstaller.isInstalled(inScope: .rootDaemon) ? "root ✓" : "root ✗"
		return "\(vUser)   \(vRoot)"
	}

	// returns the cache file's modification time as a short string
	private func cacheMtimeString() -> String? {
		let vUrl = IndexStore.cacheURL(forServiceMode: prefs.serviceMode)
		guard let vAttrs = try? FileManager.default.attributesOfItem(atPath: vUrl.path),
			  let vMtime = vAttrs[.modificationDate] as? Date
		else { return nil }
		let vF = DateFormatter()
		vF.dateStyle = .short
		vF.timeStyle = .medium
		return vF.string(from: vMtime)
	}

	// formats a byte count as a human-friendly short string
	private func formatSize(_ inBytes: Int64) -> String {
		if inBytes <= 0 { return "—" }
		let vF = ByteCountFormatter()
		vF.countStyle = .file
		return vF.string(fromByteCount: inBytes)
	}

	// prominent reminder + shortcuts to enable Full Disk Access for the
	// root daemon's binary. Without FDA, the initial scan still works
	// (root has direct filesystem access) but FSEvents will not deliver
	// notifications for newly-created files in protected user folders -
	// exactly the "new files don't appear" symptom.
	private var fdaWarningPanel: some View {
		GroupBox {
			VStack(alignment: .leading, spacing: 6) {
				Label("Full Disk Access required", systemImage: "exclamationmark.shield")
					.font(.subheadline.bold())
					.foregroundColor(.orange)
				Text("The root daemon needs Full Disk Access for FSEvents to deliver new-file notifications. Without it, your initial index appears but newly created files never show up.")
					.font(.caption)
				Text("Binary to grant access to:")
					.font(.caption2)
					.foregroundColor(.secondary)
				Text(daemonBinaryPath() ?? "(not installed)")
					.font(.system(.caption, design: .monospaced))
					.textSelection(.enabled)
				HStack {
					Button("Open Privacy & Security") {
						if let vUrl = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
							NSWorkspace.shared.open(vUrl)
						}
					}
					Button("Copy path") {
						if let vPath = daemonBinaryPath() {
							NSPasteboard.general.clearContents()
							NSPasteboard.general.setString(vPath, forType: .string)
						}
					}
					Button("Reveal binary") {
						if let vPath = daemonBinaryPath() {
							NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: vPath)])
						}
					}
				}
				.controlSize(.small)
			}
		}
	}

	// reads the daemon's binary path out of the installed root LaunchDaemon
	// plist so the user can add the exact path to Full Disk Access
	private func daemonBinaryPath() -> String? {
		let vPlist = URL(fileURLWithPath: "/Library/LaunchDaemons/com.bitsycore.allofit.service.plist")
		guard let vData = try? Data(contentsOf: vPlist),
			  let vDict = (try? PropertyListSerialization.propertyList(from: vData, format: nil)) as? [String: Any],
			  let vArgs = vDict["ProgramArguments"] as? [String],
			  let vBinary = vArgs.first
		else { return nil }
		return vBinary
	}
}
