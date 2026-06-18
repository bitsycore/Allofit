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
// to it via Combine and rebuild the visible slice on a debounced background
// task whenever any input changes.
@MainActor
final class WindowSearchModel: ObservableObject {

	// the user-entered search query; refilter is debounced via scheduleFilter
	@Published var query: String = "" {
		didSet { scheduleFilter() }
	}
	// the sort descriptor chosen by clicking a column header. Per-window:
	// clicking the Size header in window A no longer re-sorts window B.
	// Persisted to prefs (last-write-wins) so a fresh window opens with
	// the most recently chosen sort.
	@Published var sortDescriptor: FileSortDescriptor {
		didSet {
			Preferences.shared.lastSort = sortDescriptor
			scheduleFilter()
		}
	}
	// the filtered, sorted and capped records currently shown in the table
	@Published private(set) var visibleRecords: [FileRecord] = []

	// strong ref to the shared index; the per-window WindowSearchModel does
	// not outlive its window, so the shared model has a longer lifetime
	private let model: AppModel
	// Combine subscription to AppModel's @Published allRecords
	private var cancellables: Set<AnyCancellable> = []
	// pending filter+sort task, cancelled if a newer one supersedes it
	private var filterTask: Task<Void, Never>?

	// maximum rows handed to SwiftUI Table for snappy scrolling
	private let kMaxVisibleRows = 2000
	// debounce delay between keystroke / index update and filter rebuild
	private let kSearchDebounceSeconds: Double = 0.5

	init(model inModel: AppModel) {
		self.model = inModel
		self.sortDescriptor = Preferences.shared.lastSort
		// Re-filter when the shared index changes. @Published fires the
		// current value on subscribe; dropFirst skips that replay and we
		// run one explicit scheduleFilter() below so the initial debounce
		// delay applies consistently.
		inModel.$allRecords
			.dropFirst()
			.receive(on: DispatchQueue.main)
			.sink { [weak self] _ in
				self?.scheduleFilter()
			}
			.store(in: &cancellables)
		scheduleFilter()
	}

	// debounces filter rebuilds so we don't refilter on every keystroke
	// or every FSEvents batch mutation of AppModel.allRecords. The same
	// debounce window covers all input changes, which is what the old
	// single-model code did before this split.
	private func scheduleFilter() {
		filterTask?.cancel()
		// snapshot inputs on main; the detached task is self-contained
		let vQuery = query
		let vSort = sortDescriptor
		let vRecords = model.allRecords
		let vMax = kMaxVisibleRows
		let vDelayNanos = UInt64(kSearchDebounceSeconds * 1_000_000_000)
		filterTask = Task.detached(priority: .userInitiated) { [weak self] in
			try? await Task.sleep(nanoseconds: vDelayNanos)
			if Task.isCancelled { return }
			let vEngine = SearchEngine(inQuery: vQuery)
			var vFiltered: [FileRecord]
			if vEngine.isActive {
				vFiltered = vRecords.filter { vEngine.match(inRecord: $0) }
			} else {
				vFiltered = vRecords
			}
			if Task.isCancelled { return }
			AppModel.sortInPlace(inRecords: &vFiltered, inDescriptor: vSort)
			if Task.isCancelled { return }
			let vCapped: [FileRecord]
			if vFiltered.count > vMax {
				vCapped = Array(vFiltered.prefix(vMax))
			} else {
				vCapped = vFiltered
			}
			if Task.isCancelled { return }
			// hop back to main with DispatchQueue.main.async (rather than
			// await MainActor.run) so the assignment is guaranteed to land
			// on the next runloop tick, avoiding NSTableView reentrance when
			// the search field is mid-edit
			DispatchQueue.main.async {
				guard let vSelf = self else { return }
				// Skip the @Published fire when the resulting list is byte-
				// for-byte identical to what the Table is already showing.
				// Full FileRecord equality catches mtime / size updates, so
				// we only skip true no-op reassignments.
				if vSelf.visibleRecords == vCapped { return }
				vSelf.visibleRecords = vCapped
			}
		}
	}
}
