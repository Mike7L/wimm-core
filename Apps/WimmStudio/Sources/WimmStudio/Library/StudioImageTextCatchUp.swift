import Foundation
import WimmDomain
import WimmInfrastructure

/// Reads the text of image notes (a HUD screenshot, a pasted or synced
/// picture) with on-device Vision, one at a time, right after the note is
/// saved and for recent ones at launch. Nothing leaves the Mac, so private
/// mode does not stop it. The result goes through
/// `AttachmentRepository.saveDocumentOCR`, as `wimm-cli ocr --apply` does; a
/// picture with no text gets an empty `ocr` entry, so it is not read again.
@MainActor
final class StudioImageTextCatchUp {
    /// Called with each note that got its text, so the library can refresh it.
    var onNoteRecognized: (@MainActor @Sendable (URL) -> Void)?

    private var pending: [URL] = []
    private var running = false

    /// Image notes older than this are not swept in at launch.
    nonisolated static let sweepDays = StudioTranscriptCatchUp.sweepDays

    func recognize(_ files: [URL]) {
        let fresh = files.filter { file in
            Self.needsText(file: file, meta: StudioTranscriptCatchUp.sidecar(of: file))
                && !pending.contains { $0.standardizedFileURL == file.standardizedFileURL }
        }
        guard !fresh.isEmpty else { return }
        pending += fresh
        run()
    }

    /// Recent image notes that were never read. The library listing, not the
    /// directory, decides what a note is: a recording's screenshot or a PDF
    /// preview shares its base name and is not one.
    func sweep() {
        Task.detached(priority: .utility) {
            let cutoff = Date().addingTimeInterval(-Double(Self.sweepDays) * 86_400)
            let files = await FileRepository().recordings(order: .descending).filter { file in
                guard let date = FileStore.recordingDateFromFileName(file), date >= cutoff else { return false }
                return Self.needsText(file: file, meta: StudioTranscriptCatchUp.sidecar(of: file))
            }
            await MainActor.run { [weak self] in self?.recognize(files) }
        }
    }

    /// An image note with no recognition result and no text of its own yet.
    nonisolated static func needsText(file: URL, meta: [String: Any]) -> Bool {
        guard DocumentImporter.imageExtensions.contains(file.pathExtension.lowercased()),
              !FileStore.isAttachmentFile(file), meta["ocr"] == nil else { return false }
        let texts = [
            meta[MetadataKey.transcription.rawValue] as? String,
            (meta[MetadataKey.transcription.rawValue] as? [String: Any])?["transcript"] as? String,
            (meta["document"] as? [String: Any])?["text"] as? String,
        ]
        return texts.allSatisfy { ($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func run() {
        guard !running, !pending.isEmpty else { return }
        running = true
        let file = pending.removeFirst()
        let notify = onNoteRecognized
        Task.detached(priority: .utility) { [weak self] in
            if await Self.read(file), let notify { await MainActor.run { notify(file) } }
            await self?.finished()
        }
    }

    private func finished() {
        running = false
        run()
    }

    /// True when the sidecar was written.
    private nonisolated static func read(_ file: URL) async -> Bool {
        let name = file.lastPathComponent
        // The note may have been read or deleted while it waited its turn.
        guard FileManager.default.fileExists(atPath: file.path),
              needsText(file: file, meta: StudioTranscriptCatchUp.sidecar(of: file)) else { return false }
        let startedAt = Date()
        do {
            let extraction = try await DocumentImporter(ocrEngine: .vision).extractDocumentText(for: file)
            let text = (extraction?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            await AttachmentRepository(metadataRepository: MetadataRepository()).saveDocumentOCR(
                for: file, text: text,
                provider: extraction?.provider ?? TextExtractionProvider.vision,
                model: extraction?.model ?? "VNRecognizeText",
                startedAt: startedAt)
            log("[ImageText] \(name): \(text.isEmpty ? "no text" : "\(text.count) chars")")
            return true
        } catch {
            log("[ImageText] \(name): FAILED \(error.localizedDescription)")
            return false
        }
    }
}
