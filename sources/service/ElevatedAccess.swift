import Foundation

// ElevatedAccess provides on-demand sudo-backed access to files the GUI
// user can't read directly. Common case: the root LaunchDaemon indexed
// `/Users/<otheruser>/...` (it has Full Disk Access), the GUI runs as
// the current user, and trying to render an inline preview hits a
// permission denial. The user clicks "Authorize" in the preview pane,
// AdminShell prompts for the password once, sudo copies the file to
// the per-user staging directory and chowns it to the GUI user.
//
// The staged copy is owned by the GUI user, lives in
//     ~/Library/Caches/Allofit/elevated/
// and is wiped at app launch and at app quit so privileged copies don't
// linger on disk across sessions.
enum ElevatedAccess {

	// per-user staging directory; lives under Library/Caches so macOS
	// itself may purge it under disk-pressure, and our own cleanup() at
	// launch + terminate keeps it from accumulating
	static var stagingDirectory: URL {
		let vCaches = FileManager.default.urls(
			for: .cachesDirectory,
			in: .userDomainMask
		).first!
		return vCaches.appendingPathComponent("Allofit/elevated", isDirectory: true)
	}

	// true if the current user can read the file at inPath without elevation
	static func canRead(path inPath: String) -> Bool {
		return FileManager.default.isReadableFile(atPath: inPath)
	}

	// wipes anything in the staging directory. Called on app launch (so a
	// previous session's elevated copies don't survive a relaunch) and on
	// app terminate (so they don't survive a clean quit either). Failure
	// is silent - if cleanup fails the next launch's cleanup will retry.
	static func cleanup() {
		try? FileManager.default.removeItem(at: stagingDirectory)
	}

	// copies inUrl into the staging directory via sudo, chowns it to the
	// current user, and returns the staged URL. Caller is responsible for
	// catching AdminShell.Error.scriptFailed (cancelled prompt etc).
	//
	// Throws if the parent staging directory can't be created or the
	// admin script fails. Side effect: the system prompts for password
	// the first time within the auth-cache window.
	static func stage(_ inUrl: URL) throws -> URL {
		let vDir = stagingDirectory
		// create as the current user so the dir is owned by us; sudo
		// only handles the file copy itself
		try FileManager.default.createDirectory(
			at: vDir,
			withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o700]
		)
		// creation attributes don't apply to an existing folder: enforce
		// owner-only access every time (the copies may be other users' files)
		chmod(vDir.path, 0o700)

		// unique destination file, keeping the original extension so the
		// QLPreviewView / Launch Services can pick the right renderer
		var vDst = vDir.appendingPathComponent(UUID().uuidString)
		let vExt = inUrl.pathExtension
		if !vExt.isEmpty {
			vDst.appendPathExtension(vExt)
		}

		// Root only *reads* the original; the copy is written by the user
		// (sudo -u ... tee), so root never creates, chowns or chmods a path
		// inside a user-writable folder. A cp + chown + chmod as root could
		// be redirected through a swapped-in symlink / hard link to take
		// ownership of any system file. pipefail makes a failed read fail
		// the script instead of leaving an empty copy behind.
		let vScript = """
		set -o pipefail; \
		/bin/cat \(AdminShell.quote(inUrl.path)) \
		| /usr/bin/sudo -u \(AdminShell.quote(NSUserName())) /usr/bin/tee \(AdminShell.quote(vDst.path)) > /dev/null
		"""
		_ = try AdminShell.run(vScript)
		return vDst
	}
}
