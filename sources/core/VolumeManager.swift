import Foundation

// VolumeManager enumerates mounted volumes and derives the effective list of
// roots to index based on the user's preferences.
enum VolumeManager {

	// a mounted volume identified by URL plus user-friendly metadata
	struct Volume: Identifiable, Hashable {
		let id: String
		let url: URL
		let name: String
		let isLocal: Bool
		let isInternal: Bool
		// true when the volume is hosted on a remote file system
		var isNetwork: Bool { !isLocal }
	}

	// returns every mounted volume except the boot volume (covered by /Users)
	static func mountedVolumes() -> [Volume] {
		let vKeys: [URLResourceKey] = [
			.volumeNameKey,
			.volumeIsLocalKey,
			.volumeIsInternalKey,
			.volumeIsRootFileSystemKey,
			.volumeURLKey
		]
		guard let vUrls = FileManager.default.mountedVolumeURLs(
			includingResourceValuesForKeys: vKeys,
			options: []
		) else { return [] }

		var vResult: [Volume] = []
		for vUrl in vUrls {
			guard let vValues = try? vUrl.resourceValues(forKeys: Set(vKeys)) else { continue }
			if vValues.volumeIsRootFileSystem == true { continue }
			let vIsLocal = vValues.volumeIsLocal ?? false
			let vIsInternal = vValues.volumeIsInternal ?? false
			let vName = vValues.volumeName ?? vUrl.lastPathComponent
			vResult.append(Volume(
				id: vUrl.path,
				url: vUrl,
				name: vName,
				isLocal: vIsLocal,
				isInternal: vIsInternal
			))
		}
		return vResult.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
	}

	// returns the effective root URLs combining configured paths and mounted
	// volumes that match the include-mounted / include-network preferences.
	// Paths are canonicalized and nested roots dropped (a root inside another
	// root would otherwise be walked, watched and indexed twice).
	static func effectiveRoots(inPreferences: Preferences) -> [URL] {
		var vPaths: [String] = inPreferences.rootPaths.map { canonicalPath(inPath: $0) }
		if inPreferences.includeMountedVolumes || inPreferences.includeNetworkVolumes {
			for vVol in mountedVolumes() {
				if vVol.isNetwork && !inPreferences.includeNetworkVolumes { continue }
				if !vVol.isNetwork && !inPreferences.includeMountedVolumes { continue }
				vPaths.append(canonicalPath(inPath: vVol.url.path))
			}
		}
		let vMinimal = Set(SubtreeMatcher.minimalRoots(inPaths: vPaths))
		// keep the user's order, minus duplicates and nested entries
		var vSeen = Set<String>()
		return vPaths
			.filter { vMinimal.contains($0) && vSeen.insert($0).inserted }
			.map { URL(fileURLWithPath: $0) }
	}

	// true when inPath is a folder that can be read right now. Below
	// /Volumes/<name>, that volume must also be mounted: an unmounted share
	// can leave an empty folder with its name behind, which would look like
	// a share whose files were all deleted.
	static func isReachable(inPath: String) -> Bool {
		var vIsDir: ObjCBool = false
		guard FileManager.default.fileExists(atPath: inPath, isDirectory: &vIsDir), vIsDir.boolValue else {
			return false
		}
		let vParts = inPath.split(separator: "/", omittingEmptySubsequences: true)
		guard vParts.count >= 2, vParts[0] == "Volumes" else { return true }
		let vMountPoint = "/Volumes/" + vParts[1]
		var vStat = statfs()
		guard statfs(inPath, &vStat) == 0 else { return false }
		let vMountedOn = withUnsafeBytes(of: &vStat.f_mntonname) { vBytes in
			String(decoding: vBytes.prefix { $0 != 0 }, as: UTF8.self)
		}
		return RootGuard.isAtOrBelow(inPath: vMountedOn, inRoot: vMountPoint)
	}

	// the path the kernel reports for inPath (symlinks resolved, e.g.
	// /tmp -> /private/tmp), which is what FSEvents and the walker produce.
	// Foundation's standardizedFileURL / resolvingSymlinksInPath strip the
	// /private prefix instead, so a root under /tmp, /var or /etc would never
	// match its own entries. Falls back to the given path (minus a trailing
	// slash) when it doesn't exist, e.g. an unmounted volume.
	static func canonicalPath(inPath: String) -> String {
		if let vResolved = realpath(inPath, nil) {
			defer { free(vResolved) }
			return String(cString: vResolved)
		}
		return URL(fileURLWithPath: inPath).path
	}
}
