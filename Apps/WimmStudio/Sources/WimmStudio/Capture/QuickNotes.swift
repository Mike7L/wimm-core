import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WimmDomain
import WimmInfrastructure

/// One-click notes from the HUD: a screenshot of the screen under the
/// pointer, or whatever is on the clipboard. Each becomes an ordinary library
/// note (`RecordingIdentity` sidecar + file in the recordings directory),
/// independent of a running recording.
@MainActor
enum QuickNotes {
    enum Failure: LocalizedError {
        case screenshotFailed
        case emptyClipboard

        var errorDescription: String? {
            switch self {
            case .screenshotFailed: "Screenshot failed (Screen Recording permission?)"
            case .emptyClipboard: "Clipboard has nothing to save"
            }
        }
    }

    /// Captures the display under the pointer with `screencapture`, hiding
    /// the HUD for the shot.
    static func screenshot() async throws -> URL {
        let url = try newNoteURL(extension: "heic")
        CaptureSoundFeedback.start()
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("wimm-screenshot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let display = (NSScreen.screens.firstIndex { $0.frame.contains(NSEvent.mouseLocation) } ?? 0) + 1
        let hud = NSApp.windows.compactMap { $0 as? ResponsiveHUDPanel }.filter(\.isVisible).map { ($0, $0.alphaValue) }
        hud.forEach { $0.0.alphaValue = 0 }
        defer { hud.forEach { $0.0.alphaValue = $0.1 } }
        // Let the window server drop the HUD from the frame before the shot.
        try? await Task.sleep(for: .milliseconds(120))
        let status = await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-t", "png", "-D\(display)", temporary.path]
            do { try process.run() } catch { return Int32(-1) }
            process.waitUntilExit()
            return process.terminationStatus
        }.value
        guard status == 0, saveScreenshot(from: temporary, to: url) else {
            // Drop the sidecar `newNoteURL` just wrote, or it lingers as an orphan.
            try? FileManager.default.removeItem(at: FileStore.metadataURL(forRecordingURL: url))
            try? FileManager.default.removeItem(at: url)
            throw Failure.screenshotFailed
        }
        FileStore.upsertMetadata(for: url, updates: ["title": "Screenshot", "origin": ["source": "studio-screenshot"]])
        CaptureSoundFeedback.finish()
        return url
    }

    /// Match Wimm's screenshot storage: HEIC at 0.8, preserving pixel dimensions.
    static func saveScreenshot(from source: URL, to destination: URL) -> Bool {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(input, 0, nil),
              let output = CGImageDestinationCreateWithURL(
                destination as CFURL, UTType.heic.identifier as CFString, 1, nil
              ) else { return false }
        CGImageDestinationAddImage(output, image, [
            kCGImageDestinationLossyCompressionQuality: 0.8,
        ] as CFDictionary)
        return CGImageDestinationFinalize(output)
    }

    /// Saves the clipboard as notes: copied files of a supported type, else an
    /// image, else text.
    static func pasteClipboard() throws -> [URL] {
        let board = NSPasteboard.general
        let urls: [URL]
        let files = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { FileStore.isSupportedRecordingFile($0) }
        if !files.isEmpty {
            urls = try files.map { source in
                let url = try newNoteURL(extension: source.pathExtension.lowercased())
                try FileManager.default.copyItem(at: source, to: url)
                FileStore.upsertMetadata(for: url, updates: [
                    "title": source.deletingPathExtension().lastPathComponent,
                    "origin": ["source": "studio-clipboard", "file": source.lastPathComponent],
                ])
                return url
            }
        } else if let image = NSImage(pasteboard: board), let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let url = try newNoteURL(extension: "png")
            try png.write(to: url, options: .atomic)
            FileStore.upsertMetadata(for: url, updates: ["title": "Pasted image", "origin": ["source": "studio-clipboard"]])
            urls = [url]
        } else {
            let text = (board.string(forType: .string) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw Failure.emptyClipboard }
            let url = try newNoteURL(extension: "txt")
            try Data(text.utf8).write(to: url, options: .atomic)
            let firstLine = String(text.split(whereSeparator: \.isNewline).first ?? Substring(text)).prefix(80)
            FileStore.upsertMetadata(for: url, updates: ["title": String(firstLine), "origin": ["source": "studio-clipboard"]])
            urls = [url]
        }
        return urls
    }

    /// A typed text note.
    static func saveText(_ text: String, title: String, source: String) throws -> URL {
        let url = try newNoteURL(extension: "txt")
        try Data(text.utf8).write(to: url, options: .atomic)
        FileStore.upsertMetadata(for: url, updates: ["title": title, "origin": ["source": source]])
        return url
    }

    private static func newNoteURL(extension ext: String) throws -> URL {
        try FileStore.ensureDirectoryExists()
        try FileManager.default.createDirectory(at: FileStore.recordingsDirectory(), withIntermediateDirectories: true)
        let identity = RecordingIdentity()
        let url = FileStore.newRecordingURL(identity: identity, extension: ext)
        identity.persist(for: url)
        return url
    }
}
