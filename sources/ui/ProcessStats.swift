import Foundation
import Combine
import Darwin

// ProcessStats samples this process's resource usage for the status bar:
// memory footprint (the figure Activity Monitor shows), its peak, and CPU
// use. One shared instance ticks every kSampleSeconds; only the status bar
// observes it, so a tick never re-renders the results table.
@MainActor
final class ProcessStats: ObservableObject {

	// shared sampler used by every window's status bar
	static let shared = ProcessStats()

	// current physical footprint in bytes
	@Published private(set) var footprintBytes: UInt64 = 0
	// highest footprint since launch, in bytes
	@Published private(set) var peakFootprintBytes: UInt64 = 0
	// CPU use over the last interval, 100 = one full core
	@Published private(set) var cpuPercent: Double = 0
	// number of threads in the process
	@Published private(set) var threadCount: Int = 0

	// refresh interval while focused / while another app is focused;
	// sampling stops entirely when no window is on screen
	private let kSampleForegroundSeconds: TimeInterval = 2
	private let kSampleBackgroundSeconds: TimeInterval = 5
	// repeating sampler
	private var timer: Timer?
	// user + system CPU seconds at the previous sample
	private var lastCpuSeconds: Double = 0
	// wall clock of the previous sample
	private var lastSampleAt = Date()
	// activity subscription
	private var cancellable: AnyCancellable?

	// takes a first sample and ticks at a pace that follows AppActivity
	private init() {
		lastCpuSeconds = ProcessStats.cpuSeconds()
		sample()
		cancellable = AppActivity.shared.$level
			.removeDuplicates()
			.sink { [weak self] vLevel in
				self?.reschedule(inLevel: vLevel)
			}
	}

	// restarts the timer for the given visibility level (none when hidden)
	private func reschedule(inLevel: AppActivity.Level) {
		timer?.invalidate()
		timer = nil
		let vInterval: TimeInterval
		switch inLevel {
			case .hidden: return
			case .background: vInterval = kSampleBackgroundSeconds
			case .foreground: vInterval = kSampleForegroundSeconds
		}
		sample()
		let vTimer = Timer(timeInterval: vInterval, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated {
				self?.sample()
			}
		}
		// .common so it keeps ticking during scrolling / live resize
		RunLoop.main.add(vTimer, forMode: .common)
		timer = vTimer
	}

	// reads the current figures and publishes the ones that changed
	private func sample() {
		let vMemory = ProcessStats.memory()
		let vNow = Date()
		let vCpu = ProcessStats.cpuSeconds()
		let vElapsed = vNow.timeIntervalSince(lastSampleAt)
		let vPercent = vElapsed > 0 ? max(0, (vCpu - lastCpuSeconds) / vElapsed * 100) : 0
		lastCpuSeconds = vCpu
		lastSampleAt = vNow
		let vThreads = ProcessStats.threadCount()

		if footprintBytes != vMemory.footprint { footprintBytes = vMemory.footprint }
		if peakFootprintBytes != vMemory.peak { peakFootprintBytes = vMemory.peak }
		// round so tiny jitter doesn't republish every tick
		let vRounded = (vPercent * 10).rounded() / 10
		if cpuPercent != vRounded { cpuPercent = vRounded }
		if threadCount != vThreads { threadCount = vThreads }
	}

	// ===========================
	// MARK: System calls
	// ===========================

	// physical footprint and its lifetime peak (task_vm_info)
	private nonisolated static func memory() -> (footprint: UInt64, peak: UInt64) {
		var vInfo = task_vm_info_data_t()
		var vCount = mach_msg_type_number_t(
			MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
		)
		let vResult = withUnsafeMutablePointer(to: &vInfo) { vPtr in
			vPtr.withMemoryRebound(to: integer_t.self, capacity: Int(vCount)) { vIntPtr in
				task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), vIntPtr, &vCount)
			}
		}
		guard vResult == KERN_SUCCESS else { return (0, 0) }
		let vFootprint = vInfo.phys_footprint
		return (vFootprint, max(vFootprint, UInt64(vInfo.ledger_phys_footprint_peak)))
	}

	// total user + system CPU time consumed so far, in seconds
	private nonisolated static func cpuSeconds() -> Double {
		var vUsage = rusage()
		guard getrusage(RUSAGE_SELF, &vUsage) == 0 else { return 0 }
		let vUser = Double(vUsage.ru_utime.tv_sec) + Double(vUsage.ru_utime.tv_usec) / 1_000_000
		let vSystem = Double(vUsage.ru_stime.tv_sec) + Double(vUsage.ru_stime.tv_usec) / 1_000_000
		return vUser + vSystem
	}

	// number of threads of this task
	private nonisolated static func threadCount() -> Int {
		var vThreads: thread_act_array_t?
		var vCount = mach_msg_type_number_t(0)
		guard task_threads(mach_task_self_, &vThreads, &vCount) == KERN_SUCCESS, let vList = vThreads else {
			return 0
		}
		// the port array and each thread port must be released
		for vI in 0..<Int(vCount) {
			mach_port_deallocate(mach_task_self_, vList[vI])
		}
		vm_deallocate(
			mach_task_self_,
			vm_address_t(UInt(bitPattern: vList)),
			vm_size_t(Int(vCount) * MemoryLayout<thread_t>.stride)
		)
		return Int(vCount)
	}
}

// SearchStats holds the per-window search figures shown by the status bar.
// Kept apart from WindowSearchModel so updating them (every refilter)
// doesn't invalidate ContentView, which observes the search model for the
// table rows.
@MainActor
final class SearchStats: ObservableObject {

	// number of records matching the current query
	@Published var matchCount: Int = 0
	// wall time of the last completed filter + sort, in milliseconds
	@Published var lastSearchMilliseconds: Double = 0
}
