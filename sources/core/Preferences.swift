import Foundation
import SwiftUI

// Preferences wraps the user-configurable settings persisted to UserDefaults.
//
// Cross-process subtlety: when this code runs inside the root LaunchDaemon
// (uid 0) the standard UserDefaults points at /var/root/Library/Preferences,
// which is a different namespace from the GUI user's defaults. To make the
// daemon see the GUI's roots/exclusions, ServiceInstaller stashes the
// installing user's home directory in the ALLOFIT_OWNER_HOME env var on
// the launchd plist. We detect that here and load the GUI user's plist file
// directly (root has plain filesystem read access to ~/Library/Preferences,
// no TCC involvement).
// @unchecked Sendable because: writes flow through SwiftUI bindings (main
// actor), and the daemon only reads after init - there is no concurrent
// mutation. UserDefaults itself is thread-safe.
final class Preferences: ObservableObject, @unchecked Sendable {

	// shared singleton used by the GUI and the service runtime
	static let shared = Preferences()

	// the root directory paths to index
	@Published var rootPaths: [String] {
		didSet { UserDefaults.standard.set(rootPaths, forKey: Self.kRootPathsKey) }
	}
	// absolute paths to skip while indexing (descendants also skipped)
	@Published var excludedPaths: [String] {
		didSet { UserDefaults.standard.set(excludedPaths, forKey: Self.kExcludedPathsKey) }
	}
	// if true, also index external local volumes (USB, Thunderbolt, etc.)
	@Published var includeMountedVolumes: Bool {
		didSet { UserDefaults.standard.set(includeMountedVolumes, forKey: Self.kMountedKey) }
	}
	// if true, also index network volumes (SMB, AFP, NFS)
	@Published var includeNetworkVolumes: Bool {
		didSet { UserDefaults.standard.set(includeNetworkVolumes, forKey: Self.kNetworkKey) }
	}
	// background service installation mode
	@Published var serviceMode: ServiceMode {
		didSet { UserDefaults.standard.set(serviceMode.rawValue, forKey: Self.kServiceModeKey) }
	}
	// last sort descriptor used, restored on next launch
	@Published var lastSort: FileSortDescriptor {
		didSet { UserDefaults.standard.set(lastSort.rawValue, forKey: Self.kLastSortKey) }
	}

	// seconds file changes are collected before being applied to the index,
	// while Allofit is focused / another app is focused / no window shows
	@Published var updateDelayForeground: Double {
		didSet { UserDefaults.standard.set(updateDelayForeground, forKey: Self.kUpdateDelayForegroundKey) }
	}
	@Published var updateDelayBackground: Double {
		didSet { UserDefaults.standard.set(updateDelayBackground, forKey: Self.kUpdateDelayBackgroundKey) }
	}
	@Published var updateDelayHidden: Double {
		didSet { UserDefaults.standard.set(updateDelayHidden, forKey: Self.kUpdateDelayHiddenKey) }
	}
	// minimum seconds between two result refreshes caused by index changes,
	// while Allofit is focused / another app is focused
	@Published var refreshIntervalForeground: Double {
		didSet { UserDefaults.standard.set(refreshIntervalForeground, forKey: Self.kRefreshForegroundKey) }
	}
	@Published var refreshIntervalBackground: Double {
		didSet { UserDefaults.standard.set(refreshIntervalBackground, forKey: Self.kRefreshBackgroundKey) }
	}

	// default values of the update / refresh timings, in seconds
	static let kDefaultUpdateDelayForeground: Double = 2
	static let kDefaultUpdateDelayBackground: Double = 15
	static let kDefaultUpdateDelayHidden: Double = 60
	static let kDefaultRefreshForeground: Double = 1
	static let kDefaultRefreshBackground: Double = 5

	// puts every update / refresh timing back to its default
	func resetTimings() {
		updateDelayForeground = Self.kDefaultUpdateDelayForeground
		updateDelayBackground = Self.kDefaultUpdateDelayBackground
		updateDelayHidden = Self.kDefaultUpdateDelayHidden
		refreshIntervalForeground = Self.kDefaultRefreshForeground
		refreshIntervalBackground = Self.kDefaultRefreshBackground
	}

	// service installation modes
	enum ServiceMode: String, CaseIterable, Identifiable {
		case none        // no service: GUI indexes in its own process
		case userAgent   // LaunchAgent runs as the current user
		case rootDaemon  // LaunchDaemon runs as root and can scan everything
		var id: String { rawValue }
	}

	private static let kRootPathsKey = "Allofit.rootPaths"
	private static let kExcludedPathsKey = "Allofit.excludedPaths"
	private static let kMountedKey = "Allofit.includeMountedVolumes"
	private static let kNetworkKey = "Allofit.includeNetworkVolumes"
	private static let kServiceModeKey = "Allofit.serviceMode"
	private static let kLastSortKey = "Allofit.lastSort"
	private static let kUpdateDelayForegroundKey = "Allofit.updateDelayForeground"
	private static let kUpdateDelayBackgroundKey = "Allofit.updateDelayBackground"
	private static let kUpdateDelayHiddenKey = "Allofit.updateDelayHidden"
	private static let kRefreshForegroundKey = "Allofit.refreshIntervalForeground"
	private static let kRefreshBackgroundKey = "Allofit.refreshIntervalBackground"

	// flushes pending UserDefaults writes to disk so the daemon (which reads
	// the plist file directly) picks up the latest settings on next start
	static func flushToDisk() {
		UserDefaults.standard.synchronize()
	}

