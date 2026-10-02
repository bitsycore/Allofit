import SwiftUI
import AppKit
import ServiceManagement

// SettingsView is the Preferences window, grouped like Everything's options:
// General (app behavior), Indexes (what gets indexed), Performance (update
// timings) and Advanced (background service, cache, diagnostics).
struct SettingsView: View {

	@EnvironmentObject var model: AppModel
	@EnvironmentObject var prefs: Preferences

	var body: some View {
		TabView {
			GeneralTab()
				.tabItem { Label("General", systemImage: "gearshape") }
			IndexesTab()
				.tabItem { Label("Indexes", systemImage: "folder") }
			PerformanceTab()
				.tabItem { Label("Performance", systemImage: "speedometer") }
			AdvancedTab()
				.tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
		}
		.frame(width: 620, height: 500)
		.padding()
	}
}

// ===========================
// MARK: General tab
// ===========================

// GeneralTab holds the app-level behavior: menu bar icon, global shortcut,
// start at login, and how results react to double-click / highlighting.
private struct GeneralTab: View {

	@EnvironmentObject var prefs: Preferences
	// availability of the chosen global shortcut
	@ObservedObject private var hotKey = GlobalHotKey.shared
	// current login item state, read from the system
	@State private var loginStatus = SMAppService.mainApp.status
	// last error from registering the login item
	@State private var loginError: String?

	var body: some View {
		// plain sections like the other tabs: a .grouped Form drew hairline
		// panel borders at fractional positions that flickered on refresh
		VStack(alignment: .leading, spacing: 12) {
			Text("Access")
				.font(.headline)
			Form {
				// checkboxes get a left-column label like the pickers, so every
				// control starts on the same vertical line
				LabeledContent("Menu bar:") {
					Toggle("Show Allofit in the menu bar", isOn: $prefs.showMenuBarIcon)
				}
				Picker("Global shortcut:", selection: $prefs.globalHotKey) {
					ForEach(HotKeyPreset.allCases) { vPreset in
						Text(vPreset.title).tag(vPreset)
					}
				}
				.frame(maxWidth: 260)
				if !hotKey.isAvailable {
					Text("This shortcut is already used by another app. Pick another one.")
						.font(.caption)
						.foregroundColor(.orange)
				}
				LabeledContent("Login:") {
					Toggle("Start Allofit at login", isOn: loginBinding)
				}
				if loginStatus == .requiresApproval {
					HStack {
						Text("Approve Allofit in System Settings > General > Login Items.")
							.font(.caption)
							.foregroundColor(.orange)
						Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
							.controlSize(.small)
					}
				}
				if let vError = loginError {
					Text(vError)
						.font(.caption)
						.foregroundColor(.red)
				}
			}

			Divider()

			Text("Results")
				.font(.headline)
			Form {
				Picker("Double-click or Return:", selection: $prefs.primaryAction) {
					Text("Opens the file").tag(Preferences.PrimaryAction.open)
					Text("Reveals it in Finder").tag(Preferences.PrimaryAction.reveal)
				}
				.frame(maxWidth: 360)
				LabeledContent("Highlighting:") {
					Toggle("Highlight matches in names and paths", isOn: $prefs.highlightMatches)
				}
			}

			Divider()

			Text("Finder")
				.font(.headline)
			Text("Right-click a folder in Finder and choose Quick Actions (or Services) > Search in Allofit to search inside it. Dropping a folder on the Dock icon does the same.")
				.font(.caption)
				.foregroundColor(.secondary)
				.fixedSize(horizontal: false, vertical: true)
			Spacer()
		}
		.onAppear { loginStatus = SMAppService.mainApp.status }
	}

	// registers / unregisters the app as a login item
	private var loginBinding: Binding<Bool> {
		Binding(
			get: { loginStatus == .enabled || loginStatus == .requiresApproval },
			set: { vEnabled in
				do {
					if vEnabled {
						try SMAppService.mainApp.register()
					} else {
						try SMAppService.mainApp.unregister()
					}
					loginError = nil
				} catch {
					loginError = "Couldn't change the login item: \(error.localizedDescription)"
				}
				loginStatus = SMAppService.mainApp.status
			}
		)
	}
}

// ===========================
// MARK: Grouping tabs
// ===========================

