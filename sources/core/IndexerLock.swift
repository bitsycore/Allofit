import Foundation
import Darwin

// IndexerLock enforces single-writer access to the on-disk index using a
// POSIX advisory lock (fcntl F_SETLK) on a sentinel file. Whoever grabs the
// lock is the canonical indexer; competing processes (a second GUI, an old
// service that didn't exit cleanly) fall back to reader mode and just watch
// the cache file for updates.
//
// The lock is released automatically when the process exits or when unlock()
// closes the file descriptor. POSIX file locks have a known footgun: closing
// ANY descriptor on the file releases all locks held by this process. The
// class owns the fd exclusively and never re-opens it.
final class IndexerLock {

	// path of the lock sentinel file (one per cache location)
	let path: String
	// open descriptor, -1 when not locked
	private var fileDescriptor: Int32 = -1

	init(path: String) {
		self.path = path
	}

	deinit {
		unlock()
	}

	// attempts to acquire the lock without blocking
	// returns true on success, false if another process already holds it
	func tryLock() -> Bool {
		guard fileDescriptor < 0 else { return true }

		let vDir = (path as NSString).deletingLastPathComponent
		try? FileManager.default.createDirectory(
			atPath: vDir,
			withIntermediateDirectories: true
		)

		let vFd = open(path, O_CREAT | O_RDWR, 0o644)
		if vFd < 0 { return false }

		var vLock = flock(
			l_start: 0,
			l_len: 0,
			l_pid: 0,
			l_type: Int16(F_WRLCK),
			l_whence: Int16(SEEK_SET)
		)
		let vResult = withUnsafeMutablePointer(to: &vLock) { vPtr in
			fcntl(vFd, F_SETLK, vPtr)
		}
		if vResult < 0 {
			close(vFd)
			return false
		}

		// write pid for diagnostics (ftruncate first so the file stays small)
		_ = ftruncate(vFd, 0)
		let vPidString = "\(getpid())\n"
		vPidString.withCString { vCstr in
			_ = write(vFd, vCstr, strlen(vCstr))
		}
		fileDescriptor = vFd
		return true
	}

	// releases the lock (also runs at deinit)
	func unlock() {
		if fileDescriptor >= 0 {
			close(fileDescriptor)
			fileDescriptor = -1
		}
	}

	// reads the pid currently holding the lock, if any (best-effort)
	static func readHolderPid(path: String) -> Int32? {
		guard let vData = try? Data(contentsOf: URL(fileURLWithPath: path)),
			  let vStr = String(data: vData, encoding: .utf8),
			  let vPid = Int32(vStr.trimmingCharacters(in: .whitespacesAndNewlines))
		else { return nil }
		return vPid
	}
}
