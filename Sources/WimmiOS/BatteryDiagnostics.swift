#if os(iOS)
import Foundation
import UIKit
import AVFoundation
import WimmDomain

/// Debug switches for measuring what a recording costs in battery
/// (`docs/iOS_Battery_Measurement_Plan_2026-11-12.md`). Every switch is off by
/// default; with all of them off recording behaves exactly as without this file.
/// Values are read once when a recording starts, so a change applies to the next one.
struct BatteryDiagnosticsSettings: Equatable {
    static let logKey = "debug.battery.log"
    static let disableLiveTextKey = "debug.battery.disableLiveText"
    static let disableLevelMeterKey = "debug.battery.disableLevelMeter"
    static let quietLiveLogKey = "debug.battery.quietLiveLog"
    static let slowAutosaveKey = "debug.battery.slowAutosave"

    /// Write one CSV sample per minute while recording (and for a while after).
    var log = false
    /// Do not start the AVAudioEngine tap and on-device SFSpeechRecognizer at all.
    var disableLiveText = false
    /// Do not run the 10 Hz level timer that feeds the waveform.
    var disableLevelMeter = false
    /// Do not write a log line for every live-text partial result.
    var quietLiveLog = false
    /// Save the recording's metadata every 60 s instead of every 5 s.
    var slowAutosave = false

    init(log: Bool = false, disableLiveText: Bool = false, disableLevelMeter: Bool = false,
         quietLiveLog: Bool = false, slowAutosave: Bool = false) {
        self.log = log
        self.disableLiveText = disableLiveText
        self.disableLevelMeter = disableLevelMeter
        self.quietLiveLog = quietLiveLog
        self.slowAutosave = slowAutosave
    }

    init(defaults: UserDefaults) {
        log = defaults.bool(forKey: Self.logKey)
        disableLiveText = defaults.bool(forKey: Self.disableLiveTextKey)
        disableLevelMeter = defaults.bool(forKey: Self.disableLevelMeterKey)
        quietLiveLog = defaults.bool(forKey: Self.quietLiveLogKey)
        slowAutosave = defaults.bool(forKey: Self.slowAutosaveKey)
    }

    static var current: BatteryDiagnosticsSettings { .init(defaults: .standard) }

    var autosaveInterval: TimeInterval { slowAutosave ? 60 : 5 }

    /// Short tag of the A/B variant, written into every sample.
    var variant: String {
        var parts: [String] = []
        if disableLiveText { parts.append("noLive") }
        if disableLevelMeter { parts.append("noMeter") }
        if quietLiveLog { parts.append("quietLog") }
        if slowAutosave { parts.append("slowSave") }
        return parts.isEmpty ? "default" : parts.joined(separator: "+")
    }
}

/// One minute-ish sample of the app's cost.
struct BatterySample: Equatable {
    static let csvHeader = "time,phase,variant,elapsed_s,battery_pct,battery_state,low_power,thermal,app_state,brightness,input,cpu_s,cpu_pct,live_partials,live_restarts"

    var time: Date
    var phase: String          // start / recording / stop / after
    var variant: String
    var elapsed: TimeInterval  // since the recording started
    var batteryPercent: Int?   // nil when iOS reports unknown (-1)
    var batteryState: String
    var lowPower: Bool
    var thermal: String
    var appState: String
    var brightness: Double
    var input: String
    var cpuSeconds: Double     // whole process, user + system, since launch
    var cpuPercent: Double?    // of one core, over the interval since the previous sample
    var livePartials: Int      // since the previous sample
    var liveRestarts: Int      // since the previous sample

    var csvLine: String {
        [
            ISO8601.stringWithFractionalSeconds(from: time),
            phase,
            variant,
            String(format: "%.0f", elapsed),
            batteryPercent.map(String.init) ?? "",
            batteryState,
            lowPower ? "1" : "0",
            thermal,
            appState,
            String(format: "%.2f", brightness),
            input.replacingOccurrences(of: ",", with: " "),
            String(format: "%.2f", cpuSeconds),
            cpuPercent.map { String(format: "%.1f", $0) } ?? "",
            String(livePartials),
            String(liveRestarts)
        ].joined(separator: ",")
    }

    /// CPU share of one core between two process CPU readings.
    static func cpuPercent(previousCPU: Double, currentCPU: Double, wallSeconds: TimeInterval) -> Double? {
        guard wallSeconds > 0, currentCPU >= previousCPU else { return nil }
        return (currentCPU - previousCPU) / wallSeconds * 100
    }

    static func batteryPercent(fromLevel level: Float) -> Int? {
        level < 0 ? nil : Int((level * 100).rounded())
    }
}

