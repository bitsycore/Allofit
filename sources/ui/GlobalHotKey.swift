import AppKit
import Carbon.HIToolbox

// HotKeyPreset lists the global shortcuts offered in Settings. A short list
// of presets avoids a recorder UI and only offers combinations that don't
// clash with standard macOS shortcuts (⌘Space is Spotlight).
enum HotKeyPreset: String, CaseIterable, Identifiable {
	case none
	case optionSpace
	case controlSpace
	case controlOptionSpace
	case optionCommandSpace
	case shiftCommandSpace

	var id: String { rawValue }

	// menu label, e.g. "⌥ Space"
	var title: String {
		switch self {
			case .none: return "None"
			case .optionSpace: return "⌥ Space"
			case .controlSpace: return "⌃ Space"
			case .controlOptionSpace: return "⌃⌥ Space"
			case .optionCommandSpace: return "⌥⌘ Space"
			case .shiftCommandSpace: return "⇧⌘ Space"
		}
	}

	// Carbon modifier mask for RegisterEventHotKey (nil for none)
	var carbonModifiers: UInt32? {
		switch self {
			case .none: return nil
			case .optionSpace: return UInt32(optionKey)
			case .controlSpace: return UInt32(controlKey)
			case .controlOptionSpace: return UInt32(controlKey | optionKey)
			case .optionCommandSpace: return UInt32(optionKey | cmdKey)
			case .shiftCommandSpace: return UInt32(shiftKey | cmdKey)
		}
	}
}

// GlobalHotKey registers one system-wide shortcut through Carbon's
// RegisterEventHotKey, which needs no Accessibility permission (unlike an
// NSEvent global monitor) and swallows the key press for us.
@MainActor
final class GlobalHotKey: ObservableObject {

	// shared registration for the app
	static let shared = GlobalHotKey()

	// false when the chosen shortcut is already taken by another app
	@Published private(set) var isAvailable = true

	// called on main when the shortcut is pressed
	var onPressed: (() -> Void)?
	// the active registration, nil when none
	private var hotKeyRef: EventHotKeyRef?
	// the Carbon event handler, installed once
	private var handlerRef: EventHandlerRef?

	// four-char signature identifying our hot key ("ALFT")
	private let kSignature: OSType = 0x414C_4654

	// registers inPreset (replacing any previous one). Returns false when
	// the combination is already taken by another app.
	@discardableResult
	func register(inPreset: HotKeyPreset) -> Bool {
		unregister()
		guard let vModifiers = inPreset.carbonModifiers else {
			isAvailable = true
			return true
		}
		installHandlerIfNeeded()
		var vRef: EventHotKeyRef?
		let vId = EventHotKeyID(signature: kSignature, id: 1)
		let vStatus = RegisterEventHotKey(
			UInt32(kVK_Space),
			vModifiers,
			vId,
			GetApplicationEventTarget(),
			0,
			&vRef
		)
		guard vStatus == noErr, let vRegistered = vRef else {
			NSLog("[Allofit GUI] global shortcut %@ unavailable (status %d)", inPreset.title, vStatus)
			isAvailable = false
			return false
		}
		hotKeyRef = vRegistered
		isAvailable = true
		return true
	}

	// removes the current registration, if any
	func unregister() {
		if let vRef = hotKeyRef {
			UnregisterEventHotKey(vRef)
			hotKeyRef = nil
		}
	}

	// installs the application-level handler that receives hot key events
	private func installHandlerIfNeeded() {
		guard handlerRef == nil else { return }
		var vType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
		let vHandler: EventHandlerUPP = { _, _, _ in
			DispatchQueue.main.async {
				MainActor.assumeIsolated {
					GlobalHotKey.shared.onPressed?()
				}
			}
			return noErr
		}
		InstallEventHandler(GetApplicationEventTarget(), vHandler, 1, &vType, nil, &handlerRef)
	}
}
