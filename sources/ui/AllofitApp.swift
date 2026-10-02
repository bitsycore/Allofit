import SwiftUI
import AppKit
import Combine

// AllofitApp is the SwiftUI App for the GUI mode. The real entry point lives
// in Main.swift, which routes between this and the headless --service mode.
struct AllofitApp: App {

	// AppKit delegate that wrestles focus from whichever app was frontmost,
	// needed because SwiftPM-launched binaries default to .accessory policy
	@NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
	// shared application state injected into the view tree. Held with
	// @State (not @StateObject) so the App does not subscribe to it: the
	// model's counters change on every index update, and observing them
	// here would re-evaluate every scene each time.
	@State private var model = AppModel()
	// session-scoped store of sudo-staged user-readable copies. Sits
	// alongside AppModel so both the Table (lock badge on rows) and
	// the PreviewPane observe the same authorization state.
	@StateObject private var access = AccessManager()

	var body: some Scene {
		WindowGroup("Allofit") {
			AllofitWindowContent(model: model, access: access)
		}
		.windowToolbarStyle(.unified)
		.defaultSize(width: 1100, height: 640)
		.commands {
			// custom About panel with a clickable repo link in the credits
			CommandGroup(replacing: .appInfo) {
				Button("About Allofit") { showAboutPanel() }
			}
			CommandGroup(after: .appInfo) {
				// ⇧⌘R rather than ⌘R: a full rebuild is too costly to trigger
				// by accident
				Button("Rebuild Index") {
					Task { await model.performReindex() }
				}
				.keyboardShortcut("r", modifiers: [.command, .shift])
			}
			// SwiftUI provides File > New Window (⌘N) automatically for a
			// WindowGroup; nothing to add here. Additional windows share the
			// AppModel/AccessManager StateObjects defined above, so the index
			// (and current search/sort) stays in sync across them - only the
			// per-window selection / column-customization differ.
			// ⌘F focuses the search field. Standard Find-style shortcut.
			// SearchField's Coordinator observes the notification and calls
			// makeFirstResponder on its underlying NSSearchField.
			CommandGroup(after: .pasteboard) {
				Button("Find") {
					NotificationCenter.default.post(name: .allofitFocusSearch, object: nil)
				}
				.keyboardShortcut("f", modifiers: [.command])
			}
		}
		Settings {
			SettingsView()
				.environmentObject(model)
				.environmentObject(Preferences.shared)
				.environmentObject(access)
		}
	}
}

// AllofitWindowContent is the per-window root: it creates a fresh
// WindowSearchModel for each window so the query / visible slice are
// independent, while the shared AppModel + AccessManager + Preferences
// are injected from the App level.
//
// The model/access StateObjects must be passed in via init so the
// @StateObject autoclosure for WindowSearchModel can capture the shared
// AppModel instance - @EnvironmentObject isn't available at init time.
struct AllofitWindowContent: View {

	let model: AppModel
	let access: AccessManager
	@StateObject private var searchModel: WindowSearchModel

	// creates the per-window content around the shared models
	init(model inModel: AppModel, access inAccess: AccessManager) {
		self.model = inModel
		self.access = inAccess
		// @autoclosure: SwiftUI evaluates this exactly once when the view
		// first appears, so re-renders won't keep allocating new search models
		_searchModel = StateObject(wrappedValue: WindowSearchModel(model: inModel))
	}

	var body: some View {
		ContentView()
			.environmentObject(model)
			.environmentObject(Preferences.shared)
			.environmentObject(access)
			.environmentObject(searchModel)
			.frame(minWidth: 760, minHeight: 480)
			.background(MainWindowMarker())
			.background(WindowVisibilityReporter { vVisible in
				searchModel.setWindowVisible(vVisible)
			})
			.onAppear {
				model.start()
			}
			.onDisappear {
				model.saveCache()
			}
	}
}

// MainWindowMarker captures the main WindowGroup's NSWindow into
// AppDelegate.mainWindow so applicationShouldHandleReopen can re-show that
// specific window without triggering AppKit's default behavior of unhiding
// every hidden window the process holds (which would also unhide the
// Settings window when the user just wants the main one back).
//
// Uses an NSView subclass so we can hook viewDidMoveToWindow - that is the
// reliable place where the view's .window property is guaranteed non-nil.
// DispatchQueue.main.async sometimes ran before SwiftUI attached the view.
struct MainWindowMarker: NSViewRepresentable {

	// NSView that records its window as the main window
	final class MarkerView: NSView {
		// captures the window once the view is attached to it
		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			guard let vWindow = self.window else { return }
			// stop AppKit from deallocating the window when the user clicks
			// the red close button - we hold a strong ref in AppDelegate and
			// re-show this same window object on the next dock-icon click.
			// Otherwise the weak ref would die and dock-click would do nothing.
			vWindow.isReleasedWhenClosed = false
			AppDelegate.mainWindow = vWindow
		}
	}

	// creates the marker view
	func makeNSView(context inContext: Context) -> NSView {
		return MarkerView(frame: .zero)
	}

	// rebinds if SwiftUI ever swaps us into a different window
	func updateNSView(_ inView: NSView, context inContext: Context) {
		if let vWindow = inView.window, AppDelegate.mainWindow !== vWindow {
			vWindow.isReleasedWhenClosed = false
			AppDelegate.mainWindow = vWindow
		}
	}
}

