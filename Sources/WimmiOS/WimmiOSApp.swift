#if os(iOS)
import SwiftUI
import AVFoundation
import MediaPlayer
import WimmDomain
import WimmInfrastructure
import WimmTranscription

/// Receives CloudKit's silent pushes: another device changed a note, sync now
/// (also while the app is in the background).
final class WimmPushDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        if let service = CloudRecordingSyncService.live() {
            Task { await service.subscribeToChanges() }
        }
        return true
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard let service = CloudRecordingSyncService.live() else { return .noData }
        do {
            return try await service.syncNow() ? .newData : .noData
        } catch {
            print("[CloudSync] push sync failed: \(error)")
            return .failed
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("[CloudSync] push registration failed: \(error)")
    }
}

@main
struct WimmiOSApp: App {
    @UIApplicationDelegateAdaptor(WimmPushDelegate.self) private var pushDelegate
    // As a unit-test host the app is unsigned, so it has no CloudKit
    // entitlement and `CKContainer(identifier:)` traps before any test runs.
    @StateObject private var appState = AppState(
        startServices: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    )
    @AppStorage(AppLanguage.defaultsKey) private var appLanguageRaw: String = AppLanguage.system.rawValue
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Configure FileStore for iOS
        do {
            try DefaultFileStore.shared.ensureDirectoryExists()
        } catch {
            print("Failed to setup directories: \(error)")
        }
        // Must happen before the app finishes launching.
        BackgroundSync.register()
        SpeakerSplitBackgroundTime.install()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environment(\.locale, AppLanguage(storedValue: appLanguageRaw).locale)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                appState.processingQueue.resumeIfNeeded()
                SpeakerSplitCatchUp.runOnceIfNeeded()
                Task {
                    await appState.loadRecordings()
                    await appState.drainShareInbox()
                    await appState.syncNow()
                    await appState.loadRecordings()
                }
            case .background:
                BackgroundSync.schedule()
            default:
                break
            }
        }
    }
}

/// Minimal app state for iOS
@MainActor
class AppState: ObservableObject, ProcessingPerformer {
    @Published var recordings: [Recording] = [] {
        didSet { recordingsRevision &+= 1 }
    }
    /// Bumped on every change to `recordings`, including in-place row
    /// updates, so the list's search index knows when to refold.
    private(set) var recordingsRevision: UInt64 = 0
    @Published var isRecording = false
    @Published var isLoading = true
    @Published var recoveryMessage: String?
    @Published var showCapture = false
    /// Bumped by an AirPods press while recording; the open capture screen splits
    /// the note (closes it and records on into a new one), as its own split button.
    @Published private(set) var splitRequest: UInt64 = 0
    /// Notes with a manual re-transcription in flight.
    @Published var reprocessingURLs: Set<URL> = []
    
    let audioRecorder: ReliableRecorder
    let processingQueue: ProcessingQueue
    private var isFinishingRecording = false
    private var recordingPublicationGeneration = 0
    private var recordingPublicationVersions: [String: Int] = [:]
    private var recordingsLoadGeneration = 0
    
    // Use IOSRecordingRepository from WimmDomain
    let repository = IOSRecordingRepository()
    private let displayMetadata = MetadataRepository()
    private let displayTranscripts = TranscriptRepository()

    private func displayNote(for url: URL, directoryIndex: RecordingsDirectoryIndex? = nil,
                             sidecar: (dictionary: [String: Any], noteCard: NoteCard?)? = nil) async -> Note {
        await NoteBuilder.build(file: url, index: 0, metaRepo: displayMetadata,
                                transcriptRepo: displayTranscripts,
                                directoryIndex: directoryIndex,
                                includeSearchMetadata: false,
                                prefetchedSidecar: sidecar)
    }

    /// A list row depends only on the note file and its sidecar. A later load
    /// reuses the row while both are unchanged (modification time and size),
    /// so returning to the foreground costs two `stat` calls per note instead
    /// of parsing every sidecar again.
    struct ListItemStamp: Equatable {
        let file: FileStamp?
        let sidecar: FileStamp?

        struct FileStamp: Equatable {
            let seconds: Int
            let nanoseconds: Int
            let size: Int64
        }

        static func of(_ url: URL) -> ListItemStamp {
            ListItemStamp(file: fileStamp(url.path),
                          sidecar: fileStamp(FileStore.metadataURL(forRecordingURL: url).path))
        }

