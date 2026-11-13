#if os(iOS)
import SwiftUI
import WimmDomain
import WimmInfrastructure
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

struct RecordingDetailView: View {
    let recording: Recording
    @EnvironmentObject private var appState: AppState
    @StateObject private var player = AudioPlayerController()
    @State private var attachments: [NoteAttachment] = []
    @State private var transcription: String = ""
    @State private var detailImage: UIImage?
    @State private var showPhotoViewer = false
    @State private var card: NoteCard?
    @State private var originText: String?
    @State private var shareSource: NoteShareSource?
    @State private var isEditing = false
    @State private var bodyDraft = ""
    @State private var saveError: String?
    @State private var reprocessError: String?
    @State private var transcriptVariants: [NoteTranscriptVariant] = []
    @FocusState private var editorFocused: Bool

    private var kind: NoteMediaKind {
        recording.mediaKind
    }

    private var fileExists: Bool {
        FileManager.default.fileExists(atPath: recording.fileURL.path)
    }

    /// The note body shown front and center: refined text when present,
    /// otherwise the raw transcription acts as the editable base. The first
    /// manual edit promotes it into refined_text.
    private var bodyText: String {
        if let refined = card?.refined_text, !refined.isEmpty {
            return refined
        }
        return transcription
    }

    private var isUserEdited: Bool {
        card?.refined_edited_at != nil
    }

    /// The photo importer stores a localized "Photo" placeholder as the
    /// transcription; repeating it under the image is noise. Real OCR text
    /// would differ from the title and still shows up.
    private func isPlaceholder(_ text: String) -> Bool {
        guard kind == .image else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == card?.title || trimmed == L10n.iOS.Capture.photo
    }

    /// Pasted text is saved as transcription, summary and refined_text at
    /// once — showing identical cards helps nobody.
    private var summaryText: String? {
        guard let summary = card?.summary, !summary.isEmpty else { return nil }
        return summary == bodyText ? nil : summary
    }

