import Foundation
import CoreServices

// FSChange describes a single path reported by FSEvents along with its flag
// bits. The flags tell us whether the kernel coalesced events past its
// history limit, in which case we must rescan the affected subdirectory.
struct FSChange {

	// absolute path that changed
	let path: String
	// raw FSEvents flag bits for this change
	let flags: FSEventStreamEventFlags

	// true when the kernel asks the client to rescan inside this path
	// because events were dropped (history too old or buffer overflow)
	var mustScanSubDirs: Bool {
		return flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
	}
	// true when this event references a directory
	var isDir: Bool {
		return flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
	}
}

// FileWatcher streams real-time filesystem change notifications using FSEvents.
// FSEvents is the macOS analogue of the NTFS USN journal: the kernel records
// every change and we receive coalesced notifications batched by latency.
//
// The watcher can be started from a specific event id, which lets us "replay"
// every change that occurred while the app was closed - the same fast-resume
// trick Everything uses on Windows.
final class FileWatcher {

	// callback signature receiving an array of change descriptors
	typealias ChangeHandler = ([FSChange]) -> Void

	// the active FSEvents stream, nil when stopped
	private var stream: FSEventStreamRef?
	// the user-provided change handler, invoked from the FSEvents callback
	private var handler: ChangeHandler?
	// guards stream/handler against concurrent access
	private let lock = NSLock()

	deinit {
		stop()
	}

	// returns the latest event id observed by the running stream (or 0)
	var latestEventId: UInt64 {
		lock.lock()
		defer { lock.unlock() }
		guard let vStream = stream else { return 0 }
		return UInt64(FSEventStreamGetLatestEventId(vStream))
	}

	// starts watching inRoots, delivering batches of changes to inHandler
	// starting from inSinceWhen (defaults to "now")
	func start(inRoots: [String],
			   inSinceWhen: FSEventStreamEventId = FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
			   inHandler: @escaping ChangeHandler) {
		stop()
		lock.lock()
		handler = inHandler
		lock.unlock()

		var vContext = FSEventStreamContext(
			version: 0,
			info: Unmanaged.passUnretained(self).toOpaque(),
			retain: nil,
			release: nil,
			copyDescription: nil
		)

		// C callback: forwards paths + flags back to the Swift handler
		let vCallback: FSEventStreamCallback = { (_, info, numEvents, eventPaths, eventFlags, _) in
			guard let vInfo = info else { return }
			let vWatcher = Unmanaged<FileWatcher>.fromOpaque(vInfo).takeUnretainedValue()
			let vPathsArray = unsafeBitCast(eventPaths, to: NSArray.self)
			var vChanges: [FSChange] = []
			vChanges.reserveCapacity(numEvents)
			for vI in 0..<numEvents {
				guard let vPath = vPathsArray[vI] as? String else { continue }
				vChanges.append(FSChange(path: vPath, flags: eventFlags[vI]))
			}
			vWatcher.lock.lock()
			let vHandler = vWatcher.handler
			vWatcher.lock.unlock()
			vHandler?(vChanges)
		}

		// kFSEventStreamCreateFlagIgnoreSelf filters out events caused by
		// this same process - keeps the indexer's own cache writes from
		// showing up in its event stream as phantom file activity.
		let vFlags = FSEventStreamCreateFlags(
			kFSEventStreamCreateFlagFileEvents |
			kFSEventStreamCreateFlagNoDefer |
			kFSEventStreamCreateFlagUseCFTypes |
			kFSEventStreamCreateFlagIgnoreSelf
		)

		guard let vStream = FSEventStreamCreate(
			nil,
			vCallback,
			&vContext,
			inRoots as CFArray,
			inSinceWhen,
			0.2,
			vFlags
		) else { return }

		FSEventStreamSetDispatchQueue(vStream, DispatchQueue.global(qos: .utility))
		FSEventStreamStart(vStream)
		lock.lock()
		stream = vStream
		lock.unlock()
	}

	// stops the watcher and releases the underlying stream
	func stop() {
		lock.lock()
		let vStream = stream
		stream = nil
		handler = nil
		lock.unlock()
		if let vRealStream = vStream {
			FSEventStreamStop(vRealStream)
			FSEventStreamInvalidate(vRealStream)
			FSEventStreamRelease(vRealStream)
		}
	}
}
