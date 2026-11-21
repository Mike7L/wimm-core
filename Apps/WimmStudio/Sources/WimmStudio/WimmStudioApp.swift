import AppKit
import WimmDocumentUI
import WimmDomain
import SwiftUI
import WimmInfrastructure
import WimmSecretary

@main
@MainActor enum StudioLauncher {
    static func main() {
        if DocumentProfile.enabled {
            do { try DocumentProfile.prepare() }
            catch { FileHandle.standardError.write(Data("Invalid document profile: \(error)\n".utf8)); return }
            let application = NSApplication.shared
            let delegate = StudioAppDelegate()
            application.delegate = delegate
            application.run()
        } else {
            WimmStudioApp.main()
        }
    }
}

struct WimmStudioApp: App {
    @NSApplicationDelegateAdaptor(StudioAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Wimm Studio", id: "personal-document") {
            Group { if !DocumentProfile.enabled { StudioMainView(
                panels: appDelegate.panels,
                documentModel: appDelegate.documentModel,
                capture: appDelegate.capture,
                recentNotes: appDelegate.recentNotes,
                cloudSync: appDelegate.cloudSync,
                onPrivateModeChanged: { appDelegate.playCue($0 ? .lockOn : .lockOff) }
            )
            .frame(minWidth: 480, minHeight: 460) } }
        }
        .defaultSize(width: 1440, height: 880)
        .commands {
            CommandGroup(before: .toolbar) {
                ForEach(StudioPanel.allCases) { panel in
                    Toggle(panel.title, isOn: Binding(
                        get: { appDelegate.panels.isVisible(panel) },
                        set: { appDelegate.panels.setVisible(panel, $0) }
                    ))
                    .keyboardShortcut(KeyEquivalent(panel.shortcut), modifiers: [.command])
                }
                Divider()
            }
            CommandMenu("Studio") {
                Button(appDelegate.capture.isRecording ? "Stop Recording" : "Start Recording") {
                    appDelegate.capture.toggle()
                }
                .keyboardShortcut("w", modifiers: [.option])
                .disabled(appDelegate.capture.isBusy || appDelegate.capture.isSending)

                Button("Send and Keep Recording") {
                    Task { await appDelegate.capture.send() }
                }
                .keyboardShortcut("x", modifiers: [.option])
                .disabled(!appDelegate.capture.isRecording || appDelegate.capture.isSending)

                Button("Save Screenshot as Note") {
                    appDelegate.saveQuickNote { [try await QuickNotes.screenshot()] }
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(appDelegate.isSavingQuickNote)

                Button("Save Clipboard as Note") {
                    appDelegate.saveQuickNote { try QuickNotes.pasteClipboard() }
                }
                .keyboardShortcut("c", modifiers: [.option])
                .disabled(appDelegate.isSavingQuickNote)

                Button("Evening Journal") {
                    appDelegate.showEvening()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button("Friend Conversation") {
                    appDelegate.showFriend()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])

                Button("Angel and Demon") {
                    appDelegate.showShoulders()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Toggle("Алёна — обращение «Алёна»", isOn: Binding(
                    get: { appDelegate.vik.enabled },
                    set: { appDelegate.vik.enabled = $0 }
                ))
                Toggle("Алёна: я в наушниках — не выключать микрофон", isOn: Binding(
                    get: { appDelegate.vik.keepMicOpen },
                    set: { appDelegate.vik.keepMicOpen = $0 }
                ))
                Picker("Голос Алёны", selection: Binding(
                    get: { VikVoice.selectedVoice },
                    set: { VikVoice.selectedVoice = $0 }
                )) {
                    ForEach(VikVoice.voices, id: \.self) { Text("Supertonic \($0)").tag($0) }
                }
                Button("Остановить ответ Алёны") { appDelegate.vik.cancel() }
                    .disabled(!appDelegate.vik.isResponding && appDelegate.vik.phase != .listening)

                Picker("Angel and Demon Style", selection: Binding(
                    get: { ShouldersStyle.current },
                    set: { ShouldersStyle.current = $0 }
                )) {
                    ForEach(ShouldersStyle.allCases) { Text($0.title).tag($0) }
                }

                Picker("Angel and Demon Thinking", selection: Binding(
                    get: { ShouldersThinking.current },
                    set: { ShouldersThinking.current = $0 }
                )) {
                    ForEach(ShouldersThinking.allCases) { Text($0.title).tag($0) }
                }

                Menu("Angel and Demon Voices") {
                    Picker("Angel Voice (Female)", selection: Binding(
                        get: { UserDefaults.standard.string(forKey: ShoulderSpeaker.angelVoiceKey) ?? "F4" },
                        set: { UserDefaults.standard.set($0, forKey: ShoulderSpeaker.angelVoiceKey) }
                    )) {
                        ForEach(ShoulderSpeaker.availableFemaleVoices, id: \.self) { v in
                            Text("Supertonic \(v)").tag(v)
                        }
                    }

                    Picker("Demon Voice (Male)", selection: Binding(
                        get: { UserDefaults.standard.string(forKey: ShoulderSpeaker.demonVoiceKey) ?? "M5" },
                        set: { UserDefaults.standard.set($0, forKey: ShoulderSpeaker.demonVoiceKey) }
                    )) {
                        ForEach(ShoulderSpeaker.availableMaleVoices, id: \.self) { v in
                            Text("Supertonic \(v)").tag(v)
                        }
                    }

                    Divider()

                    Toggle("Auto-Start Recording After Their Turn", isOn: Binding(
                        get: { UserDefaults.standard.object(forKey: ShoulderSpeaker.autoRecordAfterTurnKey) as? Bool ?? true },
                        set: { UserDefaults.standard.set($0, forKey: ShoulderSpeaker.autoRecordAfterTurnKey) }
                    ))
                }

                Button("Rebuild Angel and Demon Dossier") {
                    appDelegate.rebuildShouldersDossier()
                }

                Button("Модели…") {
                    ModelsWindow.show(secretary: appDelegate.documentModel.secretary)
                }
                .keyboardShortcut(",", modifiers: [.command])

                Divider()

                // Kill switch: while on, every cloud request refuses (LLMTransport).
                Toggle("Приватный режим — ничего в облако", isOn: Binding(
                    get: { PrivateMode.isEnabled },
                    set: {
                        appDelegate.panels.setPrivateMode($0)
                        appDelegate.playCue(PrivateMode.isEnabled ? .lockOn : .lockOff)
                    }
                ))

                Button(appDelegate.cloudSync?.isAvailable == false ? "Sync Unavailable (no CloudKit entitlement)" : "Sync Now") {
                    Task { await appDelegate.cloudSync?.syncRequested() }
                }
                .disabled(appDelegate.cloudSync?.isAvailable != true)

                Toggle("Import Codex and Claude Sessions", isOn: Binding(
                    get: { appDelegate.importsAgentSessions },
                    set: { appDelegate.importsAgentSessions = $0 }
                ))

                Button("Toggle Responsive HUD") {
                    appDelegate.toggleHUD()
                }
                .keyboardShortcut("h", modifiers: [.option])

                Menu("HUD Island") {
                    Toggle("Attach to Screen Edge", isOn: Binding(
                        get: { appDelegate.isHUDIsland },
                        set: { appDelegate.setHUDIsland($0) }
                    ))
                    ForEach(HUDIslandEdge.allCases) { edge in
                        Button(edge.title) { appDelegate.setHUDIslandEdge(edge) }
                            .disabled(!appDelegate.isHUDIsland)
                    }
                }

                Button("Open Markdown Document…") {
                    appDelegate.documentModel.choose()
                }
                .keyboardShortcut("o", modifiers: [.command])
                .disabled(appDelegate.documentModel.secretary.isRunning || appDelegate.documentModel.isEditing)

                Button("Reload Document") {
                    Task { await appDelegate.documentModel.load() }
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(appDelegate.documentModel.secretary.isRunning || appDelegate.documentModel.isEditing)
            }
        }
    }
}

@MainActor
@Observable
final class StudioAppDelegate: NSObject, NSApplicationDelegate {
    let capture = CaptureSession()
    let documentModel = DocumentModel(url: DocumentProfile.enabled ? DocumentProfile.documentURL : nil)
    let recentNotes = RecentNotes(limit: 60)
    let panels = StudioWindowModel()
    private var hudPanel: ResponsiveHUDPanel?
    private let webLauncher = StudioWebLauncher()
    private let notePresenter = StudioNotePresenter()
    private let saveConfirmation = StudioSaveConfirmation()
    private let eveningPresenter = EveningPresenter()
    private let friendPresenter = FriendPresenter()
    private let textInsertion = StudioTextInsertion()
    /// One ⌥V at a time: a second press while the local run is awaited would insert twice.
    private var isInsertPending = false
    @ObservationIgnored private(set) lazy var vik = VikAssistant(
        capture: capture, voice: VikVoice(),
        document: { [weak self] in self?.documentModel.document?.text ?? "" },
        preferences: .standard,
        // nil = started. Unwrap self first: `self?.f() ?? x` would turn that success into x.
        runSecretary: { [weak self] in
            guard let self else { return "Секретарь недоступен." }
            return self.startSecretaryPassFromVoice()
        },
        library: VikLibrary(),
        reviewQueue: { [weak self] in
            (self?.documentModel.fileURL).flatMap(SecretaryWorkspace.init(document:))?
                .root.appendingPathComponent("secretary/review_queue.md")
        }
    )
    @ObservationIgnored private var secretaryOfferTask: Task<Void, Never>?
    /// Backlog size at the last question, and the run that was latest then: a new run
    /// or a backlog below one packet allows the next question.
    @ObservationIgnored private var secretaryOfferedBytes: Int?
    @ObservationIgnored private var secretaryOfferedAfterRun: Date?
    @ObservationIgnored private var vikFailureShown = false
    @ObservationIgnored private var cueTracker = HUDCueTracker()
    @ObservationIgnored private var hotKeyTokens: [HotKeyCenter.Token] = []
    @ObservationIgnored private var captureCommandObserver: NSObjectProtocol?
    /// Reads the web panel's angel-and-demon lines aloud (the model stays loaded here).
    @ObservationIgnored private let externalShoulderVoice = ExternalShoulderVoice()
    private(set) var isSavingQuickNote = false
    /// Created after launch, never while the scene graph is being built: the
    /// 2026-10-31 build crashed in `CKContainer(identifier:)` when this was
    /// first touched from the menu's body, inside `runApp`. Wimm creates its
    /// service well after launch too. Nil in a document-profile run.
    private(set) var cloudSync: StudioCloudSync?
    @ObservationIgnored private let transcriptCatchUp = StudioTranscriptCatchUp()
    @ObservationIgnored private let imageTextCatchUp = StudioImageTextCatchUp()
    @ObservationIgnored private var sessionImportTask: Task<Void, Never>?
    var importsAgentSessions = UserDefaults.standard.object(forKey: "studioImportsAgentSessions") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(importsAgentSessions, forKey: "studioImportsAgentSessions")
        }
    }