    private var navigationTitle: String {
        switch kind {
        case .audio: return L10n.iOS.Recording.title
        case .image: return L10n.iOS.Recording.titlePhoto
        case .text: return L10n.iOS.Recording.titleNote
        case .pdf, .document: return L10n.iOS.Recording.titleDocument
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                switch kind {
                case .pdf:
                    PDFViewer(url: recording.fileURL)
                        .frame(height: 500)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                case .image:
                    photoCard
                case .audio:
                    if fileExists {
                        playerCard
                    }
                case .text:
                    EmptyView()
                case .document:
                    documentCard
                }

                if isEditing || (!bodyText.isEmpty && !isPlaceholder(bodyText)) {
                    noteBodyCard
                }

                if kind == .audio, !visibleVariants.isEmpty {
                    TranscriptVariantsCard(variants: visibleVariants, bodyText: bodyText) { text in
                        Task { await useAsText(text) }
                    }
                }

                if !sources.isEmpty {
                    sourcesSection
                }

                if let card {
                    if let summaryText {
                        DetailCard(title: L10n.iOS.Recording.summary, systemImage: "text.alignleft") {
                            Text(summaryText)
                                .font(.body)
                                .textSelection(.enabled)
                        }
                    }

                    if let recommendation = card.agent_recommendation, !recommendation.isEmpty {
                        DetailCard(title: L10n.iOS.Recording.suggestedProject, systemImage: "lightbulb") {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(recommendation)
                                    .font(.body)
                                if let reason = card.agent_reason, !reason.isEmpty {
                                    Text(reason)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if !attachments.isEmpty {
                    DetailCard(title: L10n.iOS.Recording.attachments, systemImage: "paperclip") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(attachments) { attachment in
                                    AttachmentThumb(attachment: attachment)
                                }
                            }
                        }
                    }
                }

                DetailCard(title: L10n.iOS.Recording.details, systemImage: "info.circle") {
                    VStack(spacing: 10) {
                        LabeledContent(L10n.iOS.Recording.created) {
                            Text(recording.timestamp, style: .date)
                        }
                        Divider()
                        LabeledContent(L10n.iOS.Recording.time) {
                            Text(recording.timestamp, style: .time)
                        }
                        if kind == .audio, audioDuration > 0 {
                            Divider()
                            LabeledContent(L10n.iOS.Recording.duration) {
                                Text(formatDuration(audioDuration))
                                    .monospacedDigit()
                            }
                        }
                        if let originText {
                            Divider()
                            LabeledContent(L10n.iOS.Recording.device) {
                                Text(originText)
                            }
                        }
                        if let shareSource {
                            shareSourceRows(shareSource)
                        }
                    }
                    .font(.subheadline)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if !isEditing {
                    Button {
                        startEditing()
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .accessibilityLabel(L10n.iOS.Recording.edit)
                }
                ShareLink(item: recording.fileURL)
                if !isEditing, kind == .audio {
                    NoteReprocessMenu(
                        queue: appState.processingQueue,
                        url: recording.fileURL,
                        isAudio: kind == .audio,
                        onFinished: { await reloadNote() },
                        onError: { reprocessError = $0 }
                    )
                }
            }
        }
        .fullScreenCover(isPresented: $showPhotoViewer) {
            PhotoViewerScreen(url: recording.fileURL)
        }
        .alert(L10n.iOS.NewNote.saveFailed, isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button(L10n.Common.ok) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .alert(L10n.iOS.Reprocess.failedTitle, isPresented: Binding(
            get: { reprocessError != nil },
            set: { if !$0 { reprocessError = nil } }
        )) {
            Button(L10n.Common.ok) { reprocessError = nil }
        } message: {
            Text(reprocessError ?? "")
        }
        .task {
            await reloadNote()
            if kind == .image {
                let url = recording.fileURL
                detailImage = await Task.detached(priority: .userInitiated) {
                    ImageDownsampler.image(at: url, maxPixel: 1400)
                }.value
            }
        }
        .onDisappear {
            player.stop()
        }
    }

    /// Shared in from another app: where it came from and when the original
    /// was made. The rows above keep showing the import time.
    @ViewBuilder
    private func shareSourceRows(_ source: NoteShareSource) -> some View {
        if let label = source.displayString {
            Divider()
            LabeledContent(L10n.iOS.Recording.source) {
                if let url = source.url {
                    Link(label, destination: url)
                        .lineLimit(1)
                } else {
                    Text(label)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        if let date = source.date {
            Divider()
            LabeledContent(L10n.iOS.Recording.sourceDate) {
                Text(date.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    // MARK: - Re-run with external models

    private func reloadNote() async {
        let repository = IOSRecordingRepository()
        card = await repository.existingNoteCard(for: recording.fileURL) ?? recording.note
        attachments = await repository.attachments(for: recording.fileURL)
        if let meta = try? await repository.loadMetadata(for: recording.fileURL) {
            transcription = meta.transcription
        }
        let metadata = await repository.metadata(for: recording.fileURL)
        originText = NoteOrigin.displayString(
            metadata: metadata,
            fileName: recording.fileURL.lastPathComponent
        )
        shareSource = NoteShareSource(metadata: metadata)
        transcriptVariants = NoteTranscriptVariant.variants(fromSidecar: metadata)
            .map { $0.rendered(speakerLabel: L10n.Reader.NoteView.Variants.speakerLabel) }
    }

    /// A single transcript identical to the body tells the reader nothing.
    private var visibleVariants: [NoteTranscriptVariant] {
        let body = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        if transcriptVariants.count == 1, transcriptVariants[0].text == body { return [] }
        return transcriptVariants
    }

    /// "Use as text" on a transcription: an ordinary body edit, so it is
    /// marked edited and syncs like one.
    private func useAsText(_ text: String) async {
        bodyDraft = text
        await saveBodyEdit()
    }

    // MARK: - Note Body (editable refined text)

    private var noteBodyCard: some View {
        DetailCard(title: L10n.iOS.Recording.note, systemImage: "text.alignleft") {
            VStack(alignment: .leading, spacing: 10) {
                if isEditing {
                    TextEditor(text: $bodyDraft)
                        .focused($editorFocused)
                        .font(.body)
                        .frame(minHeight: 180)
                        .scrollContentBackground(.hidden)

                    HStack {
                        Button(L10n.iOS.Recording.cancel, role: .cancel) {
                            isEditing = false
                        }
                        Spacer()
                        Button(L10n.iOS.Recording.save) {
                            Task { await saveBodyEdit() }
                        }
                        .fontWeight(.semibold)
                        .disabled(bodyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .font(.subheadline)
                } else {
                    Text(bodyText)
                        .font(.body)
                        .textSelection(.enabled)

                    if isUserEdited {
                        Label(L10n.iOS.Recording.edited, systemImage: "pencil")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func startEditing() {
        let current = bodyText
        bodyDraft = isPlaceholder(current) ? "" : current
        isEditing = true
        editorFocused = true
    }

    private func saveBodyEdit() async {
        let text = bodyDraft
        // Nothing changed — don't promote an untouched transcription into
        // refined_text and don't lock it against reprocessing.
        guard text != bodyText else {
            isEditing = false
            return
        }

        if kind == .text {
            do {
                try text.write(to: recording.fileURL, atomically: true, encoding: .utf8)
                var metadata = try RecordingMetadata.load(for: recording.fileURL)
                metadata.transcription = text
                try metadata.save()
                transcription = text
            } catch {
                saveError = error.localizedDescription
                return
            }
        }

        var newCard: NoteCard
        if var existing = card ?? recording.note {
            existing.refined_text = text
            existing.refined_edited_at = Date()
            if kind == .text {
                existing.title = Self.extractTitle(from: text)
                existing.summary = text
            }
            newCard = existing
        } else {
            newCard = NoteCard(
                note_file: recording.fileURL.lastPathComponent,
                lang: nil,
                title: Self.extractTitle(from: text),
                summary: text,
                refined_text: text,
                refined_edited_at: Date()
            )
        }

        let repository = IOSRecordingRepository()
        await repository.upsertNoteCard(for: recording.fileURL, card: newCard, lang: newCard.lang)
        card = newCard
        isEditing = false

        await appState.enqueueSync(for: recording.fileURL)
        await appState.loadRecordings()
    }

    private static func extractTitle(from text: String) -> String {
        let firstLine = text
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return String(firstLine.trimmingCharacters(in: .whitespaces).prefix(60))
    }

    // MARK: - Sources (collapsed originals)

    struct NoteSource: Identifiable {
        let id: String
        let icon: String
        let title: String
        let fileName: String
        let fileURL: URL?
        let text: String
    }

    /// The raw material a note was built from: transcription, extracted
    /// document text, OCR of attachments. Shown collapsed below the body,
    /// and only when it actually differs from what the body already shows.
    private var sources: [NoteSource] {
        var result: [NoteSource] = []

        let raw = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasRefined = !(card?.refined_text ?? "").isEmpty
        let shownAsVariant = kind == .audio && !visibleVariants.isEmpty
        if !raw.isEmpty, hasRefined, raw != bodyText, !isPlaceholder(raw), !shownAsVariant {
            let (icon, title): (String, String)
            switch kind {
            case .audio:
                (icon, title) = ("waveform", L10n.iOS.Chat.transcription)
            case .image:
                (icon, title) = ("text.viewfinder", L10n.iOS.Recording.sourceOCR)
            case .text:
                (icon, title) = ("doc.text", L10n.iOS.Recording.text)
            case .pdf, .document:
                (icon, title) = ("doc.text", L10n.iOS.Recording.sourceDocument)
            }
            result.append(NoteSource(
                id: "primary",
                icon: icon,
                title: title,
                fileName: recording.fileURL.lastPathComponent,
                fileURL: fileExists ? recording.fileURL : nil,
                text: raw
            ))
        }

        for attachment in attachments {
            guard let extracted = attachment.extractedText?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !extracted.isEmpty
            else { continue }
            let exists = FileManager.default.fileExists(atPath: attachment.url.path)
            result.append(NoteSource(
                id: attachment.id.uuidString,
                icon: "text.viewfinder",
                title: L10n.iOS.Recording.sourceOCR,
                fileName: attachment.url.lastPathComponent,
                fileURL: exists ? attachment.url : nil,
                text: extracted
            ))
        }

        return result
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.iOS.Recording.sources, systemImage: "tray.full")
                .font(.footnote)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            ForEach(sources) { source in
                SourceDisclosureRow(source: source)
            }
        }
    }

    private var audioDuration: Double {
        player.duration > 0 ? player.duration : recording.durationSeconds
    }

    /// The photo itself is the note content: edge-to-edge card, tap to zoom.
    private var photoCard: some View {
        Group {
            if let detailImage {
                Button {
                    showPhotoViewer = true
                } label: {
                    Image(uiImage: detailImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .frame(height: 260)
                    .overlay {
                        if fileExists {
                            ProgressView()
                        } else {
                            Image(systemName: "photo")
                                .font(.system(size: 32))
                                .foregroundStyle(.secondary)
                        }
                    }
            }
        }
    }

    private var documentCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.fill")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(recording.fileURL.lastPathComponent)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                Text(recording.fileURL.pathExtension.uppercased())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var currentRecording: Recording {
        appState.recordings.first { $0.id == recording.id } ?? recording
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(currentRecording.displayTitle)
                .font(.title2)
                .fontWeight(.bold)
            Text(recording.timestamp.formatted(date: .abbreviated, time: .shortened))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var playerCard: some View {
        VStack(spacing: 14) {
            HStack(spacing: 28) {
                Button {
                    player.seek(to: max(0, player.currentTime - 15))
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 22, weight: .medium))
                }
                .disabled(player.duration <= 0)

                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 56))
                        .symbolRenderingMode(.hierarchical)
                }

                Button {
                    player.seek(to: min(player.duration, player.currentTime + 15))
                } label: {
                    Image(systemName: "goforward.15")
                        .font(.system(size: 22, weight: .medium))
                }
                .disabled(player.duration <= 0)

                Button {
                    player.skipSilence.toggle()
                } label: {
                    Image(systemName: player.skipSilence ? "forward.end.fill" : "forward.end")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(player.skipSilence ? Color.red : Color.secondary)
                }
                .accessibilityLabel("Skip silence")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)

            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { player.currentTime },
                        set: { player.seek(to: $0) }
                    ),
                    in: 0...max(player.duration, 0.01)
                )
                .disabled(player.duration <= 0)

                HStack {
                    Text(formatDuration(player.currentTime))
                    Spacer()
                    Text(formatDuration(player.duration > 0 ? player.duration : recording.durationSeconds))
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func togglePlayback() {
        if player.isPlaying {
            player.pause()
        } else {
            player.play(url: recording.fileURL)
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}
/// The note's ⋯ menu. Jobs go through the shared queue so they show up on
/// the Processing screen and outlive this view; the view only refreshes
/// itself if it is still on screen when its job ends.
private struct NoteReprocessMenu: View {
    @ObservedObject var queue: ProcessingQueue
    let url: URL
    let isAudio: Bool
    let onFinished: () async -> Void
    let onError: (String) -> Void

    var body: some View {
        if queue.isActive(url) {
            ProgressView()
                .accessibilityLabel(L10n.iOS.Reprocess.running)
        } else {
            Menu {
                if isAudio {
                    Button {
                        run(.transcribe)
                    } label: {
                        Label(L10n.iOS.Reprocess.retranscribe, systemImage: "waveform.badge.magnifyingglass")
                    }
                    Button {
                        run(.transcribeLocal)
                    } label: {
                        Label(L10n.iOS.Reprocess.retranscribeOnDevice, systemImage: "iphone")
                    }
                    // Audio cannot be masked: private mode never offers the cloud.
                    if !PrivateMode.isEnabled, let cloud = TranscriptKind.cloud.retranscriptionModel() {
                        Button {
                            run(.transcribeCloud)
                        } label: {
                            Label(L10n.iOS.Reprocess.retranscribeCloud(cloud), systemImage: "cloud")
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel(L10n.iOS.Reprocess.menu)
        }
    }

    private func run(_ kind: ProcessingJobKind) {
        Task { @MainActor in
            switch await queue.run(url, kind: kind) {
            case .failed(let message): onError(message)
            default: await onFinished()
            }
        }
    }
}
#endif
