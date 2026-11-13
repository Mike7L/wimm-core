import AppKit
import Foundation
import Observation
import WimmDomain
import WimmInfrastructure

/// The slice of `CloudRecordingSyncService` Studio drives; a seam for tests.
protocol StudioSyncService: Sendable {
    func subscribeToChanges() async
    func syncNow(fullScan: Bool, recentOnly: Bool) async throws -> Bool
    func enqueueNewRecording(_ recordingURL: URL) async throws -> SyncRecordingID
    func uploadPending() async throws
    func drainFreshlyDownloaded() async -> [URL]
}

extension CloudRecordingSyncService: StudioSyncService {}

/// Desktop↔iPhone sync for Studio. The engine is the app's one shared
/// `CloudRecordingSyncService.live()` (never a second instance: each holds its
/// own ledger); this class only decides *when* it runs, as Wimm's Reader does:
/// at launch, on a timer, when the app comes to the front, and shortly after a
/// note is saved here.
///
/// Studio runs no post-download processing yet (OCR, cards, transcription of
/// recordings that arrived without text): downloaded notes appear in the
/// library as the iPhone sent them.
@MainActor @Observable
final class StudioCloudSync {
    /// Pushes are low priority and Apple may delay or drop them, so a cheap
    /// poll of the last few minutes caps how long an iPhone note can wait.
    static let pollInterval: TimeInterval = 15
    static let incrementalScanInterval: TimeInterval = 120
    static let fullScanInterval: TimeInterval = 30 * 60
    static let activationMinGap: TimeInterval = 30

    private(set) var isSyncing = false
    private(set) var lastSyncAt: Date?
    private(set) var lastError: String?
    var isAvailable: Bool { service != nil }

    @ObservationIgnored private let service: (any StudioSyncService)?
    @ObservationIgnored private let uploadDelay: Duration
    @ObservationIgnored private let onRemoteChanges: @MainActor () -> Void
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var uploadTask: Task<Void, Never>?
    @ObservationIgnored private var pendingUploads: Set<URL> = []
    @ObservationIgnored private var lastPullAt: Date?
    @ObservationIgnored private var pushWhileSyncing = false
    @ObservationIgnored private var followUpTask: Task<Void, Never>?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    /// `service` is nil when this build carries no CloudKit entitlement
    /// (`CloudRecordingSyncService.live()` says so in the log); sync then stays
    /// off and every call is a no-op.
    init(service: (any StudioSyncService)? = CloudRecordingSyncService.live(),
         uploadDelay: Duration = .seconds(2),
         onRemoteChanges: @escaping @MainActor () -> Void) {
        self.service = service
        self.uploadDelay = uploadDelay
        self.onRemoteChanges = onRemoteChanges
    }

    func start() {
        guard service != nil, pollTask == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.activate() }
        }
        pollTask = Task { [weak self] in
            await self?.sync(fullScan: true)
            var lastFullScan = Date()
            var lastIncrementalScan = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollInterval))
                guard let self, !Task.isCancelled else { return }
                // Records from older builds carry their file time, not their
                // upload time, so only a full pass is sure to see them.
                let full = Date().timeIntervalSince(lastFullScan) >= Self.fullScanInterval
                if full { lastFullScan = Date() }
                let recentOnly = !full
                    && Date().timeIntervalSince(lastIncrementalScan) < Self.incrementalScanInterval
                if !recentOnly { lastIncrementalScan = Date() }
                await self.sync(fullScan: full, recentOnly: recentOnly)
            }
        }
    }

    /// Instant sync: CloudKit pushes a silent notification on every change.
    /// Polling remains the fallback.
    func subscribeToPushes() {
        guard let service else { return }
        NSApp.registerForRemoteNotifications()
        Task { await service.subscribeToChanges() }
    }

    /// CloudKit's query index lags a save by seconds, so the pull right after
    /// a push often misses the record that caused it: pull again shortly after.
    static let pushFollowUps: [Duration] = [.seconds(5), .seconds(20)]

    /// A push can land mid-sync; remember it and pull again right after.
    func pushReceived() async {
        guard service != nil else { return }
        await pullForPush()
        followUpTask?.cancel()
        followUpTask = Task { [weak self] in
            for delay in Self.pushFollowUps {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                await self?.pullForPush()
            }
        }
    }

    private func pullForPush() async {
        if isSyncing { pushWhileSyncing = true; return }
        repeat {
            pushWhileSyncing = false
            await sync(fullScan: false, recentOnly: true)
        } while pushWhileSyncing
    }

    func stop() {
        pollTask?.cancel(); pollTask = nil
        uploadTask?.cancel(); uploadTask = nil
        followUpTask?.cancel(); followUpTask = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
    }

    /// One two-way pass. Runs never overlap. Returns whether remote changes
    /// were applied to the library.
    @discardableResult
    func sync(fullScan: Bool, recentOnly: Bool = false) async -> Bool {
        guard let service, !isSyncing else { return false }
        isSyncing = true
        defer { isSyncing = false }
        lastPullAt = Date()
        var applied = false
        do {
            applied = try await service.syncNow(fullScan: fullScan, recentOnly: recentOnly)
            lastError = nil
            lastSyncAt = Date()
        } catch {
            lastError = error.localizedDescription
            log("[CloudSync] sync failed: \(error)")
        }
        // Nothing consumes the hand-off list here; drain it so it cannot grow.
        _ = await service.drainFreshlyDownloaded()
        if applied {
            log("[CloudSync] remote changes applied")
            onRemoteChanges()
        }
        return applied
    }

    func activate() async {
        if let lastPullAt, Date().timeIntervalSince(lastPullAt) < Self.activationMinGap { return }
        await sync(fullScan: false)
    }

    /// A note was created or edited here. Saves arrive in bursts (a recording
    /// reports once when the audio is durable and again with its final text),
    /// so uploads wait a moment and go together.
    func noteChanged(_ file: URL) {
        guard service != nil else { return }
        pendingUploads.insert(file)
        guard uploadTask == nil else { return }
        uploadTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.uploadDelay)
            guard !Task.isCancelled else { return }
            await self.flushUploads()
        }
    }

    func flushUploads() async {
        uploadTask = nil
        guard let service else { return }
        let files = pendingUploads
        pendingUploads.removeAll()
        for file in files {
            do { _ = try await service.enqueueNewRecording(file) }
            catch { log("[CloudSync] enqueue failed for \(file.lastPathComponent): \(error)") }
        }
        do { try await service.uploadPending() }
        catch { log("[CloudSync] upload failed: \(error)") }
    }
}
