#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ImageIO
import WimmDomain

/// Standalone imports from the home screen: camera shots, gallery media,
/// files and clipboard content become individual journal items.
extension AppState {
    enum PasteOutcome {
        case imported
        case empty
    }

    /// Saves a written entry as the same .txt anchor and note card used by
    /// imported text, then publishes it locally before starting cloud sync.
    func createTextNote(_ text: String) async throws {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }

        try FileStore.ensureDirectoryExists()
        let allocation = Self.uniqueImportURL(fileExtension: "txt")
        let url = allocation.url
        try Data(body.utf8).write(to: url, options: .atomic)
        allocation.identity.persist(for: url)

        do {
            try RecordingMetadata(
                recordingURL: url,
                transcription: body,
                duration: 0,
                timestamp: Date(),
                isComplete: true
            ).save()
            NoteOrigin.stamp(url)
            let card = NoteCard(
                note_file: url.lastPathComponent,
                lang: nil,
                title: Self.extractTitle(from: body),
                summary: body,
                refined_text: body,
                refined_edited_at: Date()
            )
            await IOSRecordingRepository.shared.upsertNoteCard(for: url, card: card, lang: nil)
            await publishRecording(at: url)
            scheduleRecordingSync(for: url)
        } catch {
            _ = await IOSRecordingRepository.shared.moveToTrash(file: url)
            throw error
        }
    }

    /// Each image becomes its own note (one note = one media). Returns the
    /// new notes' files, in order.
    @discardableResult
    func importImages(_ images: [UIImage], quality: Double = 0.85) async -> [URL] {
        guard !images.isEmpty else { return [] }
        var saved: [URL] = []
        for image in images {
            guard let (data, ext) = Self.encodeImage(image, quality: quality) else { continue }
            let allocation = Self.uniqueImportURL(fileExtension: ext)
            let destination = allocation.url
            do {
                try data.write(to: destination, options: .atomic)
                allocation.identity.persist(for: destination)
                await persistImport(
                    fileURL: destination,
                    transcription: L10n.iOS.Capture.photo,
                    title: L10n.iOS.Capture.photo,
                    summary: ""
                )
                saved.append(destination)
            } catch {
                print("[QuickImport] Failed to save image: \(error)")
            }
        }
        await loadRecordings()
        return saved
    }

    /// Takes the PDF produced by the VisionKit document scanner and files it as
    /// a standalone journal item. The scanner writes into a temp directory, so
    /// the file is moved rather than copied.
    func importScannedDocument(_ sourceURL: URL) async {
        let allocation = Self.uniqueImportURL(fileExtension: sourceURL.pathExtension.isEmpty ? "pdf" : sourceURL.pathExtension)
        let destination = allocation.url
        do {
            try FileManager.default.moveItem(at: sourceURL, to: destination)
            allocation.identity.persist(for: destination)
            await persistImport(
                fileURL: destination,
                transcription: "",
                title: L10n.iOS.Recording.scannedDocument,
                summary: ""
            )
        } catch {
            print("[QuickImport] Failed to save scan: \(error)")
        }
        await loadRecordings()
    }

    /// Copies picked files into the recordings directory. Returns false when
    /// at least one file had an unsupported type and was skipped.
    func importFiles(_ urls: [URL]) async -> Bool {
        var allSupported = true
        for source in urls {
            let accessed = source.startAccessingSecurityScopedResource()
            defer {
                if accessed { source.stopAccessingSecurityScopedResource() }
            }

            let ext = source.pathExtension.lowercased()
            guard FileStore.supportedAudioExtensions.contains(ext)
                || FileStore.supportedDocumentExtensions.contains(ext)
            else {
                allSupported = false
                continue
            }

            let allocation = Self.uniqueImportURL(fileExtension: ext)
            let destination = allocation.url
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                allocation.identity.persist(for: destination)
                let text = Self.textPayload(at: destination)
                await persistImport(
                    fileURL: destination,
                    transcription: text,
                    title: source.deletingPathExtension().lastPathComponent,
                    summary: text
                )
            } catch {
                print("[QuickImport] Failed to copy \(source.lastPathComponent): \(error)")
            }
        }
        await loadRecordings()
        return allSupported
    }

    /// Files dropped by the share extension (Voice Memos, Photos, Files,
    /// shared links etc.) land here;
    /// drained on launch and on every foreground activation. The extension
    /// duplicates this path — keep in sync with ShareViewController.
    static func shareInboxDirectory() -> URL {
        StoragePaths.baseDirectory().appendingPathComponent("ShareInbox", isDirectory: true)
    }

    func drainShareInbox() async {
        guard !shareInboxDrainInFlight else { return }
        shareInboxDrainInFlight = true
        defer { shareInboxDrainInFlight = false }

        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(
            at: Self.shareInboxDirectory(), includingPropertiesForKeys: nil)) ?? []
        guard !files.isEmpty else { return }

        let sidecarSuffix = NoteShareSource.inboxSidecarSuffix
        var imported = false
        for source in files where !source.lastPathComponent.hasSuffix(sidecarSuffix) {
            let ext = source.pathExtension.lowercased()
            guard FileStore.supportedAudioExtensions.contains(ext)
                || FileStore.supportedDocumentExtensions.contains(ext)
            else {
                // Drop unsupported leftovers so they aren't re-scanned forever.
                try? fm.removeItem(at: source)
                continue
            }
            let allocation = Self.uniqueImportURL(fileExtension: ext)
            let destination = allocation.url
            do {
                try fm.moveItem(at: source, to: destination)
                allocation.identity.persist(for: destination)
                // Before persistImport, so the first sync already carries it.
                await stampShareSource(
                    for: destination,
                    inboxSidecar: URL(fileURLWithPath: source.path + sidecarSuffix)
                )
                let text = Self.textPayload(at: destination)
                await persistImport(
                    fileURL: destination,
                    transcription: text,
                    title: source.deletingPathExtension().lastPathComponent,
                    summary: text
                )
                imported = true
            } catch {
                print("[ShareInbox] Failed to import \(source.lastPathComponent): \(error)")
            }
        }
        // A sidecar whose file never arrived (the extension was killed between
        // the two moves) would otherwise sit here forever. Young ones may still
        // be waiting for their file.
        for sidecar in files where sidecar.lastPathComponent.hasSuffix(sidecarSuffix) {
            let primary = String(sidecar.path.dropLast(sidecarSuffix.count))
            guard !fm.fileExists(atPath: primary) else { continue }
            let modified = (try? sidecar.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(modified) > 600 {
                try? fm.removeItem(at: sidecar)
            }
        }
        if imported { await loadRecordings() }
    }

    /// Records where a shared item came from and when the original was made
    /// (`NoteShareSource`), from the extension's sidecar plus the file's own
    /// metadata. The sidecar is consumed either way.
    private func stampShareSource(for fileURL: URL, inboxSidecar: URL) async {
        defer { try? FileManager.default.removeItem(at: inboxSidecar) }
        let inbox = (try? Data(contentsOf: inboxSidecar))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let findings = await ShareSourceInspector.inspect(fileURL)
        let source = NoteShareSource(
            inbox: inbox,
            embeddedDate: findings.date,
            embeddedApp: findings.app
        )
        guard !source.isEmpty else { return }
        FileStore.upsertMetadata(
            for: fileURL,
            updates: [NoteShareSource.metadataKey: source.metadataValue]
        )
    }

    func importPasteboard() async -> PasteOutcome {
        let pasteboard = UIPasteboard.general

        if let images = pasteboard.images, !images.isEmpty {
            await importImages(images)
            return .imported
        }

        let text = (pasteboard.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            let allocation = Self.uniqueImportURL(fileExtension: "txt")
            let destination = allocation.url
            do {
                try Data(text.utf8).write(to: destination, options: .atomic)
                allocation.identity.persist(for: destination)
                await persistImport(
                    fileURL: destination,
                    transcription: text,
                    title: Self.extractTitle(from: text),
                    summary: text
                )
            } catch {
                print("[QuickImport] Failed to save pasted text: \(error)")
            }
            await loadRecordings()
            return .imported
        }

        return .empty
    }

    // MARK: - Shared plumbing

    private func persistImport(fileURL: URL, transcription: String, title: String, summary: String) async {
        let meta = RecordingMetadata(
            recordingURL: fileURL,
            transcription: transcription,
            duration: 0,
            timestamp: Date(),
            isComplete: true
        )
        do {
            try meta.save()
        } catch {
            print("[QuickImport] Failed to save metadata for \(fileURL.lastPathComponent): \(error)")
        }
        NoteOrigin.stamp(fileURL)

        let card = NoteCard(
            note_file: fileURL.lastPathComponent,
            lang: nil,
            title: title,
            summary: summary,
            refined_text: summary.isEmpty ? nil : summary
        )
        await IOSRecordingRepository.shared.upsertNoteCard(for: fileURL, card: card, lang: nil)
        // Upload in the background so the journal list refreshes as soon as
        // the file is on disk instead of waiting for the network round-trip.
        Task { await self.enqueueSync(for: fileURL) }
    }

    private static func uniqueImportURL(
        fileExtension: String
    ) -> (url: URL, identity: RecordingIdentity) {
        let identity = RecordingIdentity()
        return (
            FileStore.newRecordingURL(identity: identity, extension: fileExtension),
            identity
        )
    }

    /// Plain-text imports (shared links, notes, .md/.csv/.log files) carry their
    /// own content — surface it right away instead of leaving an empty note
    /// until some later pass fills it in. Binary formats return "".
    private static func textPayload(at url: URL) -> String {
        guard AttachmentTypeHelper.textExtensions.contains(url.pathExtension.lowercased()),
              let raw = try? String(contentsOf: url, encoding: .utf8)
        else {
            return ""
        }
        return String(raw.prefix(Self.textPayloadLimit))
    }

    /// Long logs would otherwise be duplicated wholesale into the note card.
    private static let textPayloadLimit = 20_000

    private static func extractTitle(from text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "Note" }
        let sentence = normalized.split(whereSeparator: { ".!?".contains($0) }).first.map(String.init) ?? normalized
        let title = String(sentence.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Note" : title
    }

    private static func encodeImage(_ image: UIImage, quality: Double) -> (data: Data, ext: String)? {
        if let heic = heicData(for: image, quality: quality) {
            return (heic, "heic")
        }
        if let jpeg = image.jpegData(compressionQuality: quality) {
            return (jpeg, "jpg")
        }
        return nil
    }

    private static func heicData(for image: UIImage, quality: Double) -> Data? {
        guard let cgImage = image.cgImage else { return nil }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil)
        else {
            return nil
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
#endif