	// loads every setting, from the owner's plist when running as the root daemon
	private init() {
		// When we are the root daemon, the standard UserDefaults points at
		// /var/root/Library/Preferences/... which is *not* where the GUI user
		// stored their settings. Read the owner's plist file directly.
		let vSourceDict: [String: Any]? = Self.loadOwnerPlistIfDaemon()

		rootPaths = Self.readArray(forKey: Self.kRootPathsKey, from: vSourceDict)
			?? Self.defaultRootPaths()
		excludedPaths = Self.readArray(forKey: Self.kExcludedPathsKey, from: vSourceDict)
			?? Self.defaultExcludedPaths()
		includeMountedVolumes = Self.readBool(forKey: Self.kMountedKey, from: vSourceDict) ?? false
		includeNetworkVolumes = Self.readBool(forKey: Self.kNetworkKey, from: vSourceDict) ?? false
		if let vRaw = Self.readString(forKey: Self.kServiceModeKey, from: vSourceDict),
		   let vMode = ServiceMode(rawValue: vRaw) {
			serviceMode = vMode
		} else {
			serviceMode = .none
		}
		if let vRaw = Self.readString(forKey: Self.kLastSortKey, from: vSourceDict),
		   let vSort = FileSortDescriptor(rawValue: vRaw) {
			lastSort = vSort
		} else {
			lastSort = .nameAscending
		}
		updateDelayForeground = Self.readDouble(forKey: Self.kUpdateDelayForegroundKey, from: vSourceDict)
			?? Self.kDefaultUpdateDelayForeground
		updateDelayBackground = Self.readDouble(forKey: Self.kUpdateDelayBackgroundKey, from: vSourceDict)
			?? Self.kDefaultUpdateDelayBackground
		updateDelayHidden = Self.readDouble(forKey: Self.kUpdateDelayHiddenKey, from: vSourceDict)
			?? Self.kDefaultUpdateDelayHidden
		refreshIntervalForeground = Self.readDouble(forKey: Self.kRefreshForegroundKey, from: vSourceDict)
			?? Self.kDefaultRefreshForeground
		refreshIntervalBackground = Self.readDouble(forKey: Self.kRefreshBackgroundKey, from: vSourceDict)
			?? Self.kDefaultRefreshBackground
	}

	// ===========================
	// MARK: Source-of-truth helpers
	// ===========================

	// returns the owning user's preferences plist contents when running inside
	// the root daemon. nil otherwise, in which case callers fall through to
	// UserDefaults.standard.
	private static func loadOwnerPlistIfDaemon() -> [String: Any]? {
		let vEnv = ProcessInfo.processInfo.environment
		guard vEnv["ALLOFIT_SYSTEM_INDEX"] == "1",
			  let vOwnerHome = vEnv["ALLOFIT_OWNER_HOME"],
			  !vOwnerHome.isEmpty
		else { return nil }
		let vPath = "\(vOwnerHome)/Library/Preferences/com.bitsycore.allofit.plist"
		guard let vData = try? Data(contentsOf: URL(fileURLWithPath: vPath)),
			  let vDict = (try? PropertyListSerialization.propertyList(
				from: vData,
				format: nil
			  )) as? [String: Any]
		else {
			NSLog("[Allofit] root daemon could not read owner prefs at %@; using defaults", vPath)
			return [:]
		}
		return vDict
	}

	// reads an array from either the supplied plist dict or UserDefaults
	private static func readArray(forKey inKey: String, from inDict: [String: Any]?) -> [String]? {
		if let vDict = inDict { return vDict[inKey] as? [String] }
		return UserDefaults.standard.array(forKey: inKey) as? [String]
	}
	// reads a bool from either the supplied plist dict or UserDefaults
	private static func readBool(forKey inKey: String, from inDict: [String: Any]?) -> Bool? {
		if let vDict = inDict { return vDict[inKey] as? Bool }
		return UserDefaults.standard.object(forKey: inKey) as? Bool
	}
	// reads a number from either the supplied plist dict or UserDefaults
	private static func readDouble(forKey inKey: String, from inDict: [String: Any]?) -> Double? {
		if let vDict = inDict { return (vDict[inKey] as? NSNumber)?.doubleValue }
		return (UserDefaults.standard.object(forKey: inKey) as? NSNumber)?.doubleValue
	}
	// reads a string from either the supplied plist dict or UserDefaults
	private static func readString(forKey inKey: String, from inDict: [String: Any]?) -> String? {
		if let vDict = inDict { return vDict[inKey] as? String }
		return UserDefaults.standard.string(forKey: inKey)
	}

	// ===========================
	// MARK: Default sets
	// ===========================

	// defaults differ for the root daemon: a wide "/" root with system-path
	// exclusions makes the "scan everything" semantics meaningful even when
	// the owner's plist couldn't be read.
	private static func defaultRootPaths() -> [String] {
		if ProcessInfo.processInfo.environment["ALLOFIT_SYSTEM_INDEX"] == "1" {
			return ["/"]
		}
		return [FileManager.default.homeDirectoryForCurrentUser.path]
	}

	// default exclusions: system noise for the daemon, caches and trash for a user
	private static func defaultExcludedPaths() -> [String] {
		if ProcessInfo.processInfo.environment["ALLOFIT_SYSTEM_INDEX"] == "1" {
			return [
				"/System",
				"/private/var/folders",
				"/private/var/db",
				"/Library/Caches",
				"/.fseventsd",
				"/.Spotlight-V100",
				"/.DocumentRevisions-V100",
				"/.TemporaryItems",
				"/.Trashes"
			]
		}
		return [
			"~/Library/Caches",
			"~/Library/Containers",
			"~/.Trash",
			"/private/var/folders"
		].map { ($0 as NSString).expandingTildeInPath }
	}
}
