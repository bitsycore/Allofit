import AppKit
import Combine

// AppActivity tracks how visible Allofit currently is, so background work
// can slow down when nobody is looking:
//   - foreground: the app is frontmost and one of its windows is on screen
//   - background: a window is on screen but another app has focus
//   - hidden:     no window is on screen (closed, minimized, fully covered,
//                 or the app is hidden)
// Windows report their own visibility through WindowVisibilityReporter.
@MainActor
final class AppActivity: ObservableObject {

	// shared tracker for the whole app
	static let shared = AppActivity()

	// how visible the app is, from least to most
	enum Level: Int, Comparable {
		case hidden = 0
		case background = 1
		case foreground = 2

		// ordering by visibility
		static func < (inLhs: Level, inRhs: Level) -> Bool {
			return inLhs.rawValue < inRhs.rawValue
		}
	}

	// current visibility level
	@Published private(set) var level: Level = .foreground

	// windows (by reporter identity) currently on screen
	private var visibleWindows = Set<ObjectIdentifier>()
	// true while Allofit is the frontmost app
	private var isAppActive = true
	// app activation observers
	private var cancellables: Set<AnyCancellable> = []

	// starts following app activation / hiding
	private init() {
		isAppActive = NSApplication.shared.isActive
		let vCenter = NotificationCenter.default
		for vName in [NSApplication.didBecomeActiveNotification,
					  NSApplication.didResignActiveNotification,
					  NSApplication.didHideNotification,
					  NSApplication.didUnhideNotification] {
			vCenter.publisher(for: vName)
				.sink { [weak self] _ in
					MainActor.assumeIsolated {
						guard let vSelf = self else { return }
						vSelf.isAppActive = NSApplication.shared.isActive && !NSApplication.shared.isHidden
						vSelf.recompute()
					}
				}
				.store(in: &cancellables)
		}
	}

	// records whether the window identified by inId is on screen
	func setWindow(_ inId: ObjectIdentifier, visible inVisible: Bool) {
		if inVisible {
			visibleWindows.insert(inId)
		} else {
			visibleWindows.remove(inId)
		}
		recompute()
	}

	// derives the level from the window set and the app's active state
	private func recompute() {
		let vLevel: Level
		if visibleWindows.isEmpty || NSApplication.shared.isHidden {
			vLevel = .hidden
		} else if isAppActive {
			vLevel = .foreground
		} else {
			vLevel = .background
		}
		if level != vLevel {
			level = vLevel
		}
	}
}
