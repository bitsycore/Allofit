import Foundation
import SwiftUI
import Combine

// WindowSearchModel owns the per-window slice of the search/index pipeline:
// the query the user types, the sort descriptor chosen by clicking a column
// header in THIS window, and the filtered+sorted+capped slice of
// AppModel.allRecords currently shown here. Each new window gets its own
// instance so two windows can run independent searches and independent
// sorts against the same shared index.
//
// AppModel remains the single source of truth for allRecords. We subscribe
// to its recordsChanged signal and rebuild the visible slice on a debounced
// background task whenever any input changes.
@MainActor
final class WindowSearchModel: ObservableObject {

	// the user-entered search query; refilter is debounced via scheduleFilter
	@Published var query: String = "" {
		didSet { scheduleFilter(inDelay: kTypingDebounceSeconds) }
	}
	// the sort descriptor chosen by clicking a column header. Per-window:
	// clicking the Size header in window A no longer re-sorts window B.
	// Persisted to prefs (last-write-wins) so a fresh window opens with
	// the most recently chosen sort.
	@Published var sortDescriptor: FileSortDescriptor {
		didSet {
			Preferences.shared.lastSort = sortDescriptor
			scheduleFilter(inDelay: kTypingDebounceSeconds)
		}
	}
	// the category filter chosen in the menu next to the search field
	@Published var filter: SearchFilter = .everything {
		didSet { scheduleFilter(inDelay: kTypingDebounceSeconds) }
	}
	// every record matching the query, sorted (the table shows them all;
	// only the rows on screen get views)
	@Published private(set) var results = ResultList()
	// bumped on every change of results, so the table can tell a new list
	// from the same one without comparing hundreds of thousands of records
	@Published private(set) var resultsVersion = 0
	// what to emphasize in the shown results (always matches results)
	@Published private(set) var highlights = SearchEngine.Highlights()
	// match count and timing for the status bar (observed separately so
	// their updates don't re-render the table)
	let stats = SearchStats()

	// strong ref to the shared index; the per-window WindowSearchModel does
	// not outlive its window, so the shared model has a longer lifetime
	private let model: AppModel
	// Combine subscription to AppModel's recordsChanged signal
	private var cancellables: Set<AnyCancellable> = []
	// pending filter+sort task, cancelled if a newer one supersedes it
	private var filterTask: Task<Void, Never>?

	// rows published first when a query matches more than this: the top of
	// the list appears in milliseconds, the complete sort follows (a full
	// sort of 600k entries takes ~0.2 s)
	private nonisolated static let kQuickRows = 2000
	// above this many results, skip the "same list" comparison (it would
	// cost more than just reloading the visible rows)
	private nonisolated static let kCompareLimit = 5000
	// delay after a keystroke / sort click: just enough to merge key repeats
	private let kTypingDebounceSeconds: Double = 0.04
	// delay after an index change: merges bursts of FSEvents updates
	private let kIndexDebounceSeconds: Double = 0.3
	// true while this model's window is on screen (not closed, minimized
	// or fully covered)
	private var isWindowVisible = true
	// true when the index changed while the window was not visible
	private var isStale = false
	// true while a throttled index refilter is waiting to run
	private var isIndexRefreshScheduled = false
	// when the last index-driven refilter started
	private var lastIndexRefreshAt = Date.distantPast

	// subscribes to index changes and runs the first filter
	init(model inModel: AppModel) {
		self.model = inModel
		self.sortDescriptor = Preferences.shared.lastSort
		// Re-filter when the shared index changes. The signal carries no
		// payload (the array itself is read when the filter runs), so a
		// burst of updates never queues up copies of the index.
		inModel.recordsChanged
			.sink { [weak self] in
				self?.indexDidChange()
			}
			.store(in: &cancellables)
		scheduleFilter(inDelay: 0)
	}

