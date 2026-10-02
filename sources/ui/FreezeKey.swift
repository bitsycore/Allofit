import AppKit

// FreezeKey reports whether the "freeze" key (⌥ Option) is held down while
// Allofit is active. Holding it pauses the background refreshes of the
// results, so rows don't move while the user reads or selects them; typing,
// sorting and filtering still apply. Released (or the app deactivated), the
// lists catch up once.
@MainActor
final class FreezeKey: ObservableObject {

	// shared state for every window
	static let shared = FreezeKey()

	// true while ⌥ Option is held in Allofit
	@Published private(set) var isHeld = false

	// modifier-change monitor, alive for the app's lifetime
	private var monitor: Any?
	// app activation observers
	private var observers: [NSObjectProtocol] = []

	// starts following the modifier keys
	private init() {
		monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] vEvent in
			MainActor.assumeIsolated {
				self?.update(inFlags: vEvent.modifierFlags)
			}
			return vEvent
		}
		// a key released while another app was frontmost never reaches the
		// local monitor: re-read the state on (de)activation
		for vName in [NSApplication.didResignActiveNotification, NSApplication.didBecomeActiveNotification] {
			observers.append(NotificationCenter.default.addObserver(forName: vName, object: nil, queue: .main) { [weak self] vNote in
				MainActor.assumeIsolated {
					if vNote.name == NSApplication.didResignActiveNotification {
						self?.setHeld(false)
					} else {
						self?.update(inFlags: NSEvent.modifierFlags)
					}
				}
			})
		}
	}

	// held when Option is down on its own (shortcuts such as ⌥⌘C don't
	// freeze the list)
	private func update(inFlags: NSEvent.ModifierFlags) {
		let vMods = inFlags.intersection([.command, .option, .control, .shift])
		setHeld(vMods == [.option])
	}

	// publishes a change of state
	private func setHeld(_ inHeld: Bool) {
		if isHeld != inHeld {
			isHeld = inHeld
		}
	}
}