    private struct ExternalShouldersContext: Decodable {
        var conversationId: String?
        var conversationFile: String?
        var doc: String?
        var section: String?
        var heading: String?
        var quote: String?
        var prompt: String?
        var updatedAt: TimeInterval?
    }

    private func applyExternalShouldersContextIfFresh(to recordingURL: URL) {
        let contextURL = StoragePaths.baseDirectory()
            .appendingPathComponent("Conversation", isDirectory: true)
            .appendingPathComponent("active_shoulders_context.json")
        guard let data = try? Data(contentsOf: contextURL),
              let ctx = try? JSONDecoder().decode(ExternalShouldersContext.self, from: data) else {
            return
        }
        // Only link if the web conversation context was updated recently (within the last 20 minutes).
        if let updatedAt = ctx.updatedAt {
            let ageSeconds = Date().timeIntervalSince1970 - (updatedAt > 10_000_000_000 ? updatedAt / 1000.0 : updatedAt)
            if ageSeconds > 1200 { return }
        }
        try? RecallSidecar.linkConversation(
            forRecordingURL: recordingURL,
            source: "shoulders-conversation",
            doc: ctx.doc,
            section: ctx.section,
            heading: ctx.heading,
            conversationId: ctx.conversationId,
            conversationFile: ctx.conversationFile,
            prompt: ctx.prompt
        )
    }