	// reported by the window: refilters on reappearance if the index
	// changed while the window was off screen
	func setWindowVisible(_ inVisible: Bool) {
		isWindowVisible = inVisible
		if inVisible && isStale {
			isStale = false
			scheduleFilter(inDelay: 0)
		}
	}

	// drops rows right away (e.g. after Move to Trash); the index catches up
	// through FSEvents a moment later
	func removeVisible(inIds: Set<FileRecord.ID>) {
		results = results.removing(inIds: inIds)
		resultsVersion &+= 1
		stats.matchCount = results.count
	}

	// publishes a result list (and its count / highlights) on main
	private func publish(inResults: ResultList,
						 inCount: Int,
						 inHighlights: SearchEngine.Highlights,
						 inMilliseconds: Double?) {
		if stats.matchCount != inCount { stats.matchCount = inCount }
		if let vMs = inMilliseconds { stats.lastSearchMilliseconds = vMs }
		if highlights != inHighlights { highlights = inHighlights }
		// skip a no-op reassignment of a small identical list (full record
		// equality also catches size / date updates)
		if inResults.count <= Self.kCompareLimit && results.count == inResults.count && results.elementsEqual(inResults) {
			return
		}
		results = inResults
		resultsVersion &+= 1
	}

	// throttled reaction to an index change: nothing while off screen,
	// otherwise at most one refilter per refresh interval. The
	// refilter reads the newest records when it runs, so skipped
	// notifications lose nothing.
	private func indexDidChange() {
		guard isWindowVisible else {
			isStale = true
			return
		}
		if isIndexRefreshScheduled { return }
		isIndexRefreshScheduled = true
		let vSinceLast = Date().timeIntervalSince(lastIndexRefreshAt)
		// minimum gap between two index-driven refilters (Settings >
		// Performance). Typing is unaffected; this caps the cost of an
		// expensive query left open while files change constantly.
		let vPrefs = Preferences.shared
		let vInterval = AppActivity.shared.level == .foreground
			? vPrefs.refreshIntervalForeground
			: vPrefs.refreshIntervalBackground
		let vWait = max(kIndexDebounceSeconds, vInterval - vSinceLast)
		DispatchQueue.main.asyncAfter(deadline: .now() + vWait) { [weak self] in
			guard let vSelf = self else { return }
			vSelf.isIndexRefreshScheduled = false
			guard vSelf.isWindowVisible else {
				vSelf.isStale = true
				return
			}
			vSelf.lastIndexRefreshAt = Date()
			// no quick partial list here: it would briefly cut the list to
			// its first rows and lose the scroll position of a user
			// browsing further down
			vSelf.scheduleFilter(inDelay: 0, inProgressive: false)
		}
	}

