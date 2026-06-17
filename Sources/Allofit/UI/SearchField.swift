import SwiftUI
import AppKit

// Posted by AllofitApp's "Find" menu command (⌘F). SearchField's Coordinator
// listens and re-grabs first responder, mimicking the standard Find shortcut.
extension Notification.Name {
	static let allofitFocusSearch = Notification.Name("AllofitFocusSearch")
}

// SearchField wraps AppKit's NSSearchField so we get native macOS behaviors
// the SwiftUI TextField cannot offer: a built-in recent-searches dropdown
// behind the magnifying glass, persistent history via recentsAutosaveName,
// and up/down arrow navigation through the history.
struct SearchField: NSViewRepresentable {

	// the current search text (two-way binding with the field)
	@Binding var text: String
	// placeholder shown when the field is empty
	var placeholder: String = ""
	// fired when the user presses Return inside the field
	var onSubmit: (() -> Void)? = nil
	// set true to grab keyboard focus when the field is first inserted
	var initiallyFirstResponder: Bool = false

	// builds and configures the underlying NSSearchField
	func makeNSView(context: Context) -> NSSearchField {
		let vField = NSSearchField()
		vField.placeholderString = placeholder
		vField.delegate = context.coordinator
		vField.target = context.coordinator
		vField.action = #selector(Coordinator.actionTriggered(_:))
		// keep filtering live as the user types
		vField.sendsSearchStringImmediately = false
		vField.sendsWholeSearchString = false
		// persist history in user defaults under our app namespace
		vField.recentsAutosaveName = "Allofit.recentSearches"
		vField.maximumRecents = 30
		vField.font = .systemFont(ofSize: NSFont.systemFontSize + 2)

		// recent-searches dropdown shown when the magnifying glass is clicked
		let vMenu = NSMenu()
		let vTitle = NSMenuItem(title: "Recent Searches", action: nil, keyEquivalent: "")
		vTitle.tag = 1000  // NSSearchFieldRecentsTitleMenuItemTag
		vMenu.addItem(vTitle)
		let vRecents = NSMenuItem(title: "Recents", action: nil, keyEquivalent: "")
		vRecents.tag = 1001  // NSSearchFieldRecentsMenuItemTag
		vMenu.addItem(vRecents)
		let vNoRecents = NSMenuItem(title: "No recent searches", action: nil, keyEquivalent: "")
		vNoRecents.tag = 1003  // NSSearchFieldNoRecentsMenuItemTag
		vMenu.addItem(vNoRecents)
		vMenu.addItem(NSMenuItem.separator())
		let vClear = NSMenuItem(title: "Clear Recent Searches", action: nil, keyEquivalent: "")
		vClear.tag = 1002  // NSSearchFieldClearRecentsMenuItemTag
		vMenu.addItem(vClear)
		vField.searchMenuTemplate = vMenu

		context.coordinator.field = vField

		if initiallyFirstResponder {
			DispatchQueue.main.async {
				vField.window?.makeFirstResponder(vField)
			}
		}
		return vField
	}

	// keeps the NSSearchField's stringValue in sync with our binding
	func updateNSView(_ nsView: NSSearchField, context: Context) {
		if nsView.stringValue != text {
			nsView.stringValue = text
		}
	}

	func makeCoordinator() -> Coordinator {
		return Coordinator(self)
	}

	// Coordinator bridges AppKit delegate callbacks to the SwiftUI binding,
	// adds submitted queries to the recents list, and implements arrow-key
	// navigation through the search history. @MainActor since AppKit invokes
	// every delegate method on main.
	@MainActor
	final class Coordinator: NSObject, NSSearchFieldDelegate {

		// strong reference back to the SearchField struct (rebound by updates)
		var parent: SearchField
		// weak link to the live NSSearchField for use by history navigation
		weak var field: NSSearchField?
		// index in recentSearches of the entry currently shown by arrow nav
		private var navigationIndex: Int?
		// text the user typed before starting to navigate; restored on rollback
		private var savedQuery: String = ""
		// debounced auto-save to recents: if the user stops typing for this
		// many nanoseconds, the current query is added to recents as though
		// they had pressed Return
		private static let kAutoSaveDelayNanos: UInt64 = 4_000_000_000
		// pending auto-save task; cancelled+rescheduled on every keystroke
		private var autoSaveTask: Task<Void, Never>?

		init(_ inParent: SearchField) {
			parent = inParent
			super.init()
			// listen for the global ⌘F notification so menu Find re-focuses
			// the search field even when it isn't first responder
			NotificationCenter.default.addObserver(
				self,
				selector: #selector(handleFocusRequest),
				name: .allofitFocusSearch,
				object: nil
			)
		}