// IndexesTab groups what gets indexed: root folders, exclusions, volumes
private struct IndexesTab: View {

	// sections of the tab
	private enum Section: String, CaseIterable, Identifiable {
		case folders = "Folders"
		case exclusions = "Exclusions"
		case volumes = "Volumes"
		var id: String { rawValue }
	}

	// section currently shown
	@State private var section: Section = .folders

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Picker("", selection: $section) {
				ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
			}
			.pickerStyle(.segmented)
			.labelsHidden()
			// pinned to the top so every section starts right below the
			// picker (a section without a trailing Spacer would otherwise
			// be centered vertically)
			Group {
				switch section {
					case .folders: RootsTab()
					case .exclusions: ExclusionsTab()
					case .volumes: VolumesTab()
				}
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		}
	}
}

// AdvancedTab groups the power-user pages: background service, cache file
// and live diagnostics
private struct AdvancedTab: View {

	// sections of the tab
	private enum Section: String, CaseIterable, Identifiable {
		case service = "Service"
		case cache = "Cache"
		case diagnostics = "Diagnostics"
		var id: String { rawValue }
	}

	// section currently shown
	@State private var section: Section = .service

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Picker("", selection: $section) {
				ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
			}
			.pickerStyle(.segmented)
			.labelsHidden()
			// pinned to the top, see IndexesTab
			Group {
				switch section {
					case .service: ServiceTab()
					case .cache: CacheTab()
					case .diagnostics: DiagnosticsTab()
				}
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		}
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
			Text("In built-in mode, changes apply automatically: new folders are scanned and removed ones dropped from the index. With a service, they apply when the service restarts; Reindex now stops the daemon, deletes its cache, and restarts it so the fresh process re-scans from scratch.")
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
				TextField("Path, e.g. ~/Projects/build", text: $newExclusion)
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
			Text("Entries match exact paths and any descendants. In built-in mode, matching entries are removed from the index right away.")
				.font(.caption)
				.foregroundColor(.secondary)
		}
	}

	// presents an Open panel and adds the picked folders as exclusions
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

	// removes the currently-selected exclusion
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
// MARK: Performance tab
// ===========================

// PerformanceTab sets how quickly file changes reach the index and the open
// search results, per app state. Longer delays when Allofit isn't being
// looked at keep it nearly idle in the background; focusing a window always
// catches up at once.
private struct PerformanceTab: View {

	@EnvironmentObject var prefs: Preferences

	// preset choices offered by each picker, in seconds
	private let kForegroundDelays: [Double] = [0.5, 1, 2, 3, 5, 10]
	private let kBackgroundDelays: [Double] = [3, 5, 10, 15, 30, 60, 120]
	private let kHiddenDelays: [Double] = [15, 30, 60, 120, 300, 600]
	private let kForegroundRefreshes: [Double] = [0.5, 1, 2, 3, 5]
	private let kBackgroundRefreshes: [Double] = [1, 3, 5, 10, 20, 30]
	// FSEvents' own delivery latency, added to the estimates
	private let kEventLatency: Double = 0.2

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Index updates")
				.font(.headline)
			Text("How long file changes are collected before they are applied to the index. Longer delays mean less work: repeated writes to the same file are checked only once.")
				.font(.caption)
				.foregroundColor(.secondary)
				.fixedSize(horizontal: false, vertical: true)
			Form {
				secondsPicker("While Allofit is focused", inChoices: kForegroundDelays, inValue: $prefs.updateDelayForeground)
				secondsPicker("While another app is focused", inChoices: kBackgroundDelays, inValue: $prefs.updateDelayBackground)
				secondsPicker("With no window visible", inChoices: kHiddenDelays, inValue: $prefs.updateDelayHidden)
			}

			Divider()

			Text("Result refresh")
				.font(.headline)
			Text("Minimum time between two refreshes of the open search results when files change. Typing always searches immediately.")
				.font(.caption)
				.foregroundColor(.secondary)
				.fixedSize(horizontal: false, vertical: true)
			Form {
				secondsPicker("While Allofit is focused", inChoices: kForegroundRefreshes, inValue: $prefs.refreshIntervalForeground)
				secondsPicker("While another app is focused", inChoices: kBackgroundRefreshes, inValue: $prefs.refreshIntervalBackground)
			}

			Divider()