	// debounces filter rebuilds so we don't refilter on every keystroke
	// or every FSEvents batch. The latest call wins: earlier pending
	// tasks are cancelled before they start (or between chunks).
	// inProgressive publishes the first rows before the complete sort
	// when there are many results (typing, sort and filter changes).
	private func scheduleFilter(inDelay: Double, inProgressive: Bool = true) {
		filterTask?.cancel()
		// snapshot inputs on main; the detached task is self-contained
		let vQuery = filter.apply(toQuery: query)
		let vHighlights = SearchEngine(inQuery: query).highlights
		let vSort = sortDescriptor
		let vRecords = model.allRecords
		let vDelayNanos = UInt64(inDelay * 1_000_000_000)
		filterTask = Task.detached(priority: .userInitiated) { [weak self] in
			if vDelayNanos > 0 {
				try? await Task.sleep(nanoseconds: vDelayNanos)
			}
			if Task.isCancelled { return }
			let vStartedAt = DispatchTime.now()
			let vEngine = SearchEngine(inQuery: vQuery)
			// the chunks run on GCD worker threads, which can't see this
			// task's cancellation - relay it through a shared flag
			let vCancelled = ManagedAtomicFlag()
			let vResult = await withTaskCancellationHandler {
				WindowSearchModel.matchingPositions(
					inRecords: vRecords,
					inEngine: vEngine,
					inCancelled: vCancelled
				)
			} onCancel: {
				vCancelled.set()
			}
			guard let vPositions = vResult else { return }
			if Task.isCancelled { return }
			let vCount = vPositions.count
			// timing covers the filter plus the first displayable sort
			var vMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - vStartedAt.uptimeNanoseconds) / 1_000_000
			if inProgressive && vCount > WindowSearchModel.kQuickRows {
				let vTop = ResultList(inStore: vRecords, inPositions: ResultSorter.topPositions(
					inRecords: vRecords,
					inPositions: vPositions,
					inLimit: WindowSearchModel.kQuickRows,
					inDescriptor: vSort
				))
				if Task.isCancelled { return }
				vMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - vStartedAt.uptimeNanoseconds) / 1_000_000
				let vQuickMs = vMilliseconds
				// hop back to main with DispatchQueue.main.async (rather than
				// await MainActor.run) so the assignment lands on the next
				// runloop tick, avoiding NSTableView reentrance when the
				// search field is mid-edit
				DispatchQueue.main.async {
					self?.publish(inResults: vTop, inCount: vCount, inHighlights: vHighlights, inMilliseconds: vQuickMs)
				}
			}
			let vAll = ResultList(inStore: vRecords, inPositions: ResultSorter.topPositions(
				inRecords: vRecords,
				inPositions: vPositions,
				inLimit: vCount,
				inDescriptor: vSort
			))
			if Task.isCancelled { return }
			let vFinalMs: Double? = (inProgressive && vCount > WindowSearchModel.kQuickRows)
				? nil
				: Double(DispatchTime.now().uptimeNanoseconds - vStartedAt.uptimeNanoseconds) / 1_000_000
			DispatchQueue.main.async {
				self?.publish(inResults: vAll, inCount: vCount, inHighlights: vHighlights, inMilliseconds: vFinalMs)
			}
		}
	}

	// positions of the records matching the engine, computed in parallel
	// chunks. Returns nil if the task was cancelled midway.
	private nonisolated static func matchingPositions(inRecords: RecordStore,
													  inEngine: SearchEngine,
													  inCancelled: ManagedAtomicFlag) -> [Int32]? {
		if !inEngine.isActive {
			return (0..<Int32(inRecords.count)).map { $0 }
		}
		// one parallel job per store chunk, reading its records directly
		let vChunkCount = inRecords.chunkCount
		if vChunkCount == 0 { return [] }
		var vChunks = [[Int32]](repeating: [], count: vChunkCount)
		vChunks.withUnsafeMutableBufferPointer { vOut in
			// each chunk writes only its own slot, so sharing is safe
			nonisolated(unsafe) let vOutBase = vOut.baseAddress!
			DispatchQueue.concurrentPerform(iterations: vChunkCount) { vChunk in
				if inCancelled.isSet { return }
				let vRecords = inRecords.chunk(at: vChunk)
				let vBase = Int32(vChunk << RecordStore.kShift)
				var vLocal: [Int32] = []
				for (vI, vRecord) in vRecords.enumerated() where inEngine.match(inRecord: vRecord) {
					vLocal.append(vBase + Int32(vI))
				}
				(vOutBase + vChunk).pointee = vLocal
			}
		}
		if inCancelled.isSet { return nil }
		return Array(vChunks.joined())
	}
}

// Minimal thread-safe boolean used to stop parallel filter chunks early.
private final class ManagedAtomicFlag: @unchecked Sendable {
	// current value
	private var value = false
	// guards value
	private let lock = NSLock()

	// true once set() has been called
	var isSet: Bool {
		lock.lock()
		defer { lock.unlock() }
		return value
	}

	// raises the flag
	func set() {
		lock.lock()
		value = true
		lock.unlock()
	}
}