        private static func fileStamp(_ path: String) -> FileStamp? {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            return FileStamp(seconds: Int(info.st_mtimespec.tv_sec),
                             nanoseconds: Int(info.st_mtimespec.tv_nsec),
                             size: Int64(info.st_size))
        }
    }
    private var listItemCache: [URL: (stamp: ListItemStamp, item: Recording)] = [:]
    /// How many rows list loads built from disk rather than reused (tests check reuse).
    private(set) var listItemBuilds = 0

    /// One listing of the recordings folder per list load. Without it every
    /// note listed the whole folder again to look for its screenshots: with
    /// ~10k notes and ~20k files that kept a core busy for 12–25 minutes after
    /// each launch or return to the foreground
    /// (`docs/iOS_Battery_Measurement_Results_2026-11-12.md`).
    private var listDirectoryIndex: RecordingsDirectoryIndex?
    /// How many folder listings list loads have made (tests check it is one per load).
    private(set) var listDirectoryIndexBuilds = 0
    private let cloudSyncService: CloudRecordingSyncService?
    
    init(audioRecorder: ReliableRecorder? = nil, startServices: Bool = true) {
        self.audioRecorder = audioRecorder ?? ReliableRecorder()
        self.processingQueue = ProcessingQueue(storeURL: startServices ? ProcessingQueue.defaultStoreURL : nil)
        self.cloudSyncService = startServices ? CloudRecordingSyncService.live() : nil
        processingQueue.performer = self
        guard startServices else { return }
        setupRemoteCommands()
        setupInterruptionHandling()
        
        Task {
            // Local notes must be visible even while CloudKit is offline or
            // reconciling thousands of remote records after an update.
            await loadRecordings()
            // First, attempt to recover any incomplete recordings from crashes
            await recoverIncompleteRecordings()
            // Pick up files the share extension dropped while we were dead.
            await drainShareInbox()
            // Launch reconciles the whole library: a Mac note uploaded long after its
            // file time is outside the incremental window.
            await syncNow(fullScan: true)
            // Then load all recordings normally
            await loadRecordings()
        }
    }
    