    private func registerExternalCaptureCommandObserver() {
        captureCommandObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.micha.wimm.studio.captureCommand"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            let action = (note.userInfo?["action"] as? String) ?? (note.object as? String) ?? ""
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch action {
                case "start":
                    if !self.capture.isRecording && !self.capture.isBusy && !self.capture.isSending {
                        await self.capture.start()
                    }
                case "stop":
                    if self.capture.isRecording && !self.capture.isBusy {
                        await self.capture.stop()
                    }
                case "toggle":
                    if !self.capture.isBusy && !self.capture.isSending {
                        self.capture.toggle()
                    }
                default:
                    break
                }
            }
        }
    }

    /// Алёна's phase lives in the bottom banner, so an exchange never opens the HUD
    /// over the user's work; the full reply waits in the HUD.
    private func trackVikBanner() {
        withObservationTracking {
            saveConfirmation.setStatus(vik.banner)
            let failed = vik.phase == .failed
            if failed, !vikFailureShown {
                saveConfirmation.show(message: "Алёна не ответила", systemImage: "exclamationmark.triangle.fill",
                                      duration: .seconds(5))
            }
            vikFailureShown = failed
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.trackVikBanner() }
        }
    }

    /// Headphones mode (`keepMicOpen`) is the user's word that cues cannot reach the microphone.
    func playCue(_ cue: HUDSound.Cue) {
        HUDSound.play(cue, recording: capture.isRecording, headphones: vik.keepMicOpen)
    }

    private func trackSoundCues() {
        withObservationTracking {
            let snapshot = HUDCueTracker.Snapshot(
                recording: capture.isRecording, sendCount: capture.sendCount,
                inputTrouble: capture.inputTrouble, vik: vik.phase, headphones: vik.keepMicOpen)
            cueTracker.cues(for: snapshot).forEach(playCue)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.trackSoundCues() }
        }
    }

    private func startSecretaryPassFromVoice() -> String? {
        let model = documentModel
        guard model.hasSecretaryWorkspace else { return "Документ не в рабочей папке секретаря." }
        guard !model.secretary.isRunning else { return "Секретарь уже работает." }
        guard !model.isEditing else { return "Документ сейчас редактируется, секретаря не запускаю." }
        model.runSecretary(.pass)
        return nil
    }

    /// Every few minutes: when the notes waiting for a pass fill one packet, Алёна asks
    /// whether to start the secretary. Local reads only; never starts a run itself.
    private func monitorSecretaryBacklog() {
        guard !StoragePaths.isTestProcess, secretaryOfferTask == nil else { return }
        secretaryOfferTask = Task(priority: .utility) { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            while !Task.isCancelled {
                await self?.checkSecretaryBacklog()
                do { try await Task.sleep(for: .seconds(5 * 60)) } catch { return }
            }
        }
    }

    private func checkSecretaryBacklog() async {
        let model = documentModel
        guard vik.enabled, !PrivateMode.isEnabled, model.hasSecretaryWorkspace,
              !model.secretary.isRunning, !model.isEditing else { return }
        if secretaryOfferedAfterRun != model.secretary.startedAt { secretaryOfferedBytes = nil }
        guard let scan = await SecretaryPassPlanner.scan() else { return }
        let packetBytes = SecretaryPacketSettings.normalize(model.secretary.packetSourceKB) * 1000
        if scan.pendingBytes < packetBytes { secretaryOfferedBytes = nil }
        guard VikSecretaryOffer.shouldOffer(bytes: scan.pendingBytes, packetBytes: packetBytes,
                                            lastOfferedBytes: secretaryOfferedBytes),
              !model.secretary.isRunning, !PrivateMode.isEnabled,
              vik.offerSecretary(pending: scan.pending, bytes: scan.pendingBytes) else { return }
        secretaryOfferedBytes = scan.pendingBytes
        secretaryOfferedAfterRun = model.secretary.startedAt
    }

    /// A note was created or edited here: refresh the library and queue it for the iPhone.
    private func noteChanged(_ files: [URL]) {
        recentNotes.reload(changedFiles: files)
        NotificationCenter.default.post(name: .studioNoteChanged, object: files)
        // Before sync starts, a full pass picks up never-synced notes anyway.
        for file in files { cloudSync?.noteChanged(file) }
    }

    func saveQuickNote(_ make: @escaping @MainActor () async throws -> [URL]) {
        guard !isSavingQuickNote else { return }
        isSavingQuickNote = true
        saveConfirmation.dismiss()
        Task { @MainActor in
            defer { isSavingQuickNote = false }
            do {
                let files = try await make()
                capture.errorMessage = nil
                noteChanged(files)
                imageTextCatchUp.recognize(files)
                if !files.isEmpty {
                    saveConfirmation.show(count: files.count)
                    playCue(.saved)
                }
            } catch {
                capture.errorMessage = error.localizedDescription
                showHUD()
            }
        }
    }

    /// CloudKit's silent push: another device changed a note.
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        log("[CloudSync] push received")
        Task { @MainActor in await self.cloudSync?.pushReceived() }
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        log("[CloudSync] push registration ok")
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        log("[CloudSync] push registration failed: \(error.localizedDescription)")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        HUDSound.preload()
        capture.onRecordingStarting = { [weak self] in
            guard let self else { return }
            self.playCue(HUDCueTracker.startCue(vikResuming: self.vik.isResumingCapture))
        }
        capture.onRecordingChanged = { [weak self] recording in
            guard let self, !recording else { return }
            self.playCue(HUDCueTracker.stopCue(vik: self.vik.phase, headphones: self.vik.keepMicOpen))
        }
        trackSoundCues()
        if !DocumentProfile.enabled { SecretaryLibraryWarmup.shared.start() }

        capture.onUserAction = { [weak self] in self?.vik.captureWillAct($0) }
        capture.onSilenceDetected = { [weak self] in self?.vik.silenceDetected(revision: $0) ?? false }
        capture.onSendRequested = { [weak self] in self?.vik.silenceDetected() ?? false }
        capture.onLiveFinalized = { [weak self] file, revision, result in
            self?.vik.liveFinalized(file, revision: revision, result: result)
        }

        capture.onCommentPosted = { [weak self] url in
            guard let self, self.documentModel.fileURL?.standardizedFileURL == url.standardizedFileURL else { return }
            Task { await self.documentModel.reloadComments(force: true) }
        }
        capture.onNoteSaved = { [weak self] file in
            self?.noteChanged([file])
        }
        capture.allowsNoteCardAnalysis = false
        capture.onNoteTranscribed = { [weak self] file, text in
            guard let self else { return }
            self.applyExternalShouldersContextIfFresh(to: file)
            self.friendPresenter.noteTranscribed(file, text: text)
        }
        capture.onTranscriptMissing = { [weak self] file in
            self?.transcriptCatchUp.transcriptMissing(file)
        }
        transcriptCatchUp.onNoteTranscribed = { [weak self] file in
            self?.noteChanged([file])
        }
        imageTextCatchUp.onNoteRecognized = { [weak self] file in
            self?.noteChanged([file])
        }
        documentModel.onNoteCreated = { [weak self] file in
            self?.noteChanged([file])
        }

        if DocumentProfile.enabled {
            for window in NSApp.windows { window.orderOut(nil) }
            DocumentProfile.run(app: "WimmStudio", loadLibrary: {
                self.recentNotes.reload()
                await self.recentNotes.waitUntilLoaded()
                return ["notes": self.recentNotes.allNotes.count,
                        "decoded_notes": self.recentNotes.lastDecodedCount,
                        "timeline_title_utf8_bytes": self.recentNotes.allNotes.reduce(0) { $0 + $1.studioTitle.utf8.count },
                        "hud_search_utf8_bytes": self.recentNotes.notes.reduce(0) { $0 + $1.metadataSearchText.utf8.count },
                        "hud_notes": self.recentNotes.notes.count]
            }, makeDocument: {
                AnyView(StudioDocumentView(model: self.documentModel, capture: self.capture, recentNotes: self.recentNotes,
                                           panels: self.panels))
            })
            return
        }
        if !StoragePaths.isTestProcess {
            // Live text first, the voice second: both compile for the Neural Engine, and a
            // parallel voice warm-up once kept the live transcriber from loading (2026-11-16).
            // The gate is set before anything asks for the voice.
            let parakeetPreload = Task(priority: .utility) {
                let started = Date()
                do {
                    try await ParakeetTranscriptionAdapter.preload(onlyIfInstalled: true)
                    log(String(format: "[Capture] Parakeet preload finished in %.1fs", Date().timeIntervalSince(started)))
                } catch {
                    log("[Capture] Parakeet preload failed: \(error.localizedDescription)")
                }
            }
            // During non-stop capture the preload waits behind live sessions; the model the
            // live transcriber loaded is just as good a signal.
            NeuralSpeech.shared.loadAfter {
                await WarmupOrder.wait(for: { await parakeetPreload.value },
                                       orUntil: { await ParakeetTranscriptionAdapter.isLoaded() })
            }
        }
        trackVikBanner()
        vik.onNotice = { [weak self] in self?.saveConfirmation.show(message: "Алёна: \($0)", systemImage: "tray.full") }
        vik.startMonitoring()
        monitorSecretaryBacklog()
        recentNotes.reload()
        if !StoragePaths.isTestProcess {
            sessionImportTask = Task(priority: .utility) { [weak self, importer = StudioSessionImport()] in
                while !Task.isCancelled {
                    if self?.importsAgentSessions == true {
                        let files = await importer.run()
                        if !files.isEmpty { self?.noteChanged(files) }
                    }
                    do { try await Task.sleep(for: .seconds(15 * 60)) }
                    catch { break }
                }
            }
        }
        registerHotKeys()
        if !StoragePaths.isTestProcess { registerAirPodsPress() }
        registerExternalCaptureCommandObserver()
        if !StoragePaths.isTestProcess { externalShoulderVoice.start() }
        showHUD()
        // Requests left over from a quit mid-run, then recordings that never got text.
        transcriptCatchUp.drain()
        transcriptCatchUp.sweep(excluding: capture.recordingURL)
        imageTextCatchUp.sweep()
        // One run-loop turn later, so launch has fully finished before CloudKit is touched.
        DispatchQueue.main.async { [weak self] in self?.startCloudSync() }
    }

    private func startCloudSync() {
        let sync = StudioCloudSync(
            onRemoteChanges: { [weak self] in self?.recentNotes.reload() },
            onDownloaded: { [weak self] files in self?.transcriptCatchUp.synced(files) })
        cloudSync = sync
        if sync.isAvailable {
            sync.start()
            sync.subscribeToPushes()
        } else if capture.errorMessage == nil {
            capture.errorMessage = "Синк с iPhone выключен: у этой сборки нет прав CloudKit (нужен профиль com.micha.wimm.macos, см. scripts/make_studio.sh)."
        }
    }

    private func registerHotKeys() {
        let bindings: [(UInt32, String, () -> Void)] = [
            (HotKeyCenter.KeyCode.ansiW, "⌥W", { [weak self] in
                guard let self, !self.capture.isBusy, !self.capture.isSending else { return }
                self.capture.toggle()
            }),
            (HotKeyCenter.KeyCode.ansiC, "⌥C", { [weak self] in
                self?.saveQuickNote { try QuickNotes.pasteClipboard() }
            }),
            (HotKeyCenter.KeyCode.ansiX, "⌥X", { [weak self] in
                Task { @MainActor [weak self] in await self?.capture.send() }
            }),
            (HotKeyCenter.KeyCode.ansiH, "⌥H", { [weak self] in self?.toggleHUD() }),
            (HotKeyCenter.KeyCode.ansiV, "⌥V", { [weak self] in self?.insertIntoOtherApp() }),
        ]
        var unavailable: [String] = []
        for (code, label, action) in bindings {
            if let token = HotKeyCenter.shared.register(keyCode: code, flags: [.option], handler: action) {
                hotKeyTokens.append(token)
            } else {
                unavailable.append(label)
            }
        }
        if !unavailable.isEmpty {
            capture.errorMessage = "Глобальные клавиши заняты: \(unavailable.joined(separator: ", ")). Закройте Wimm или другое приложение, использующее их, и перезапустите Studio."
        }
    }

    /// AirPods stem press: send while recording (⌥X), start when idle (⌥W).
    private func registerAirPodsPress() {
        AirPodsCaptureGesture.install { [weak self] in
            guard let self, !self.capture.isBusy, !self.capture.isSending else { return }
            switch self.capture.phase {
            case .recording:
                log("[Capture] AirPods press → send")
                Task { @MainActor [weak self] in await self?.capture.send() }
            case .idle:
                log("[Capture] AirPods press → start")
                self.capture.toggle()
            case .starting, .finishing:
                break
            }
        }
    }

    /// ⌥V into the app the user came from. While recording with live words it closes the
    /// note as ⌥X does (the microphone rolls into a new note) and inserts that note's local
    /// run once it lands. With no live words it is the stopped recording's stored text,
    /// else the newest note.
    private func insertIntoOtherApp() {
        guard !isInsertPending else { return }
        let live = capture.liveText
        let hasLive = !live.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let active = capture.phase != .idle
        let url = capture.recordingURL
        let newest = recentNotes.notes.lazy.compactMap(\.insertableText).last
        isInsertPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isInsertPending = false }
            var stored: String?
            var closed = false, landed = false
            if self.capture.phase == .recording, hasLive, let url, !self.capture.isSending {
                await self.capture.send()
                // Vik may take the send over; then the note is still open and only live text exists.
                if self.capture.recordingURL != url {
                    closed = true
                    self.saveConfirmation.show(message: "Заметка закрыта — жду локальную расшифровку…",
                                               systemImage: "hourglass", duration: .seconds(35))
                    (stored, landed) = await StudioTextInsertion.awaitLocalRun(of: url)
                }
            } else if !active, hasLive, let url {
                // The live text stays on screen after a stop; the sidecar is read fresh so a
                // finished local run wins over it without waiting for the note list.
                stored = await TranscriptRepository().transcriptText(for: url)
            }
            guard let text = StudioTextInsertion.text(isCapturing: active && !closed, live: live, stored: stored, newest: newest) else {
                self.capture.errorMessage = "Нет текста для вставки."
                self.saveConfirmation.show(message: "Нет текста для вставки", systemImage: "exclamationmark.triangle.fill")
                return
            }
            let reached = await self.textInsertion.insert(text)
            self.capture.errorMessage = reached ? nil : "Текст скопирован — нажмите ⌘V (нужен доступ к Accessibility)."
            self.saveConfirmation.show(
                message: StudioTextInsertion.receipt(closedNote: closed, localLanded: landed, hadLive: hasLive, reachedApp: reached),
                systemImage: reached ? "checkmark.circle.fill" : "doc.on.clipboard")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        vik.shutdown()
        secretaryOfferTask?.cancel()
        sessionImportTask?.cancel()
        capture.finishForTermination()
        cloudSync?.stop()
        externalShoulderVoice.stop()
        if let obs = captureCommandObserver {
            DistributedNotificationCenter.default().removeObserver(obs)
            captureCommandObserver = nil
        }
        hotKeyTokens.forEach { HotKeyCenter.shared.unregister($0) }
        hotKeyTokens.removeAll()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !DocumentProfile.enabled else { return }
        recentNotes.reload()
    }

    func showHUD() {
        if hudPanel == nil {
            let island = HUDIslandModel()
            let hudView = ResponsiveHUDView(
                capture: capture,
                recentNotes: recentNotes,
                onOpenDocument: { [weak self] in self?.focusDocumentWindow() },
                onOpenNote: { [weak self] in self?.openHUDNote($0) },
                onOpenWeb: { [weak self] in self?.webLauncher.open() },
                onOpenList: { [weak self] in
                    self?.panels.setVisible(.timeline, true)
                    self?.focusDocumentWindow()
                },
                island: island,
                vik: vik,
                onSaveQuickNote: { [weak self] make in self?.saveQuickNote(make) }
            )
            hudPanel = ResponsiveHUDPanel(rootView: hudView, island: island)
        }
        hudPanel?.orderFrontRegardless()
    }

    private func openHUDNote(_ file: URL) {
        if let entry = StudioNoteLink.resolve(file, in: recentNotes.notesByURLPath) {
            openNote(entry)
            return
        }
        // A just-saved transcript can be clicked before the library refresh lands.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.recentNotes.reload(changedFiles: [file])
            await self.recentNotes.waitUntilLoaded()
            if let entry = StudioNoteLink.resolve(file, in: self.recentNotes.notesByURLPath) {
                self.openNote(entry)
            }
        }
    }

    private func openNote(_ note: StudioLibraryNote) {
        notePresenter.show(note, onSave: { [weak self] file in
            self?.noteChanged([file])
        }, onTrash: { [weak self] file in
            guard await StudioNoteTrash.move(file) else { return false }
            // The file is gone from the library: only a full pass drops its entry.
            self?.recentNotes.reload()
            return true
        }, onOpenURL: { [weak self] url in
            guard let self, let entry = StudioNoteLink.resolve(url, in: self.recentNotes.notesByURLPath) else { return false }
            self.openNote(entry)
            return true
        })
    }

    func showEvening() {
        eveningPresenter.show(recentNotes: recentNotes, capture: capture,
                              onOpenNote: { [weak self] in self?.openHUDNote($0) },
                              onNoteChanged: { [weak self] in self?.noteChanged($0) },
                              onAnswerRecorded: { [weak self] in self?.transcriptCatchUp.transcriptMissing($0) })
    }

    func showFriend() {
        friendPresenter.show(capture: capture)
    }

    func showShoulders() {
        friendPresenter.show(capture: capture, mode: .shoulders(document: documentModel.fileURL))
    }

    /// The old dossier is kept beside the new one; an open conversation keeps its own until reopened.
    func rebuildShouldersDossier() {
        do {
            try ShouldersChat.setDossierAside()
            showShoulders()
        } catch {
            log("[Shoulders] dossier not set aside: \(error.localizedDescription)")
        }
    }

    var isHUDIsland: Bool { hudPanel?.island.isEnabled ?? UserDefaults.standard.bool(forKey: "WimmStudio.hudIsland") }

    func setHUDIsland(_ on: Bool) {
        showHUD()
        hudPanel?.setIslandEnabled(on)
    }

    func setHUDIslandEdge(_ edge: HUDIslandEdge) {
        hudPanel?.setIslandEdge(edge)
    }

    func toggleHUD() {
        if let panel = hudPanel, panel.isVisible {
            panel.orderOut(nil)
        } else {
            showHUD()
        }
    }

    func focusDocumentWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where !(window is ResponsiveHUDPanel) && !notePresenter.owns(window)
            && !eveningPresenter.owns(window) && !friendPresenter.owns(window) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
