import AppKit

// Posted with a query string as object: the key window's search field
// replaces its text with it (see SearchField.Coordinator).
extension Notification.Name {
	static let allofitSetQuery = Notification.Name("AllofitSetQuery")
}

// WindowPresenter brings the main window up from anywhere: the global
// shortcut, the menu bar icon, the Dock, the Finder "Search in Allofit"
// service and folders opened with the app. It also carries a query to the
// window's search field.
@MainActor
enum WindowPresenter {

	// query waiting for a search field that doesn't exist yet (the window
	// is still being created); taken by the first field that appears
	static var pendingQuery: String?

	// shows and focuses the main window (creating one if needed) and puts
	// the keyboard focus in the search field
	static func show() {
		NSApp.activate(ignoringOtherApps: true)
		if let vMain = AppDelegate.mainWindow {
			if vMain.isMiniaturized { vMain.deminiaturize(nil) }
			vMain.makeKeyAndOrderFront(nil)
		} else if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
			openNewWindow()
		}
		// one tick later the window is key, so the focus request reaches it
		DispatchQueue.main.async {
			NotificationCenter.default.post(name: .allofitFocusSearch, object: nil)
		}
	}

	// global shortcut behavior (like Everything): hide Allofit when its
	// window is already in front, show it otherwise
	static func toggle() {
		if NSApp.isActive, let vKey = NSApp.keyWindow, vKey === AppDelegate.mainWindow, vKey.isVisible {
			NSApp.hide(nil)
		} else {
			show()
		}
	}

	// shows the main window searching inside a folder: the query is the
	// folder path with a trailing "/", which matches everything below it
	static func search(inFolder inPath: String) {
		let vFolder = VolumeManager.canonicalPath(inPath: inPath)
		let vTerm = vFolder.hasSuffix("/") ? vFolder : vFolder + "/"
		let vQuery = "\"\(vTerm)\" "
		pendingQuery = vQuery
		show()
		// an existing window takes it through the notification; a window
		// still being created takes pendingQuery when its field appears
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
			if pendingQuery != nil {
				NotificationCenter.default.post(name: .allofitSetQuery, object: vQuery)
			}
		}
	}

	// triggers File > New Window, found by its ⌘N shortcut so the lookup
	// survives localized menus
	static func openNewWindow() {
		guard let vMain = NSApp.mainMenu else { return }
		for vTop in vMain.items {
			guard let vSub = vTop.submenu else { continue }
			for vItem in vSub.items {
				if vItem.keyEquivalent == "n",
				   vItem.keyEquivalentModifierMask == [.command],
				   let vAction = vItem.action {
					NSApp.sendAction(vAction, to: vItem.target, from: nil)
					return
				}
			}
		}
	}
}

// ServicesProvider implements the "Search in Allofit" entry of Finder's
// Services / Quick Actions menu (declared under NSServices in Info.plist).
final class ServicesProvider: NSObject {

	// called by the system with the folders selected in Finder
	@objc func searchInAllofit(_ inPasteboard: NSPasteboard,
							   userData inUserData: String?,
							   error inError: AutoreleasingUnsafeMutablePointer<NSString>?) {
		let vUrls = inPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
		guard let vFirst = vUrls.first else {
			inError?.pointee = "No folder selected" as NSString
			return
		}
		// a file searches its folder
		let vIsDir = (try? vFirst.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
		let vFolder = vIsDir ? vFirst.path : vFirst.deletingLastPathComponent().path
		DispatchQueue.main.async {
			WindowPresenter.search(inFolder: vFolder)
		}
	}
}