// WindowVisibilityReporter tells its owner whether the hosting window is
// actually on screen (AppKit occlusion state), so a closed, minimized or
// fully covered window can skip work nobody would see.
struct WindowVisibilityReporter: NSViewRepresentable {

	// called on main with true when the window becomes visible
	let onChange: (Bool) -> Void

	// NSView that follows its window's occlusion notifications
	final class ReporterView: NSView {

		// latest callback from the SwiftUI side
		var onChange: ((Bool) -> Void)?
		// occlusion observer for the current window
		private var observer: NSObjectProtocol?

		// re-targets the observer whenever the view changes window
		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			if let vObserver = observer {
				NotificationCenter.default.removeObserver(vObserver)
				observer = nil
			}
			guard let vWindow = window else {
				report(false)
				return
			}
			observer = NotificationCenter.default.addObserver(
				forName: NSWindow.didChangeOcclusionStateNotification,
				object: vWindow,
				queue: .main
			) { [weak self, weak vWindow] _ in
				guard let vWin = vWindow else { return }
				MainActor.assumeIsolated {
					self?.report(vWin.occlusionState.contains(.visible))
				}
			}
			report(vWindow.occlusionState.contains(.visible))
		}

		// forwards a visibility change to the owner and the app-wide tracker
		private func report(_ inVisible: Bool) {
			onChange?(inVisible)
			AppActivity.shared.setWindow(ObjectIdentifier(self), visible: inVisible)
		}

		// removes the occlusion observer; a destroyed window no longer
		// counts as visible
		deinit {
			if let vObserver = observer {
				NotificationCenter.default.removeObserver(vObserver)
			}
			let vId = ObjectIdentifier(self)
			DispatchQueue.main.async {
				AppActivity.shared.setWindow(vId, visible: false)
			}
		}
	}

	// creates the reporter view
	func makeNSView(context inContext: Context) -> NSView {
		let vView = ReporterView(frame: .zero)
		vView.onChange = onChange
		return vView
	}

	// keeps the view's callback current
	func updateNSView(_ inView: NSView, context inContext: Context) {
		(inView as? ReporterView)?.onChange = onChange
	}
}

// Opens the standard macOS About panel with a clickable GitHub link in the
// Credits section. App name + version come from Info.plist automatically.
private func showAboutPanel() {
	let vUrlString = "https://github.com/bitsycore/Allofit"
	let vCredits = NSMutableAttributedString(
		string: vUrlString,
		attributes: [
			.link: URL(string: vUrlString) as Any,
			.font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
			.foregroundColor: NSColor.linkColor
		]
	)
	NSApplication.shared.orderFrontStandardAboutPanel(options: [
		.credits: vCredits
	])
	NSApp.activate(ignoringOtherApps: true)
}

// AppDelegate handles the activation lifecycle. It also keeps the app
// resident after the window closes so the in-memory index stays warm and
// the next window open is instant - the same pattern Finder and Safari use.
final class AppDelegate: NSObject, NSApplicationDelegate {

	// strong ref to the main app window so it stays in RAM after the user
	// closes it (paired with isReleasedWhenClosed=false on the window). This
	// lets a dock-icon click bring the *same* window back instead of letting
	// AppKit unhide every hidden window the app holds (Settings included).
	// Strong, not weak, because SwiftUI tears down its content view tree on
	// close - the weak ref would die and dock-click would silently no-op.
	// nonisolated(unsafe) because all reads/writes happen on the main thread
	// (NSView callbacks + the AppKit delegate methods are all @MainActor).
	nonisolated(unsafe) static var mainWindow: NSWindow?
	// keeps the global-shortcut setting subscription alive
	private var hotKeySubscription: AnyCancellable?
	// keeps the menu-bar-icon setting subscription alive
	private var menuBarSubscription: AnyCancellable?
	// the menu bar icon, nil while hidden
	private var statusItem: NSStatusItem?