/// Samples battery, CPU and conditions once a minute during a recording and for a
/// tail after it, into `logs/battery_YYYY-MM-DD.csv` in the library, and mirrors each
/// sample into the event log. Runs only while `debug.battery.log` is on.
@MainActor
final class BatteryProbe {
    static let shared = BatteryProbe()

    static let sampleInterval: TimeInterval = 60
    /// How long to keep sampling after the recording stops (CloudKit upload etc.).
    /// iOS suspends the app in background once audio stops, so the tail only
    /// covers time the app stays on screen.
    static let tailDuration: TimeInterval = 10 * 60

    private var timer: Timer?
    private var settings = BatteryDiagnosticsSettings()
    private var startedAt: Date?
    private var stoppedAt: Date?
    private var lastSampleTime: Date?
    private var lastCPU: Double = 0
    private var partials = 0
    private var restarts = 0

    var isActive: Bool { timer != nil }

    // Counters from the live-text pipeline; cheap no-ops when the probe is idle.
    nonisolated static func notePartial() {
        Task { @MainActor in if shared.isActive { shared.partials += 1 } }
    }
    nonisolated static func noteRestart() {
        Task { @MainActor in if shared.isActive { shared.restarts += 1 } }
    }

    func recordingStarted(settings: BatteryDiagnosticsSettings) {
        guard settings.log else { return }
        self.settings = settings
        UIDevice.current.isBatteryMonitoringEnabled = true
        startedAt = Date()
        stoppedAt = nil
        partials = 0
        restarts = 0
        lastSampleTime = nil
        sample(phase: "start")
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.sampleInterval, repeats: true) { _ in
            MainActor.assumeIsolated { BatteryProbe.shared.tick() }
        }
    }

    func recordingStopped() {
        guard isActive, stoppedAt == nil else { return }
        stoppedAt = Date()
        sample(phase: "stop")
    }

    private func tick() {
        if let stoppedAt {
            if Date().timeIntervalSince(stoppedAt) >= Self.tailDuration {
                sample(phase: "after")
                finish()
            } else {
                sample(phase: "after")
            }
        } else {
            sample(phase: "recording")
        }
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        UIDevice.current.isBatteryMonitoringEnabled = false
    }

    private func sample(phase: String) {
        let now = Date()
        let cpu = Self.processCPUSeconds()
        let device = UIDevice.current
        let s = BatterySample(
            time: now,
            phase: phase,
            variant: settings.variant,
            elapsed: startedAt.map { now.timeIntervalSince($0) } ?? 0,
            batteryPercent: BatterySample.batteryPercent(fromLevel: device.batteryLevel),
            batteryState: Self.name(device.batteryState),
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermal: Self.name(ProcessInfo.processInfo.thermalState),
            appState: Self.name(UIApplication.shared.applicationState),
            brightness: Double(UIScreen.main.brightness),
            input: AVAudioSession.sharedInstance().currentRoute.inputs.first?.portType.rawValue ?? "none",
            cpuSeconds: cpu,
            cpuPercent: lastSampleTime.flatMap {
                BatterySample.cpuPercent(previousCPU: lastCPU, currentCPU: cpu, wallSeconds: now.timeIntervalSince($0))
            },
            livePartials: partials,
            liveRestarts: restarts
        )
        lastSampleTime = now
        lastCPU = cpu
        partials = 0
        restarts = 0
        log("[Battery] \(s.csvLine)")
        Self.append(s)
    }

    // MARK: - Output

    static func logURL(for date: Date = Date()) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return logsDirectory().appendingPathComponent("battery_\(f.string(from: date)).csv")
    }

    static func logsDirectory() -> URL {
        StoragePaths.baseDirectory().appendingPathComponent("logs", isDirectory: true)
    }

    /// All battery CSVs, newest first, for sharing from Settings.
    static func existingLogs() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: logsDirectory(), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("battery_") && $0.pathExtension == "csv" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private static func append(_ sample: BatterySample) {
        let url = logURL(for: sample.time)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = Data((sample.csvLine + "\n").utf8)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: Data((BatterySample.csvHeader + "\n").utf8) + line)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    // MARK: - Readings

    nonisolated static func processCPUSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private static func name(_ s: UIDevice.BatteryState) -> String {
        switch s {
        case .unplugged: return "unplugged"
        case .charging: return "charging"
        case .full: return "full"
        default: return "unknown"
        }
    }

    private static func name(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func name(_ s: UIApplication.State) -> String {
        switch s {
        case .active: return "fg"
        case .inactive: return "inactive"
        case .background: return "bg"
        @unknown default: return "unknown"
        }
    }
}
#endif
