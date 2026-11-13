import Foundation
import Darwin

/// Lightweight programmatic profiler for UI flow metrics (search latency, scroll fulfillment, etc.).
/// Enabled via DefaultsKey.profilingEnabled or env WIMM_PROFILING=1.
public final class Profiler: @unchecked Sendable {
    public static let shared = Profiler()
    private init() {}

    public static var isEnabled: Bool {
        if let env = ProcessInfo.processInfo.environment["WIMM_PROFILING"], env == "1" || env.lowercased() == "true" { return true }
        return UserDefaults.standard.bool(forKey: DefaultsKey.profilingEnabled)
    }

    private struct StartKey: Hashable { let name: String; let id: String }
    private var starts: [StartKey: Date] = [:]
    private var lock = NSLock()
    private var sampleVersion: Int = 0

    public struct Series { public var values: [Double] = [] }
    public internal(set) var series: [String: Series] = [:]
    private var samplingTimer: DispatchSourceTimer?
    private var cpuLastSample: (user: Double, system: Double, wall: Date)?
    private var cpuLock = NSLock()

    // Series that represent counts (unitless integers), not durations
    private static let countSeriesNames: Set<String> = [
        "rowAppearCount",
        "searchQueryLength",
        "searchResultCount",
        "deleteNote.usedFastPath",
        "visibleIndices.notesCount",
        "visibleIndices.filteredCount",
        "visibleIndices.queryLength"
    ]
    private static let unitOverrides: [String: (suffix: String, label: String)] = [
        "cpu.percent": (suffix: "%", label: " unit=%"),
        "mem.rssMB": (suffix: "MB", label: " unit=MB"),
        "mem.footprintMB": (suffix: "MB", label: " unit=MB"),
        "mem.virtualMB": (suffix: "MB", label: " unit=MB")
    ]

    public func start(_ name: String, id: AnyHashable) {
        guard Self.isEnabled else { return }
        let k = StartKey(name: name, id: String(describing: id))
        lock.lock(); defer { lock.unlock() }
        starts[k] = Date()
    }

    public func end(_ name: String, id: AnyHashable) {
        guard Self.isEnabled else { return }
        let k = StartKey(name: name, id: String(describing: id))
        lock.lock(); defer { lock.unlock() }
        if let s = starts.removeValue(forKey: k) {
            let dt = Date().timeIntervalSince(s)
            var ser = series[name] ?? Series()
            ser.values.append(dt)
            series[name] = ser
            sampleVersion += 1
        }
    }

    public func record(_ name: String, value: Double) {
        guard Self.isEnabled else { return }
        lock.lock(); defer { lock.unlock() }
        var ser = series[name] ?? Series()
        ser.values.append(value)
        series[name] = ser
        sampleVersion += 1
    }

    public func currentSampleVersion() -> Int {
        lock.lock(); defer { lock.unlock() }
        return sampleVersion
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        series.removeAll()
        starts.removeAll()
        sampleVersion = 0
    }

    public func saveReport(in directory: URL) -> URL? {
        let txt = reportString()
        let url = directory.appendingPathComponent("WimmProfiler-\(Int(Date().timeIntervalSince1970)).txt")
        do { try txt.write(to: url, atomically: true, encoding: .utf8); return url } catch { return nil }
    }

    public func reportString() -> String {
        lock.lock(); defer { lock.unlock() }
        var out = [String]()
        out.append("Wimm Profiler Report — \(Date())")
        for (name, ser) in series.sorted(by: { $0.key < $1.key }) {
            let vals = ser.values
            guard !vals.isEmpty else { continue }
            let count = vals.count
            let minv = vals.min() ?? 0
            let maxv = vals.max() ?? 0
            let avg = vals.reduce(0, +) / Double(count)
            let sorted = vals.sorted()
            func p(_ q: Double) -> Double { let idx = Int(Double(count - 1) * q); return sorted[max(0, min(idx, count - 1))] }
            let p50 = p(0.5)
            let p90 = p(0.9)
            let p95 = p(0.95)
            let p99 = p(0.99)

            let override = Self.unitOverrides[name]
            let isCount = Self.countSeriesNames.contains(name)
            let unitSuffix = override?.suffix ?? (isCount ? "" : "s")
            let unitLabel = override?.label ?? (isCount ? " unit=count" : "")
            func fmt(_ v: Double) -> String { String(format: "%.3f", v) }

            out.append("\n[\(name)] n=\(count)\(unitLabel) avg=\(fmt(avg))\(unitSuffix) min=\(fmt(minv))\(unitSuffix) p50=\(fmt(p50))\(unitSuffix) p90=\(fmt(p90))\(unitSuffix) p95=\(fmt(p95))\(unitSuffix) p99=\(fmt(p99))\(unitSuffix) max=\(fmt(maxv))\(unitSuffix)")
        }
        return out.joined(separator: "\n")
    }

    @discardableResult
    public func saveReport() -> URL? {
        let txt = reportString()
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("WimmProfiler-\(Int(Date().timeIntervalSince1970)).txt")
        do { try txt.write(to: url, atomically: true, encoding: .utf8); return url } catch { return nil }
    }

    public func startSampling(interval: TimeInterval = 0.5) {
        guard Self.isEnabled else { return }
        lock.lock()
        let alreadyRunning = samplingTimer != nil
        lock.unlock()
        guard !alreadyRunning else { return }

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.sampleResources()
        }
        samplingTimer = timer
        timer.resume()
    }

    public func stopSampling() {
        lock.lock()
        let timer = samplingTimer
        samplingTimer = nil
        lock.unlock()
        timer?.cancel()
    }

    private func sampleResources() {
        guard Self.isEnabled else { return }
        sampleCPUPercent()
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride)
        let kerr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { infoPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), infoPtr, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return }

        let mb = 1_048_576.0
        record("mem.rssMB", value: Double(info.resident_size) / mb)
        record("mem.virtualMB", value: Double(info.virtual_size) / mb)
        record("mem.footprintMB", value: Double(info.phys_footprint) / mb)
    }

    private func sampleCPUPercent() {
        var times = task_thread_times_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_thread_times_info_data_t>.stride / MemoryLayout<natural_t>.stride)
        let kerr = withUnsafeMutablePointer(to: &times) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { infoPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), infoPtr, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return }

        func timeValueToSeconds(_ tv: time_value_t) -> Double {
            Double(tv.seconds) + Double(tv.microseconds) / 1_000_000.0
        }

        let user = timeValueToSeconds(times.user_time)
        let system = timeValueToSeconds(times.system_time)
        let now = Date()

        cpuLock.lock()
        let last = cpuLastSample
        cpuLastSample = (user: user, system: system, wall: now)
        cpuLock.unlock()

        guard let last else { return }
        let elapsed = now.timeIntervalSince(last.wall)
        guard elapsed > 0 else { return }

        let delta = (user - last.user) + (system - last.system)
        let cores = max(1, ProcessInfo.processInfo.processorCount)
        let percent = (delta / elapsed) * 100.0 / Double(cores)
        record("cpu.percent", value: percent)
    }
}
