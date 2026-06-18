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
	// volumes that match the include-mounted / include-network preferences
	static func effectiveRoots(inPreferences: Preferences) -> [URL] {
		var vRoots: [URL] = inPreferences.rootPaths.map { URL(fileURLWithPath: $0) }
		if inPreferences.includeMountedVolumes || inPreferences.includeNetworkVolumes {
			for vVol in mountedVolumes() {
				if vVol.isNetwork && !inPreferences.includeNetworkVolumes { continue }
				if !vVol.isNetwork && !inPreferences.includeMountedVolumes { continue }
				vRoots.append(vVol.url)
			}
		}
		return vRoots
	}
}
