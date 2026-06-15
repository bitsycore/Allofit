import SwiftUI
import AppKit

// AllofitApp is the SwiftUI App for the GUI mode. The real entry point lives
// in Main.swift, which routes between this and the headless --service mode.
struct AllofitApp: App {

	// AppKit delegate that wrestles focus from whichever app was frontmost,
	// needed because SwiftPM-launched binaries default to .accessory policy
	@NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
	// shared application state injected into the view tree
	@StateObject private var model = AppModel()
	// session-scoped store of sudo-staged user-readable copies. Sits
	// alongside AppModel so both the Table (lock badge on rows) and
	// the PreviewPane observe the same authorization state.
	@StateObject private var access = AccessManager()

	var body: some Scene {
		WindowGroup("Allofit") {
			ContentView()
				.environmentObject(model)
				.environmentObject(Preferences.shared)
				.environmentObject(access)
				.frame(minWidth: 760, minHeight: 480)
				.background(MainWindowMarker())
		}
		.windowToolbarStyle(.unified)
		.defaultSize(width: 1100, height: 640)
		.commands {
			// custom About panel with a clickable repo link in the credits
			CommandGroup(replacing: .appInfo) {
				Button("About Allofit") { showAboutPanel() }
			}
			CommandGroup(after: .appInfo) {
				Button("Reindex All") {
					Task { await model.performReindex() }
				}
				.keyboardShortcut("r", modifiers: [.command])
			}
			CommandGroup(replacing: .newItem) { }
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

	final class MarkerView: NSView {
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

	func makeNSView(context: Context) -> NSView {
		return MarkerView(frame: .zero)
	}

	func updateNSView(_ nsView: NSView, context: Context) {
		// rebind if SwiftUI ever swaps us into a different window
		if let vWindow = nsView.window, AppDelegate.mainWindow !== vWindow {
			vWindow.isReleasedWhenClosed = false
			AppDelegate.mainWindow = vWindow
		}
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

	// called once when the application has finished launching
	func applicationDidFinishLaunching(_ notification: Notification) {
		// run as a regular foreground app even when launched outside a .app
		// bundle - covers the SwiftPM "swift run" case
		NSApp.setActivationPolicy(.regular)
		NSApp.activate(ignoringOtherApps: true)
		// wipe any elevated-access staging files left over from a previous
		// run so a crash or hard-kill doesn't accumulate privileged copies
		// in ~/Library/Caches across sessions
		ElevatedAccess.cleanup()
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
	func applicationWillTerminate(_ notification: Notification) {
		ElevatedAccess.cleanup()
	}

	// keep the process alive when the user closes the last window: the index
	// stays in RAM and clicking the dock icon snaps a new window up instantly.
	// Cmd+Q still quits via the standard Quit menu item.
	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		return false
	}

	// dock-icon click while no windows are visible: re-show only the main
	// window and return false so AppKit doesn't run its default "unhide every
	// hidden window" action (which would also resurrect the Settings window).
	func applicationShouldHandleReopen(_ sender: NSApplication,
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