		deinit {
			NotificationCenter.default.removeObserver(self)
		}

		// fired by the Find menu item; brings the search field to first
		// responder and selects existing text so typing replaces it.
		// With multi-window, every Coordinator gets the notification - so
		// we only act when our field belongs to the currently key window;
		// otherwise inactive windows would all race to steal focus.
		@objc private func handleFocusRequest() {
			guard let vField = field, vField.window?.isKeyWindow == true else { return }
			vField.window?.makeFirstResponder(vField)
			vField.selectText(nil)
		}

		// fired on every keystroke; reset navigation and push text to SwiftUI
		func controlTextDidChange(_ notification: Notification) {
			guard let vField = notification.object as? NSSearchField else { return }
			navigationIndex = nil
			let vValue = vField.stringValue
			if parent.text != vValue {
				// defer the binding write so SwiftUI does not re-render the
				// Table while AppKit is still in the NSSearchField delegate
				DispatchQueue.main.async { [weak self] in
					self?.parent.text = vValue
				}
			}
			scheduleAutoSave(field: vField)
		}

		// reschedules the deferred "treat the current query as submitted"
		// task. Called on every keystroke; if the user stops typing for the
		// configured dwell time, the query lands in recents without Enter.
		private func scheduleAutoSave(field inField: NSSearchField) {
			autoSaveTask?.cancel()
			let vQuery = inField.stringValue.trimmingCharacters(in: .whitespaces)
			guard !vQuery.isEmpty else { return }
			autoSaveTask = Task { [weak self, weak inField] in
				try? await Task.sleep(nanoseconds: Coordinator.kAutoSaveDelayNanos)
				if Task.isCancelled { return }
				await MainActor.run {
					guard let vField = inField else { return }
					// the user may have edited or cleared the field while we
					// slept; only commit if the snapshot still matches
					let vNow = vField.stringValue.trimmingCharacters(in: .whitespaces)
					guard vNow == vQuery else { return }
					self?.addCurrentToRecents(field: vField)
				}
			}
		}

		// NSSearchField's action target: fires on Return and on recent-pick
		@objc func actionTriggered(_ sender: NSSearchField) {
			if parent.text != sender.stringValue {
				parent.text = sender.stringValue
			}
			parent.onSubmit?()
		}

		// intercept arrow-keys and Return for history nav and recents-update
		func control(_ control: NSControl,
					 textView: NSTextView,
					 doCommandBy commandSelector: Selector) -> Bool {
			guard let vField = control as? NSSearchField else { return false }
			if commandSelector == #selector(NSResponder.moveUp(_:)) {
				navigateHistory(field: vField, inOlder: true)
				return true
			}
			if commandSelector == #selector(NSResponder.moveDown(_:)) {
				navigateHistory(field: vField, inOlder: false)
				return true
			}
			if commandSelector == #selector(NSControl.insertNewline(_:)) {
				addCurrentToRecents(field: vField)
				return false
			}
			return false
		}

		// adds the current text to the recents list (deduped, newest-first)
		private func addCurrentToRecents(field: NSSearchField) {
			let vQuery = field.stringValue.trimmingCharacters(in: .whitespaces)
			guard !vQuery.isEmpty else { return }
			var vRecents = field.recentSearches
			vRecents.removeAll { $0 == vQuery }
			vRecents.insert(vQuery, at: 0)
			if vRecents.count > 30 { vRecents = Array(vRecents.prefix(30)) }
			field.recentSearches = vRecents
			navigationIndex = nil
		}

		// walks one step through the recent-searches list
		private func navigateHistory(field: NSSearchField, inOlder: Bool) {
			let vHistory = field.recentSearches
			if vHistory.isEmpty { return }

			if inOlder {
				if navigationIndex == nil {
					savedQuery = field.stringValue
					navigationIndex = 0
				} else if let vI = navigationIndex, vI + 1 < vHistory.count {
					navigationIndex = vI + 1
				}
			} else {
				if let vI = navigationIndex {
					if vI > 0 {
						navigationIndex = vI - 1
					} else {
						navigationIndex = nil
						field.stringValue = savedQuery
						parent.text = savedQuery
						return
					}
				} else {
					return
				}
			}

			if let vIdx = navigationIndex, vIdx < vHistory.count {
				let vValue = vHistory[vIdx]
				field.stringValue = vValue
				parent.text = vValue
			}
		}
	}
}
