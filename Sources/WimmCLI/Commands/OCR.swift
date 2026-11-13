import ArgumentParser
import Foundation
import ImageIO
import WimmDomain
import WimmInfrastructure

struct OCR: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Extract text and scene descriptions from images and PDF files using OCR"
    )

    @Argument(help: "Path to the file to process (PDF, HEIC, PNG, JPG, etc.)")
    var path: String?

    @Option(name: .long, help: "Process the most recent N notes with photos in the library")
    var recent: Int?

    @Flag(name: .long, help: "Persist the OCR results into note sidecars (archiving previous runs in previousRuns)")
    var apply: Bool = false

    @Option(name: .long, help: "Limit number of OCR pages for PDF files")
    var maxPages: Int = 50

    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false

    mutating func run() async throws {
        if let recent {
            guard recent >= 1 else {
                throw ValidationError("--recent must be at least 1")
            }
            try await runRecentPhotoNotes(limit: recent)
            return
        }

        guard let path else {
            throw ValidationError("Provide a file <path> or --recent <N>")
        }

        let filePath = (path as NSString).expandingTildeInPath
        let fileURL = URL(fileURLWithPath: filePath).standardizedFileURL

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ValidationError("File not found: \(fileURL.path)")
        }

        let ext = fileURL.pathExtension.lowercased()
        let supportedExtensions = Set(["pdf", "heic", "png", "jpg", "jpeg", "tif", "tiff", "bmp", "webp", "gif"])
        guard supportedExtensions.contains(ext) else {
            throw ValidationError(
                "Unsupported file type: \(ext). Supported: pdf, heic, png, jpg, jpeg, tif, tiff, bmp, webp, gif"
            )
        }

        let importer = DocumentImporter()
        let startedAt = Date()

        do {
            guard
                let extraction = try await importer.extractDocumentText(
                    for: fileURL,
                    allowOCR: true,
                    maxPDFOCRPages: max(1, maxPages)
                )
            else {
                if json {
                    let result = OCRResult(
                        file: fileURL.lastPathComponent, text: "", provider: nil, model: nil,
                        pageCount: nil, error: "No text extracted")
                    try printJSON(result)
                } else {
                    print("No text could be extracted from \(fileURL.lastPathComponent)")
                }
                return
            }

            let text = extraction.text.trimmingCharacters(in: .whitespacesAndNewlines)

            if apply, !text.isEmpty {
                let attachmentRepo = AttachmentRepository(metadataRepository: MetadataRepository())
                await attachmentRepo.saveDocumentOCR(
                    for: fileURL,
                    text: text,
                    provider: extraction.provider,
                    model: extraction.model ?? "VNRecognizeText",
                    startedAt: startedAt
                )
            }

            if json {
                let result = OCRResult(
                    file: fileURL.lastPathComponent,
                    text: text,
                    provider: extraction.provider,
                    model: extraction.model,
                    pageCount: extraction.pageCount,
                    error: nil
                )
                try printJSON(result)
            } else {
                print("File: \(fileURL.lastPathComponent)")
                print("Provider: \(extraction.provider)")
                if let model = extraction.model {
                    print("Model: \(model)")
                }
                if let pageCount = extraction.pageCount {
                    print("Pages: \(pageCount)")
                }
                print("Text length: \(text.count) chars")
                print("---")
                print(text)
            }
        } catch {
            if json {
                let result = OCRResult(
                    file: fileURL.lastPathComponent, text: "", provider: nil, model: nil,
                    pageCount: nil, error: error.localizedDescription)
                try printJSON(result)
            } else {
                print("OCR failed: \(error.localizedDescription)")
            }
            throw ExitCode(1)
        }
    }

    // MARK: - Batch Recent Photo Notes

    private struct PhotoTarget {
        enum Kind {
            case standaloneNote
            case screenshotOfAudio
            case attachment(UUID)
        }
        let noteURL: URL
        let imageURL: URL
        let kind: Kind
    }

    private struct NoteCandidate {
        let noteURL: URL
        let sortDate: Date
        let targets: [PhotoTarget]
    }

    private func runRecentPhotoNotes(limit: Int) async throws {
        let fileRepo = FileRepository()
        let allNotes = await fileRepo.recordings(order: .descending)
        let fm = FileManager.default

        var candidates: [NoteCandidate] = []
        for noteURL in allNotes {
            let sidecarURL = FileStore.metadataURL(forRecordingURL: noteURL)
            let root = (try? Data(contentsOf: sidecarURL))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

            var targets: [PhotoTarget] = []
            var seenImagePaths = Set<String>()
            let ext = noteURL.pathExtension.lowercased()

            if NoteAttachmentMedia.imageExtensions.contains(ext),
               fm.fileExists(atPath: noteURL.path) {
                targets.append(PhotoTarget(noteURL: noteURL, imageURL: noteURL, kind: .standaloneNote))
                seenImagePaths.insert(noteURL.standardizedFileURL.path)
            }

            for item in NoteAttachmentMedia.items(in: root) where item.isImage {
                let standardized = item.url.standardizedFileURL.path
                guard !seenImagePaths.contains(standardized),
                      fm.fileExists(atPath: item.url.path)
                else { continue }
                targets.append(PhotoTarget(noteURL: noteURL, imageURL: item.url, kind: .attachment(item.id)))
                seenImagePaths.insert(standardized)
            }

            if FileStore.isAudioFile(noteURL) {
                let screenURL = FileStore.screenshotURL(forRecordingURL: noteURL)
                let standardized = screenURL.standardizedFileURL.path
                if !seenImagePaths.contains(standardized),
                   fm.fileExists(atPath: screenURL.path) {
                    targets.append(PhotoTarget(noteURL: noteURL, imageURL: screenURL, kind: .screenshotOfAudio))
                    seenImagePaths.insert(standardized)
                }
            }

            guard !targets.isEmpty else { continue }
            let sortDate = Self.noteDate(for: noteURL, sidecar: root)
            candidates.append(NoteCandidate(noteURL: noteURL, sortDate: sortDate, targets: targets))
        }

        candidates.sort { a, b in
            if a.sortDate != b.sortDate { return a.sortDate > b.sortDate }
            return a.noteURL.lastPathComponent > b.noteURL.lastPathComponent
        }

        let selected = Array(candidates.prefix(limit))
        let totalImages = selected.reduce(0) { $0 + $1.targets.count }
        print("Recent photo notes OCR\(apply ? " [apply]" : " [dry-run]")")
        print("Matched notes: \(selected.count) (requested: \(limit), total in library: \(candidates.count))")
        print("Total photos across selected notes: \(totalImages)")

        let importer = DocumentImporter(ocrEngine: .vision)
        let attachmentRepo = AttachmentRepository(metadataRepository: MetadataRepository())
        var succeeded = 0
        var empty = 0
        var failed = 0
        var sceneCount = 0
        var docCount = 0

        for (noteIdx, candidate) in selected.enumerated() {
            for target in candidate.targets {
                let startedAt = Date()
                let imgName = target.imageURL.lastPathComponent
                do {
                    if try Self.isTooSmallToRead(target.imageURL) {
                        empty += 1
                        continue
                    }
                    let text = try await importer.extractTextFromImage(at: target.imageURL)
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        empty += 1
                    } else {
                        succeeded += 1
                        if trimmed.hasPrefix("[scene:") {
                            sceneCount += 1
                        } else {
                            docCount += 1
                        }
                    }

                    if apply {
                        switch target.kind {
                        case .attachment(let attachmentID):
                            _ = try NoteAttachmentMedia.setText(
                                trimmed,
                                provider: TextExtractionProvider.vision,
                                model: "VNRecognizeText",
                                attachmentID: attachmentID,
                                ofNote: candidate.noteURL,
                                emptyIsNoSpeech: false
                            )
                        case .standaloneNote:
                            await attachmentRepo.saveDocumentOCR(
                                for: candidate.noteURL,
                                text: trimmed,
                                provider: TextExtractionProvider.vision,
                                model: "VNRecognizeText",
                                startedAt: startedAt
                            )
                        case .screenshotOfAudio:
                            await attachmentRepo.saveOCR(
                                for: candidate.noteURL,
                                text: trimmed,
                                provider: TextExtractionProvider.vision,
                                model: "VNRecognizeText",
                                startedAt: startedAt
                            )
                        }
                    }

                    let preview = trimmed
                        .replacingOccurrences(of: "\n", with: " ⏎ ")
                    let snippet = preview.count > 120 ? String(preview.prefix(120)) + "…" : preview
                    print("[\(noteIdx + 1)/\(selected.count)] \(candidate.noteURL.lastPathComponent) -> \(imgName) (\(trimmed.count) chars): \(snippet.isEmpty ? "(empty)" : snippet)")
                } catch {
                    failed += 1
                    print("[\(noteIdx + 1)/\(selected.count)] \(candidate.noteURL.lastPathComponent) -> \(imgName): FAILED \(error.localizedDescription)")
                }
            }
        }

        print("---")
        print("Done: \(succeeded) with output (documents: \(docCount), scene/mixed: \(sceneCount)), \(empty) empty, \(failed) failed.")
        if failed > 0 { throw ExitCode.failure }
    }

    private static func noteDate(for noteURL: URL, sidecar: [String: Any]) -> Date {
        if let ts = sidecar["timestamp"] as? Double, ts > 0 {
            return Date(timeIntervalSince1970: ts)
        }
        if let tsStr = sidecar["timestamp"] as? String, let date = ISO8601.parseEither(tsStr) {
            return date
        }
        // Parse Wimm_YYYY-MM-DD_HH-mm-ss prefix if present
        let name = noteURL.deletingPathExtension().lastPathComponent
        let parts = name.split(separator: "_")
        if parts.count >= 3, parts[0] == "Wimm" {
            let dateStr = "\(parts[1])_\(parts[2])"
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            if let d = df.date(from: dateStr) {
                return d
            }
        }
        if let mtime = (try? noteURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            return mtime
        }
        return .distantPast
    }

    private static func isTooSmallToRead(_ url: URL) throws -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path]) }
        return min(width, height) < 8
    }
}

private struct OCRResult: Encodable {
    let file: String
    let text: String
    let provider: String?
    let model: String?
    let pageCount: Int?
    let error: String?
}

private func printJSON<T: Encodable>(_ payload: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(payload)
    if let output = String(data: data, encoding: .utf8) {
        print(output)
    }
}