			Text(summaryText)
				.font(.callout)
				.foregroundColor(.secondary)
				.fixedSize(horizontal: false, vertical: true)
			HStack {
				Spacer()
				Button("Restore Defaults") { prefs.resetTimings() }
			}
			Spacer()
		}
	}

	// a picker over preset durations; a stored value outside the presets
	// (set by hand) is kept selectable instead of showing a blank picker
	private func secondsPicker(_ inLabel: String, inChoices: [Double], inValue: Binding<Double>) -> some View {
		let vChoices = Array(Set(inChoices + [inValue.wrappedValue])).sorted()
		return Picker(inLabel, selection: inValue) {
			ForEach(vChoices, id: \.self) { vSeconds in
				Text(Self.durationText(inSeconds: vSeconds)).tag(vSeconds)
			}
		}
		.frame(maxWidth: 360)
	}

	// estimated delay before a changed file appears in the results
	private var summaryText: String {
		let vForeground = kEventLatency + prefs.updateDelayForeground + prefs.refreshIntervalForeground
		let vBackground = kEventLatency + prefs.updateDelayBackground + prefs.refreshIntervalBackground
		return "A changed file shows up in the results after about \(Self.durationText(inSeconds: vForeground)) while Allofit is focused, and \(Self.durationText(inSeconds: vBackground)) while another app is. With no window visible nothing is refreshed; showing a window applies every pending change at once."
	}

	// "0.5 s", "15 s", "1 min", "1 min 30 s"
	private static func durationText(inSeconds: Double) -> String {
		if inSeconds < 60 {
			let vRounded = (inSeconds * 10).rounded() / 10
			return vRounded == vRounded.rounded() ? "\(Int(vRounded)) s" : String(format: "%.1f s", vRounded)
		}
		let vMinutes = Int(inSeconds) / 60
		let vRest = Int(inSeconds) % 60
		return vRest == 0 ? "\(vMinutes) min" : "\(vMinutes) min \(vRest) s"
	}
}

// ===========================
// MARK: Service tab
// ===========================

// ServiceTab manages the LaunchAgent / LaunchDaemon that keeps the index
// up to date while the GUI is closed. Surfaces install/uninstall, run-
// state (stop/start), and the gap between the version that's currently
// installed on disk vs the bundle the user is running right now.
private struct ServiceTab: View {

	@EnvironmentObject var prefs: Preferences
	@EnvironmentObject var model: AppModel
	// tick value to force the status block to recompute on a timer; the
	// status doesn't observe @Published changes since it reads file
	// system state directly, so we need an explicit refresh signal
	@State private var statusTick: Int = 0
	// mode picked in the radio group; only saved by a successful Install
	// (or Uninstall), so picking a mode alone never leaves the app waiting
	// on a service that doesn't exist
	@State private var draftMode: Preferences.ServiceMode?
	// confirmation for Uninstall
	@State private var confirmUninstall = false

	// the mode shown and acted on: the draft, else the saved mode
	private var chosenMode: Preferences.ServiceMode {
		return draftMode ?? prefs.serviceMode
	}

	// launchd scope of the chosen mode, nil for Off
	private var scope: ServiceInstaller.Scope? {
		switch chosenMode {
			case .none: return nil
			case .userAgent: return .userAgent
			case .rootDaemon: return .rootDaemon
		}
	}

	// the radio group writes the draft, not the preference
	private var modeBinding: Binding<Preferences.ServiceMode> {
		Binding(get: { chosenMode }, set: { draftMode = $0 })
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Background service")
				.font(.headline)

			Picker("Mode", selection: modeBinding) {
				Text("Off (GUI maintains the index)").tag(Preferences.ServiceMode.none)
				Text("User service (LaunchAgent, no admin needed)").tag(Preferences.ServiceMode.userAgent)
				Text("System service (LaunchDaemon as root, scans everything)").tag(Preferences.ServiceMode.rootDaemon)
			}
			.pickerStyle(.radioGroup)

			if prefs.serviceMode != .none && model.activeServiceMode == .none {
				Text("The saved service isn't installed, so Allofit is indexing on its own. Install it again or choose Off.")
					.font(.callout)
					.foregroundColor(.orange)
					.fixedSize(horizontal: false, vertical: true)
			}

			Group {
				switch chosenMode {
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

			installDescription

			actionButtons

			if !model.workMessage.isEmpty {
				HStack(spacing: 6) {
					if model.isWorking {
						ProgressView().controlSize(.small)
					}
					Text(model.workMessage)
						.font(.caption)
						.foregroundColor(.secondary)
				}
			}

			Divider()

			statusBlock
		}
		.onAppear { statusTick &+= 1 }
		.onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
			statusTick &+= 1
		}
		.onChange(of: model.isWorking) { _, _ in statusTick &+= 1 }
	}