    private func setupRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()
        cc.togglePlayPauseCommand.isEnabled = true
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            
            Task { @MainActor in
                await self.airPodsPressed(via: "play/pause")
            }
            return .success
        }
        // While the AirPods mic records, a stem press is the "mute microphone" gesture,
        // not play/pause. Never let it mute the note: unmute at once and treat it as a press.
        NotificationCenter.default.addObserver(
            forName: AVAudioApplication.inputMuteStateChangeNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard (note.userInfo?[AVAudioApplication.muteStateKey] as? Bool) == true else { return }
            Task { @MainActor in
                try? AVAudioApplication.shared.setInputMuted(false)
                await self?.airPodsPressed(via: "mute gesture")
            }
        }
    }

    // MARK: - Phone calls

    /// Set when a call closed a note that should continue in a new one.
    private(set) var restartAfterInterruption = false

    private func setupInterruptionHandling() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let event = AudioInterruptionEvent(notification.userInfo) else { return }
            Task { @MainActor in await self?.handleAudioInterruption(event) }
        }
    }

    func handleAudioInterruption(_ event: AudioInterruptionEvent) async {
        let action = AudioInterruptionPolicy.action(
            for: event, isRecording: audioRecorder.isRecording,
            isUserPaused: audioRecorder.isPaused, restartPending: restartAfterInterruption)
        switch action {
        case .none:
            if case .ended = event { restartAfterInterruption = false }
        case .finish(let restartAfter):
            log("[IOSRecorder] interrupted (call); closing the note, restart after: \(restartAfter)")
            await finishRecording()
            restartAfterInterruption = restartAfter
        case .startNewRecording:
            restartAfterInterruption = false
            log("[IOSRecorder] interruption ended; starting a new note")
            showCapture = true
            await audioRecorder.startRecording()
        }
    }

    private var lastAirPodsPress: Date?

    /// One press may arrive both as play/pause and as the mute gesture; act once.
    private func airPodsPressed(via source: String) async {
        let now = Date()
        if let last = lastAirPodsPress, now.timeIntervalSince(last) < 1 {
            log("[IOSRecorder] AirPods press (\(source)) ignored: repeat within 1 s")
            return
        }
        lastAirPodsPress = now
        log("[IOSRecorder] AirPods press (\(source)), recording: \(audioRecorder.isRecording), paused: \(audioRecorder.isPaused)")
        await handleGlobalPlayPause()
    }

    func handleGlobalPlayPause() async {
        // An explicit command after a call replaces the automatic restart.
        restartAfterInterruption = false
        guard !isFinishingRecording else { return }
        if audioRecorder.isRecording {
            // Send, as in Studio: the note closes and recording goes on in a new one.
            // A paused note resumes instead (the split needs a running recording).
            if audioRecorder.isPaused {
                showCapture = true
                splitRequest &+= 1
            } else if showCapture {
                splitRequest &+= 1
            } else {
                await finishRecording()
            }
        } else {
            showCapture = true
            // Give the UI a moment to appear if needed, or just start recording
            // reliably recorder handles state.
            // If we start recording here, SketchCaptureView needs to reflect it.
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
            await audioRecorder.startRecording()
        }
    }
    
    /// Only local finalization belongs on the capture screen. Cloud uploads can
    /// take minutes (or fail offline) and must never hold the recorder or cover open.
    func finishRecording() async {
        guard !isFinishingRecording, audioRecorder.isRecording,
              let url = audioRecorder.recordingURL else { return }
        isFinishingRecording = true
        defer { isFinishingRecording = false }

        await audioRecorder.stopRecording()
        await publishRecording(at: url)
        showCapture = false
        scheduleRecordingSync(for: url)
    }

    /// Publish one durable note without rescanning the library or its duration assets.
    ///
    /// A note already in the list is updated in place and keeps its date and
    /// position. Re-dating it here (the sidecar timestamp, or "now" for Mac
    /// notes that have none) moved it into Today until the next full load moved
    /// it back — and a row changing day sections under a live SwiftUI List is
    /// what crashed UICollectionView ("invalid number of items in section")
    /// while the processing queue published one note after another.
    func publishRecording(at url: URL) async {
        await repository.invalidateCache()
        let card = await repository.existingNoteCard(for: url)
        let displayNote = await displayNote(for: url)
        let id = url.lastPathComponent
        recordingPublicationGeneration += 1
        recordingPublicationVersions[id] = recordingPublicationGeneration
        if let index = recordings.firstIndex(where: { $0.id == id }) {
            let existing = recordings[index]
            recordings[index] = Recording(
                id: id,
                fileURL: url,
                timestamp: existing.timestamp,
                durationSeconds: existing.durationSeconds,
                note: card,
                titlePreview: displayNote.displayTitle(fallback: "")
            )
            return
        }
        let metadata = try? await repository.loadMetadata(for: url)
        let recording = Recording(
            id: id,
            fileURL: url,
            timestamp: Self.listTimestamp(for: url, fallback: metadata?.timestamp),
            durationSeconds: metadata?.duration ?? 0,
            note: card,
            titlePreview: displayNote.displayTitle(fallback: "")
        )
        let insertAt = recordings.firstIndex { $0.timestamp < recording.timestamp } ?? recordings.endIndex
        recordings.insert(recording, at: insertAt)
    }

    /// The one date rule for the list, shared by the full load and a single
    /// publish so the two can never disagree about which day a note is on.
    nonisolated static func listTimestamp(for url: URL, fallback: Date? = nil) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? fallback ?? Date()
    }

    /// An app-owned task survives dismissal of the capture view. It uses the
    /// finished URL only and never changes the current recorder or presentation.
    func scheduleRecordingSync(for url: URL) {
        Task {
            await enqueueSync(for: url)
        }
    }

    // MARK: - Reprocessing engines (class members so tests can override them;
    // the flow lives in NoteReprocessing.swift)

    /// Whether the provider behind `model` has a key. Re-reads Settings so a
    /// key entered a moment ago counts without restarting the app.
    func hasKey(for model: String) async -> Bool {
        // On-device Parakeet needs no key; ModelRouter files it under Gemini on purpose.
        if ParakeetModel.isParakeet(model) { return true }
        switch ModelRouter.provider(for: model) {
        case .gemini:
            return await ConfiguredKeys.gemini()
        case .openrouter:
            return await ConfiguredKeys.openRouter()
        case .apple, .local:
            return true
        }
    }

    /// Transcribes with `Config.transcribeModel`; the service persists the run.
    func runTranscription(of url: URL) async throws -> String {
        try await runTranscription(of: url, model: Config.transcribeModel)
    }

    /// Transcribes with `model` for this run only ("Transcribe again →
    /// On-device / Cloud"); Settings keep their hear model. The service
    /// persists the run, and the run it replaces stays in the sidecar.
    func runTranscription(of url: URL, model: String) async throws -> String {
        let service = TranscriptionService(rotator: .shared, model: model, transport: .shared)
        let engine: EngineID = ModelRouter.provider(for: model) == .openrouter ? .openrouter : .gemini
        switch await service.transcribe(file: url, engine: engine, model: model) {
        case .success(let text):
            return text
        case .failure(.cancelled, _):
            // Out of background time, not a broken note: ProcessingQueue requeues on this.
            throw CancellationError()
        case .failure(let reason, let underlying):
            let detail = underlying.map { NoteReprocessingError.providerMessage(from: $0.localizedDescription) }
            throw NoteReprocessingError.transcriptionFailed(detail ?? "\(reason)")
        }
    }

    func loadRecordings() async {
        let publicationGeneration = recordingPublicationGeneration
        recordingsLoadGeneration += 1
        let loadGeneration = recordingsLoadGeneration
        isLoading = true
        defer {
            if loadGeneration == recordingsLoadGeneration { isLoading = false }
        }
        
        // Fetch URLs
        let urls = await repository.recordings(order: .descending)
        guard loadGeneration == recordingsLoadGeneration else { return }
        let directories = Array(Set(urls.map { $0.deletingLastPathComponent().standardizedFileURL }))
        listDirectoryIndex = RecordingsDirectoryIndex(directories: directories)
        listDirectoryIndexBuilds += 1
        defer {
            if loadGeneration == recordingsLoadGeneration { listDirectoryIndex = nil }
        }
        
        var items: [Recording] = []
        var seen = Set<String>()
        // Partial publishes at 50, 100, 200, 400… rows: the first screen shows
        // at once, and the whole load re-sorts and re-diffs the list O(log N)
        // times instead of every 50 notes (O(N²) on a ~10k-note library).
        var nextPartialPublish = 50
        var freshCache: [URL: (stamp: ListItemStamp, item: Recording)] = [:]
        freshCache.reserveCapacity(urls.count)
        for url in urls {
             // The list keys rows by file name; a second copy would be a
             // duplicate identity, which a SwiftUI List cannot diff.
             guard seen.insert(url.lastPathComponent).inserted else { continue }
             let stamp = ListItemStamp.of(url)
             let rec: Recording
             if let cached = listItemCache[url], cached.stamp == stamp {
                 rec = cached.item
                 // A fully cached load never suspends otherwise; let the UI breathe.
                 if items.count % 500 == 499 { await Task.yield() }
             } else {
                 rec = await recordingListItem(for: url)
                 listItemBuilds += 1
             }
             guard loadGeneration == recordingsLoadGeneration else { return }
             items.append(rec)
             freshCache[url] = (stamp, rec)
             // Show the first rows without waiting for every sidecar. Keep
             // existing rows until the complete snapshot can reconcile them.
             if items.count == nextPartialPublish {
                 nextPartialPublish *= 2
                 applyLoadedRecordings(items, startedAt: publicationGeneration, complete: false)
             }
        }
        applyLoadedRecordings(items, startedAt: publicationGeneration, complete: true)
        // Only notes still in the folder stay cached.
        listItemCache = freshCache
    }

    /// List rendering never opens audio assets. A damaged/unfinished container
    /// must not stall the entire library; duration already lives in the sidecar.
    func recordingListItem(for url: URL) async -> Recording {
        // One sidecar read for the card, the duration and the note text.
        let sidecar = await displayMetadata.metadataAndNoteCard(for: url)
        let card = sidecar.1
        let sidecarDuration = sidecar.0["duration"] as? Double
        // Only the list load's own snapshot; a single publish lists the folder fresh.
        let note = await displayNote(for: url, directoryIndex: listDirectoryIndex,
                                     sidecar: (sidecar.0, card))
        let storedDuration = sidecarDuration ?? note.duration
        let duration = storedDuration.isFinite && storedDuration > 0 ? storedDuration : 0
        return Recording(id: url.lastPathComponent, fileURL: url,
                         timestamp: Self.listTimestamp(for: url),
                         durationSeconds: duration, note: card,
                         titlePreview: note.displayTitle(fallback: ""))
    }

    private func applyLoadedRecordings(_ items: [Recording], startedAt generation: Int, complete: Bool) {
        var byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        for current in recordings {
            if (recordingPublicationVersions[current.id] ?? 0) > generation
                || (!complete && byID[current.id] == nil) {
                byID[current.id] = current
            }
        }
        recordings = byID.values.sorted {
            if $0.timestamp == $1.timestamp { return $0.id < $1.id }
            return $0.timestamp > $1.timestamp
        }
    }

    private var syncInFlight = false
    /// Cold launch fires both init-drain and scenePhase .active — don't overlap.
    var shareInboxDrainInFlight = false

    func syncNow(fullScan: Bool = false) async {
        // Cold launch fires both init-sync and scenePhase .active — don't overlap.
        guard let cloudSyncService, !syncInFlight else { return }
        syncInFlight = true
        defer { syncInFlight = false }
        do {
            try await cloudSyncService.syncNow(fullScan: fullScan)
        } catch {
            print("[CloudSync] syncNow failed: \(error)")
        }
    }

    func enqueueSync(for url: URL) async {
        guard let cloudSyncService else { return }
        do {
            _ = try await cloudSyncService.enqueueNewRecording(url)
            try await cloudSyncService.uploadPending()
        } catch {
            print("[CloudSync] enqueue failed for \(url.lastPathComponent): \(error)")
        }
    }

    func deleteRecording(_ recording: Recording) async {
        await NoteTrash.moveToTrash(recording.fileURL, cloudSync: cloudSyncService)
        await repository.invalidateCache()
        await loadRecordings()
    }
    
    /// Recovers incomplete recordings from interrupted sessions (crashes/force quits)
    func recoverIncompleteRecordings() async {
        print("[RecoveryStartup] Scanning for incomplete recordings...")
        
        let incompleteURLs = await repository.findIncompleteRecordings()
        
        guard !incompleteURLs.isEmpty else {
            print("[RecoveryStartup] No incomplete recordings found")
            return
        }
        
        print("[RecoveryStartup] Found \(incompleteURLs.count) incomplete recording(s)")
        
        var recoveredCount = 0
        for url in incompleteURLs {
            do {
                // Load the metadata to get the partial transcription and duration
                let metadata = try await repository.loadMetadata(for: url)
                
                print("[RecoveryStartup] Recovering: \(url.lastPathComponent)")
                print("  - Partial transcription: \(metadata.transcription.prefix(50))...")
                print("  - Duration: \(String(format: "%.1f", metadata.duration))s")
                print("  - Last saved: \(metadata.lastSaved)")
                
                // Mark as complete to prevent re-recovery on next launch
                try await repository.markAsComplete(url)
                
                recoveredCount += 1
            } catch {
                print("[RecoveryStartup] Failed to recover \(url.lastPathComponent): \(error)")
            }
        }
        
        if recoveredCount > 0 {
            await MainActor.run {
                self.recoveryMessage = L10n.iOS.Success.recovered(count: recoveredCount)
            }
            print("[RecoveryStartup] Successfully recovered \(recoveredCount) recording(s)")
        }
    }
}