	// called once when the application has finished launching
	func applicationDidFinishLaunching(_ inNotification: Notification) {
		// run as a regular foreground app even when launched outside a .app
		// bundle - covers the SwiftPM "swift run" case
		NSApp.setActivationPolicy(.regular)
		NSApp.activate(ignoringOtherApps: true)
		// shrink the AppKit help-tag (.help() / NSView.toolTip) hover delay
		// from the ~1-2 s system default. Registered as a default so a
		// user-set value in the global domain still wins. The value is in
		// milliseconds (it used to be registered as 0.3, read as 0 ms).
		UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 250])
		// wipe any elevated-access staging files left over from a previous
		// run so a crash or hard-kill doesn't accumulate privileged copies
		// in ~/Library/Caches across sessions
		ElevatedAccess.cleanup()
		// Finder > Services > "Search in Allofit"
		NSApp.servicesProvider = ServicesProvider()
		NSUpdateDynamicServices()
		// system-wide shortcut, re-registered whenever the setting changes
		GlobalHotKey.shared.onPressed = { WindowPresenter.toggle() }
		hotKeySubscription = Preferences.shared.$globalHotKey
			.removeDuplicates()
			.sink { vPreset in
				MainActor.assumeIsolated {
					_ = GlobalHotKey.shared.register(inPreset: vPreset)
				}
			}
		// menu bar icon (Everything's tray icon), shown per the setting.
		// Plain AppKit: a SwiftUI MenuBarExtra scene crashed the app at
		// launch (runtime recursion resolving the App's scene type).
		menuBarSubscription = Preferences.shared.$showMenuBarIcon
			.removeDuplicates()
			.sink { [weak self] vShow in
				MainActor.assumeIsolated {
					self?.setStatusItemVisible(vShow)
				}
			}
		// bring the main window to the front so it accepts keystrokes
		DispatchQueue.main.async {
			for vWindow in NSApp.windows where vWindow.canBecomeKey {
				vWindow.makeKeyAndOrderFront(nil)
				vWindow.orderFrontRegardless()
				break
			}
		}
	}

	// called on clean Cmd+Q quit; wipes the elevated-access staging dir
	// so the user-readable copies of privileged files don't linger
	func applicationWillTerminate(_ inNotification: Notification) {
		ElevatedAccess.cleanup()
	}

	// keep the process alive when the user closes the last window: the index
	// stays in RAM and clicking the dock icon snaps a new window up instantly.
	// Cmd+Q still quits via the standard Quit menu item.
	func applicationShouldTerminateAfterLastWindowClosed(_ inSender: NSApplication) -> Bool {
		return false
	}

	// dock-icon right-click contextual menu: surface a "New Window" entry so
	// the user can spawn an additional window without bringing the app to the
	// front first. The action defers to whatever the File > New Window menu
	// item does (SwiftUI auto-generates that item for WindowGroup) so we stay
	// compatible with whichever underlying selector SwiftUI uses.
	func applicationDockMenu(_ inSender: NSApplication) -> NSMenu? {
		let vMenu = NSMenu()
		let vItem = NSMenuItem(title: "New Window",
								action: #selector(newWindowFromDock(_:)),
								keyEquivalent: "")
		vItem.target = self
		vMenu.addItem(vItem)
		return vMenu
	}

	// finds the ⌘N main-menu item (File > New Window) and re-invokes its
	// action. We match on the keyboard shortcut rather than the title so the
	// lookup survives localized menus.
	@objc func newWindowFromDock(_ inSender: Any?) {
		MainActor.assumeIsolated {
			WindowPresenter.openNewWindow()
		}
	}

	// adds or removes the menu bar icon and its menu
	private func setStatusItemVisible(_ inVisible: Bool) {
		guard inVisible else {
			if let vItem = statusItem {
				NSStatusBar.system.removeStatusItem(vItem)
				statusItem = nil
			}
			return
		}
		guard statusItem == nil else { return }
		let vItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
		vItem.button?.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Allofit")
		let vMenu = NSMenu()
		vMenu.addItem(withTitle: "Show Allofit", action: #selector(statusShow(_:)), keyEquivalent: "").target = self
		vMenu.addItem(.separator())
		vMenu.addItem(withTitle: "Settings…", action: #selector(statusSettings(_:)), keyEquivalent: "").target = self
		vMenu.addItem(.separator())
		vMenu.addItem(withTitle: "Quit Allofit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
		vItem.menu = vMenu
		statusItem = vItem
	}

	// menu bar > Show Allofit
	@objc private func statusShow(_ inSender: Any?) {
		MainActor.assumeIsolated {
			WindowPresenter.show()
		}
	}

	// menu bar > Settings…
	@objc private func statusSettings(_ inSender: Any?) {
		NSApp.activate(ignoringOtherApps: true)
		NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
	}

	// folders dropped on the Dock icon or opened with the app
	// (open -a Allofit <folder>) start a search inside that folder
	func application(_ inApplication: NSApplication, open inUrls: [URL]) {
		guard let vFirst = inUrls.first else { return }
		let vIsDir = (try? vFirst.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
		WindowPresenter.search(inFolder: vIsDir ? vFirst.path : vFirst.deletingLastPathComponent().path)
	}

	// dock-icon click while no windows are visible: re-show only the main
	// window and return false so AppKit doesn't run its default "unhide every
	// hidden window" action (which would also resurrect the Settings window).
	func applicationShouldHandleReopen(_ inSender: NSApplication,
									   hasVisibleWindows inHasVisible: Bool) -> Bool {
		if inHasVisible { return true }
		if let vMain = AppDelegate.mainWindow {
			// hide any other hidden windows (e.g. Settings) so AppKit's
			// default behavior, if it triggers, doesn't bring them up
			for vOther in NSApp.windows where vOther !== vMain && vOther.isVisible {
				vOther.orderOut(nil)
			}
			vMain.makeKeyAndOrderFront(nil)
			NSApp.activate(ignoringOtherApps: true)
			return false
		}
		// no captured window (shouldn't happen) - let AppKit do its default;
		// SwiftUI will spawn a fresh WindowGroup window since the app is alive
		return true
	}
}
