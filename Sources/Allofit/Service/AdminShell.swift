import Foundation
import AppKit

// AdminShell runs short shell commands with administrator privileges by
// wrapping them in `do shell script ... with administrator privileges`
// via NSAppleScript. The system shows its native password prompt the
// first time within a session; subsequent calls inside the auth-cache
// window (about 5 minutes) re-use the credential without re-prompting.
//
// Used by both ServiceInstaller (LaunchDaemon install/uninstall and
// cache-clear-and-restart) and ElevatedAccess (sudo cp of a single
// unreadable file into the per-user staging cache).
enum AdminShell {

	// surfaces an AppleScript failure - typically the user clicked
	// Cancel on the password prompt, or the embedded shell command
	// returned a non-zero exit code
	enum Error: Swift.Error, LocalizedError {
		case scriptFailed(String)
		var errorDescription: String? {
			switch self {
				case .scriptFailed(let vMsg): return vMsg
			}
		}
	}

	// runs inScript as root via NSAppleScript. Returns the script's
	// stdout. Throws Error.scriptFailed if NSAppleScript reports an
	// error (cancelled prompt, non-zero shell exit, etc).
	@discardableResult
	static func run(_ inScript: String) throws -> String {
		// AppleScript string literal needs backslashes and double quotes
		// escaped before we embed the shell command
		let vEscaped = inScript
			.replacingOccurrences(of: "\\", with: "\\\\")
			.replacingOccurrences(of: "\"", with: "\\\"")
		let vSource = "do shell script \"\(vEscaped)\" with administrator privileges"
		let vAppleScript = NSAppleScript(source: vSource)
		var vErr: NSDictionary?
		let vResult = vAppleScript?.executeAndReturnError(&vErr)
		guard let vDescriptor = vResult else {
			let vMessage = vErr?[NSAppleScript.errorMessage] as? String
				?? "Authorization cancelled or failed"
			throw Error.scriptFailed(vMessage)
		}
		return vDescriptor.stringValue ?? ""
	}

	// POSIX-style single-quote escape so a string can be safely embedded
	// inside the inScript argument of run(_:). Each embedded single
	// quote becomes the escape sequence '\''. Use for any user-supplied
	// path or argument; literal command names should not be quoted.
	static func quote(_ inString: String) -> String {
		return "'" + inString.replacingOccurrences(of: "'", with: "'\\''") + "'"
	}
}