	// ===========================
	// MARK: Install explanation
	// ===========================

	@ViewBuilder
	private var installDescription: some View {
		if let vScope = scope {
			GroupBox {
				VStack(alignment: .leading, spacing: 4) {
					Text("Install will:")
						.font(.caption.bold())
					Text("• Copy the running binary to \(daemonBinaryPath(for: vScope)) so the daemon has a stable on-disk path that won't break if you move Allofit.app.")
						.font(.caption)
					Text("• Write the launchd plist that runs it as \(vScope == .rootDaemon ? "root" : "your user").")
						.font(.caption)
					Text("• Start the daemon via launchctl bootstrap.")
						.font(.caption)
					if vScope == .rootDaemon {
						Text("• Prompt once for your administrator password (steps run as one privileged script).")
							.font(.caption)
					}
					Text("Reinstall after updating Allofit: the service runs its own copy of the app, which doesn't update by itself.")
						.font(.caption)
						.foregroundColor(.secondary)
						.padding(.top, 2)
				}
				.frame(maxWidth: .infinity, alignment: .leading)
			}
		}
	}

	// ===========================
	// MARK: Action buttons
	// ===========================

	private var actionButtons: some View {
		let vInstalled = scope.map { ServiceInstaller.isInstalled(inScope: $0) } ?? false
		let vRunning = scope.map { ServiceInstaller.isRunning(inScope: $0) } ?? false
		_ = statusTick  // re-read the file-system status on each tick
		return HStack {
			Button("Install") {
				let vMode = chosenMode
				Task {
					await model.performInstallService(inMode: vMode)
					draftMode = nil
				}
			}
			.disabled(chosenMode == .none || model.isWorking)
			Button("Uninstall…") { confirmUninstall = true }
				.disabled(chosenMode == .none || !vInstalled || model.isWorking)
			Button("Stop") {
				let vMode = chosenMode
				Task { await model.performStopService(inMode: vMode) }
			}
			.disabled(!vInstalled || !vRunning || model.isWorking)
			Button("Start") {
				let vMode = chosenMode
				Task { await model.performStartService(inMode: vMode) }
			}
			.disabled(!vInstalled || vRunning || model.isWorking)
			Spacer()
		}
		.confirmationDialog("Uninstall the background service?", isPresented: $confirmUninstall) {
			Button("Uninstall", role: .destructive) {
				let vMode = chosenMode
				Task {
					await model.performUninstallService(inMode: vMode)
					draftMode = nil
				}
			}
		} message: {
			Text("Allofit goes back to indexing on its own while it's open.")
		}
	}

	// ===========================
	// MARK: Status block
	// ===========================

	private var statusBlock: some View {
		_ = statusTick  // ensure recomputation each tick
		let vScope = scope
		let vInstalled = vScope.map { ServiceInstaller.isInstalled(inScope: $0) } ?? false
		let vRunning = vScope.map { ServiceInstaller.isRunning(inScope: $0) } ?? false
		let vInstalledVer = vScope.flatMap { ServiceInstaller.installedVersion(inScope: $0) }
		let vBundleVer = ServiceInstaller.bundleVersion()
		let vStale = vInstalled && vInstalledVer != nil && vInstalledVer != vBundleVer

		return VStack(alignment: .leading, spacing: 4) {
			LabeledContent("Service installed") {
				Text(vInstalled ? "yes" : "no")
					.foregroundColor(vInstalled ? .primary : .secondary)
					.font(.callout)
			}
			LabeledContent("Currently running") {
				Text(vRunning ? "yes" : "no")
					.foregroundColor(vRunning ? .green : .secondary)
					.font(.callout)
			}
			LabeledContent("Installed version") {
				Text(vInstalledVer ?? "-")
					.font(.callout)
					.monospacedDigit()
			}
			LabeledContent("This app's version") {
				HStack(spacing: 6) {
					Text(vBundleVer)
						.font(.callout)
						.monospacedDigit()
					if vStale {
						Text("Reinstall to update")
							.font(.caption)
							.foregroundColor(.orange)
					}
				}
			}
			if let vScope = vScope {
				LabeledContent("Other scope") {
					Text(otherScopeStatusText(currentScope: vScope))
						.font(.caption)
						.foregroundColor(.secondary)
				}
			}
		}
	}

