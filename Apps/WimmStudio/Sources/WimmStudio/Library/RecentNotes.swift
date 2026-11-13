import Foundation
import Observation
import WimmDomain
import WimmInfrastructure

/// A bounded full-text HUD slice and a compact, incremental timeline projection.
@MainActor @Observable
final class RecentNotes {
    private(set) var notes: [Note] = []
    private(set) var notesByMetadataName: [String: StudioLibraryNote] = [:]
    private(set) var notesByURLPath: [String: StudioLibraryNote] = [:]
    private(set) var allNotes: [StudioLibraryNote] = []
    private(set) var isLoading = false
    private(set) var revision: UInt64 = 0
    private(set) var lastDecodedCount = 0
    @ObservationIgnored private let store: StudioLibraryStore
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pendingReconcile = false
    @ObservationIgnored private var pendingFiles: Set<URL> = []
    let hudLimit: Int

    init(limit: Int = 60, store: StudioLibraryStore? = nil) {
        hudLimit = limit; self.store = store ?? StudioLibraryStore(limit: limit)
    }

    /// Repeated requests join one drain. Detached, uncancellable full builds are absent.
    func reload(changedFiles: [URL]? = nil) {
        if let changedFiles { pendingFiles.formUnion(changedFiles) }
        else { pendingReconcile = true }
        guard task == nil else { return }
        isLoading = true
        task = Task {
            while pendingReconcile || !pendingFiles.isEmpty {
                let reconcile = pendingReconcile
                let files = pendingFiles
                pendingReconcile = false; pendingFiles.removeAll()
                let snapshot = await store.update(changedFiles: reconcile ? nil : files, preview: { [weak self] snapshot in
                    await self?.publishPreview(snapshot)
                })
                if allNotes != snapshot.entries {
                    allNotes = snapshot.entries
                    indexMetadataNames()
                }
                notes = snapshot.recent
                lastDecodedCount = snapshot.decoded
                revision = snapshot.revision
            }
            isLoading = false; task = nil
        }
    }

    private func publishPreview(_ snapshot: StudioLibraryStore.Snapshot) {
        guard allNotes.isEmpty else { return }
        notes = snapshot.recent; allNotes = snapshot.entries
        indexMetadataNames()
    }

    private func indexMetadataNames() {
        notesByURLPath = StudioNoteLink.index(allNotes)
        notesByMetadataName = Dictionary(allNotes.map {
            ($0.metadataURL?.lastPathComponent ?? FileStore.metadataURL(forRecordingURL: $0.fileURL).lastPathComponent, $0)
        }, uniquingKeysWith: { first, _ in first })
    }

    func waitUntilLoaded() async { await task?.value }
}

extension Note {
    var studioTitle: String {
        displayTitle(fallback: studioTitleFallback)
    }

    /// Which transcript an audio note's text is right now, in the user's words:
    /// the live text until a file run replaces it, then that run's kind.
    var studioTranscriptLabel: String? {
        guard FileStore.isAudioFile(fileURL), insertableText != nil else { return nil }
        guard let provider = transcriptionProvider, !provider.isEmpty else { return "живой текст" }
        switch TranscriptKind.ofProvider(provider) {
        case .local: return "локальная"
        case .cloud: return "облачная"
        case .realtime, nil: return nil
        }
    }

    var hasFileTranscript: Bool { TranscriptKind.ofProvider(transcriptionProvider) != nil }

    /// Quiet type glyph for a saved note; red stays reserved for "recording now".
    var studioKindIcon: String {
        let ext = fileURL.pathExtension.lowercased()
        if FileStore.isAudioFile(fileURL) { return "mic.fill" }
        if AttachmentTypeHelper.imageExtensions.contains(ext) { return "photo" }
        if AttachmentTypeHelper.textExtensions.contains(ext) { return "text.alignleft" }
        return "doc"
    }

    private var studioTitleFallback: String {
        let ext = fileURL.pathExtension.lowercased()
        let type: String
        if FileStore.isAudioFile(fileURL) {
            type = "Аудиозапись"
        } else if AttachmentTypeHelper.imageExtensions.contains(ext) {
            type = "Изображение"
        } else if AttachmentTypeHelper.textExtensions.contains(ext) {
            type = "Заметка"
        } else {
            type = "Документ"
        }
        return "\(type) · \(absoluteDate.formatted(date: .omitted, time: .shortened))"
    }
}
