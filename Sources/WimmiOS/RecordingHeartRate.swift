#if os(iOS)
import Foundation
import HealthKit
import WimmDomain
import WimmInfrastructure

/// Trial: pulse during a voice recording. Off by default.
enum RecordingHeartRateSetting {
    static let defaultsKey = "ios.recording.heartRate"

    /// Stored in the App Group defaults like the other iOS settings.
    static func isEnabled(in defaults: UserDefaults = SharedUserDefaults.store) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    static func set(_ enabled: Bool, in defaults: UserDefaults = SharedUserDefaults.store) {
        defaults.set(enabled, forKey: defaultsKey)
    }
}

/// One pulse reading inside a note.
struct HeartRateSample: Equatable {
    /// Wall-clock seconds from the note's start (a pause is not subtracted).
    let offset: TimeInterval
    let bpm: Int

    var sidecarValue: [String: Any] {
        ["offsetSeconds": (offset * 10).rounded() / 10, "bpm": bpm]
    }
}

/// Pulse readings of one note, in order (sidecar key `heartRate`).
struct HeartRateTrack: Equatable {
    static let metadataKey = "heartRate"

    let startedAt: Date
    private(set) var samples: [HeartRateSample] = []
    private var lastDate: Date?

    init(startedAt: Date) {
        self.startedAt = startedAt
    }

    /// False when the reading is not this note's or was already taken.
    @discardableResult
    mutating func add(bpm: Double, at date: Date) -> Bool {
        guard bpm.isFinite, bpm > 0, date >= startedAt else { return false }
        if let lastDate, date <= lastDate { return false }
        lastDate = date
        samples.append(HeartRateSample(offset: date.timeIntervalSince(startedAt), bpm: Int(bpm.rounded())))
        return true
    }

    var sidecarValue: [[String: Any]] { samples.map(\.sidecarValue) }
}

/// What the recorder needs from the pulse source.
@MainActor
protocol RecordingHeartRateCapturing: AnyObject {
    /// Called with every new reading of the running note, nil when it ends.
    var onReading: ((Int?) -> Void)? { get set }
    func noteStarted(url: URL, at start: Date)
    func noteStopped()
}

enum RecordingHeartRate {
    /// nil where an iPhone workout session does not exist (before iOS 26, no HealthKit).
    @MainActor
    static func makeCapture() -> RecordingHeartRateCapturing? {
        guard #available(iOS 26.0, *), HKHealthStore.isHealthDataAvailable() else { return nil }
        return WorkoutHeartRateCapture()
    }
}

/// AirPods Pro 3 (and Apple Watch) measure pulse continuously only inside a
/// workout, so the recording runs a HealthKit workout session and reads the
/// heart rate it collects. The workout itself is discarded, never saved.
@available(iOS 26.0, *)
@MainActor
final class WorkoutHeartRateCapture: NSObject, RecordingHeartRateCapturing,
                                     HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    /// A split closes one note and opens the next at once: keep one session across it.
    private static let endGraceSeconds: TimeInterval = 5

    var onReading: ((Int?) -> Void)?

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var starting = false
    private var noteURL: URL?
    private var track: HeartRateTrack?
    private var endTask: Task<Void, Never>?

    func noteStarted(url: URL, at start: Date) {
        endTask?.cancel()
        endTask = nil
        noteURL = url
        track = HeartRateTrack(startedAt: start)
        guard session == nil, !starting else { return }
        starting = true
        Task { await startSession() }
    }

    func noteStopped() {
        noteURL = nil
        track = nil
        onReading?(nil)
        endTask?.cancel()
        endTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.endGraceSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.endSession()
        }
    }

    private func startSession() async {
        defer { starting = false }
        let heartRate = HKQuantityType(.heartRate)
        do {
            try await store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [heartRate])
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .other
            configuration.locationType = .indoor
            let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            let source = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
            source.enableCollection(for: heartRate, predicate: nil)
            builder.dataSource = source
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder
            let now = Date()
            session.startActivity(with: now)
            try await builder.beginCollection(at: now)
            log("[HeartRate] workout session started")
            // The note may have ended while the permission sheet was up.
            if noteURL == nil { endSession() }
        } catch {
            log("[HeartRate] workout session not started: \(error.localizedDescription)")
            endSession()
        }
    }

    private func endSession() {
        guard let session, let builder else { return }
        self.session = nil
        self.builder = nil
        session.end()
        Task {
            do {
                try await builder.endCollection(at: Date())
            } catch {
                log("[HeartRate] end of collection failed: \(error.localizedDescription)")
            }
            builder.discardWorkout()
            log("[HeartRate] workout session ended, workout discarded")
        }
    }

    private func record(bpm: Double, at date: Date) {
        guard let url = noteURL, track?.add(bpm: bpm, at: date) == true, let track else { return }
        if track.samples.count == 1 { log("[HeartRate] first reading for \(url.lastPathComponent)") }
        FileStore.upsertMetadata(for: url, updates: [HeartRateTrack.metadataKey: track.sidecarValue])
        onReading?(track.samples.last?.bpm)
    }

    // MARK: - HKLiveWorkoutBuilderDelegate

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                                    didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let heartRate = HKQuantityType(.heartRate)
        guard collectedTypes.contains(heartRate),
              let statistics = workoutBuilder.statistics(for: heartRate),
              let quantity = statistics.mostRecentQuantity() else { return }
        let bpm = quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        let date = statistics.mostRecentQuantityDateInterval()?.end ?? Date()
        Task { @MainActor [weak self] in self?.record(bpm: bpm, at: date) }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    // MARK: - HKWorkoutSessionDelegate

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {}

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        log("[HeartRate] workout session failed: \(error.localizedDescription)")
    }
}
#endif
