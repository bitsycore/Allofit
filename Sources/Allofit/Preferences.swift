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
final class Preferences: ObservableObject {

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
	// last search query, restored on next launch
	@Published var lastQuery: String {
		didSet { UserDefaults.standard.set(lastQuery, forKey: Self.kLastQueryKey) }
	}
	// last sort descriptor used, restored on next launch
	@Published var lastSort: FileSortDescriptor {
		didSet { UserDefaults.standard.set(lastSort.rawValue, forKey: Self.kLastSortKey) }
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
	private static let kLastQueryKey = "Allofit.lastQuery"
	private static let kLastSortKey = "Allofit.lastSort"

	// flushes pending UserDefaults writes to disk so the daemon (which reads
	// the plist file directly) picks up the latest settings on next start
	static func flushToDisk() {
		UserDefaults.standard.synchronize()
	}

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
		lastQuery = Self.readString(forKey: Self.kLastQueryKey, from: vSourceDict) ?? ""
		if let vRaw = Self.readString(forKey: Self.kLastSortKey, from: vSourceDict),
		   let vSort = FileSortDescriptor(rawValue: vRaw) {
			lastSort = vSort
		} else {
			lastSort = .nameAscending
		}
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