struct Recording: Identifiable {
    let id: String
    let fileURL: URL
    let timestamp: Date
    let durationSeconds: Double
    let note: NoteCard?
    var titlePreview: String = ""
}

/// What kind of content a journal item holds; drives which detail layout
/// and list icon is used.
enum NoteMediaKind {
    case audio, image, pdf, text, document

    init(fileURL: URL) {
        let ext = fileURL.pathExtension.lowercased()
        if AttachmentTypeHelper.imageExtensions.contains(ext) {
            self = .image
        } else if AttachmentTypeHelper.pdfExtensions.contains(ext) {
            self = .pdf
        } else if AttachmentTypeHelper.textExtensions.contains(ext) {
            self = .text
        } else if AttachmentTypeHelper.officeExtensions.contains(ext) {
            self = .document
        } else {
            self = .audio
        }
    }
}

extension Recording {
    var displayTitle: String {
        if !titlePreview.isEmpty { return titlePreview }
        let type: String
        switch mediaKind {
        case .audio: type = L10n.iOS.Recording.title
        case .image: type = L10n.iOS.Recording.titlePhoto
        case .text: type = L10n.iOS.Recording.titleNote
        case .pdf, .document: type = L10n.iOS.Recording.titleDocument
        }
        return "\(type) · \(timestamp.formatted(date: .omitted, time: .shortened))"
    }

    var mediaKind: NoteMediaKind {
        NoteMediaKind(fileURL: fileURL)
    }
}

#endif

#if !os(iOS)
@main
struct MacOSDummyMain {
    static func main() {
        print("This target is for iOS only.")
    }
}
#endif