	// path of the daemon-renamed binary copy, used in the explanatory blurb
	private func daemonBinaryPath(for inScope: ServiceInstaller.Scope) -> String {
		return ServiceInstaller.daemonBinaryPath(inScope: inScope)
	}

	// summary of the *other* scope's install state so the user can see at
	// a glance that they don't have a stray install on the unused side
	private func otherScopeStatusText(currentScope inCurrent: ServiceInstaller.Scope) -> String {
		let vOther: ServiceInstaller.Scope = (inCurrent == .userAgent) ? .rootDaemon : .userAgent
		let vLabel = (vOther == .userAgent) ? "User agent" : "Root daemon"
		let vInstalled = ServiceInstaller.isInstalled(inScope: vOther)
		let vRunning = vInstalled && ServiceInstaller.isRunning(inScope: vOther)
		if vRunning { return "\(vLabel): running" }
		if vInstalled { return "\(vLabel): installed (stopped)" }
		return "\(vLabel): not installed"
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
	// confirmation for Clear Cache
	@State private var confirmClear = false

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
					Text(Formatters.sizeOrDash(bytes: IndexStore.cacheFileSize(at: currentCacheURL())))
						.font(.callout)
						.monospacedDigit()
				}
				LabeledContent("Last modified") {
					Text(cacheFileMtime() ?? "-")
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
				Button("Clear Cache…", role: .destructive) {
					confirmClear = true
				}
				.disabled(model.isWorking)
				.confirmationDialog("Clear the index cache?", isPresented: $confirmClear) {
					Button("Clear and Rebuild", role: .destructive) {
						Task { await model.performClearCache() }
					}
				} message: {
					Text("The whole index is rebuilt from scratch, which can take a few minutes.")
				}
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
	@State private var daemonStatus: String = "-"
	@State private var serviceLogTail: String = "-"
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
					Text(Formatters.sizeOrDash(bytes: IndexStore.cacheFileSize(at: IndexStore.cacheURL(forServiceMode: prefs.serviceMode))))
						.font(.callout)
						.monospacedDigit()
				}
				LabeledContent("Cache mtime") {
					Text(cacheMtimeString() ?? "-")
						.font(.callout)
						.monospacedDigit()
				}
				LabeledContent("Indexer lock holder") {
					Text(daemonStatus)
						.font(.callout)
						.foregroundColor(daemonStatus.hasPrefix("running") ? .primary : .red)
				}
				LabeledContent("Service plist") {
					Text(servicePlistStatus())
						.font(.callout)
				}
			}

			Divider()

			Text("Service log tail (\(DiagnosticsTab.logPath(inMode: prefs.serviceMode) ?? "no service"))")
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
					// revealed rather than opened: Finder never runs it
					if let vPath = DiagnosticsTab.logPath(inMode: prefs.serviceMode) {
						NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: vPath)])
					}
				}
				.disabled(DiagnosticsTab.logPath(inMode: prefs.serviceMode) == nil)
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
			let vLog = DiagnosticsTab.readLogTail(inPath: DiagnosticsTab.logPath(inMode: Preferences.shared.serviceMode))
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
	// nonisolated so the detached Task can call without an actor hop.
	private nonisolated static func computeDaemonStatus(inMode: Preferences.ServiceMode) async -> String {
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

	// log file of the service for a mode, nil when no service is used
	nonisolated static func logPath(inMode: Preferences.ServiceMode) -> String? {
		switch inMode {
			case .none: return nil
			case .userAgent: return ServiceInstaller.logPath(inScope: .userAgent)
			case .rootDaemon: return ServiceInstaller.logPath(inScope: .rootDaemon)
		}
	}

	// reads the last 30 lines of the service log file
	private nonisolated static func readLogTail(inPath: String?) -> String {
		guard let vPath = inPath else { return "(no background service: Allofit indexes in its own process)" }
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
