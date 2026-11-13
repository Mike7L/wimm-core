import ArgumentParser
import Foundation
import WimmDomain
import WimmInfrastructure

struct MetaMigrateTxtStubs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "migrate-txt-stubs",
        abstract: "Migrate legacy .txt stub notes into document metadata and optionally remove .txt files"
    )

    @Flag(name: .long, help: "Apply changes (default is dry-run)")
    var apply: Bool = false

    @Flag(name: .long, help: "Delete migrated .txt stub files (works only with --apply)")
    var deleteTxt: Bool = false

    @Flag(name: .long, help: "Also migrate txt+non-txt pairs without explicit legacy markers")
    var aggressive: Bool = false

    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false

    func run() async throws {
        let fm = FileManager.default
        let recordingsDir = FileStore.recordingsDirectory()

        let metadataRepository = MetadataRepository()
        let attachmentRepository = AttachmentRepository(metadataRepository: metadataRepository)

        let all = try fm.contentsOfDirectory(at: recordingsDir, includingPropertiesForKeys: nil)
        let files = all.filter { $0.isFileURL && !$0.lastPathComponent.hasPrefix(".") }

        var byBase: [String: [URL]] = [:]
        for file in files {
            byBase[file.deletingPathExtension().lastPathComponent, default: []].append(file)
        }

        var report = TxtStubMigrationReport(
            dryRun: !apply,
            deleteTxt: deleteTxt,
            aggressive: aggressive
        )

        for file in files where file.pathExtension.lowercased() == "txt" {
            let base = file.deletingPathExtension().lastPathComponent
            let siblings = (byBase[base] ?? []).filter { $0 != file && isSupportedAnchor($0) && $0.pathExtension.lowercased() != "txt" }
            guard !siblings.isEmpty else { continue }

            guard let target = pickTarget(from: siblings) else { continue }
            report.scannedTxt += 1

            let meta = await metadataRepository.metadata(for: target)
            let card = await metadataRepository.existingNoteCard(for: target)
            let attachments = await attachmentRepository.attachments(for: target)
            let cardPointsToTxt = card?.note_file == file.lastPathComponent
            let hasProcessingStatus = meta[MetadataKey.processingStatus.rawValue] != nil
            let hasSourcePath = (meta[MetadataKey.sourcePath.rawValue] as? String)?.isEmpty == false
            let hasSelfAttachment = attachments.contains { $0.url.lastPathComponent == target.lastPathComponent }
            let likelyLegacy = cardPointsToTxt || hasProcessingStatus || hasSourcePath || hasSelfAttachment

            if !aggressive && !likelyLegacy {
                continue
            }

            let txtText = readTextFile(file)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let documentMeta = (meta[MetadataKey.document.rawValue] as? [String: Any]) ?? [:]
            let existingDocText = (documentMeta[MetadataKey.text.rawValue] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let shouldSetDocumentText = !txtText.isEmpty && existingDocText.isEmpty
            let shouldUpdateCardNoteFile = cardPointsToTxt
            let shouldDropSelfAttachment = hasSelfAttachment
            let shouldDeleteTxt = apply && deleteTxt

            let action = TxtStubMigrationAction(
                txtFile: file.lastPathComponent,
                targetFile: target.lastPathComponent,
                setDocumentText: shouldSetDocumentText,
                updateNoteFile: shouldUpdateCardNoteFile,
                removeSelfAttachment: shouldDropSelfAttachment,
                deleteTxt: shouldDeleteTxt
            )
            report.actions.append(action)

            if !apply {
                continue
            }

            if shouldSetDocumentText {
                var updatedDoc = documentMeta
                updatedDoc[MetadataKey.text.rawValue] = txtText
                if updatedDoc[MetadataKey.textProvider.rawValue] == nil {
                    updatedDoc[MetadataKey.textProvider.rawValue] = TextExtractionProvider.plainText
                }
                await metadataRepository.upsertMetadata(for: target, updates: [
                    MetadataKey.document.rawValue: updatedDoc
                ])
                report.updatedDocumentText += 1
            }

            if shouldUpdateCardNoteFile, var mutableCard = card {
                mutableCard.note_file = target.lastPathComponent
                await metadataRepository.upsertNoteCard(for: target, card: mutableCard, lang: mutableCard.lang)
                report.updatedNoteFileField += 1
            }

            if shouldDropSelfAttachment {
                let filtered = attachments.filter { $0.url.lastPathComponent != target.lastPathComponent }
                await attachmentRepository.upsertAttachments(for: target, attachments: filtered)
                report.cleanedSelfAttachments += 1
            }

            if shouldDeleteTxt {
                do {
                    try fm.removeItem(at: file)
                    report.deletedTxtFiles += 1
                } catch {
                    report.deleteErrors.append(TxtStubDeleteError(file: file.lastPathComponent, error: error.localizedDescription))
                }
            }
        }

        report.candidates = report.actions.count

        if json {
            try printJSON(report)
            return
        }

        print("TXT stub migration")
        print("Mode: \(apply ? "APPLY" : "DRY-RUN")")
        print("Scanned txt-with-sibling: \(report.scannedTxt)")
        print("Candidates: \(report.candidates)")
        print("Will/Did set document.text: \(apply ? report.updatedDocumentText : report.actions.filter { $0.setDocumentText }.count)")
        print("Will/Did update noteCard.note_file: \(apply ? report.updatedNoteFileField : report.actions.filter { $0.updateNoteFile }.count)")
        print("Will/Did remove self-attachments: \(apply ? report.cleanedSelfAttachments : report.actions.filter { $0.removeSelfAttachment }.count)")
        if deleteTxt {
            print("Will/Did delete txt files: \(apply ? report.deletedTxtFiles : report.actions.filter { $0.deleteTxt }.count)")
        }

        if !report.deleteErrors.isEmpty {
            print("Delete errors: \(report.deleteErrors.count)")
            for err in report.deleteErrors.prefix(20) {
                print("- \(err.file): \(err.error)")
            }
        }

        if !report.actions.isEmpty {
            print("\nSample actions:")
            for action in report.actions.prefix(20) {
                print("- \(action.txtFile) -> \(action.targetFile) [docText:\(action.setDocumentText) noteFile:\(action.updateNoteFile) selfAttach:\(action.removeSelfAttachment) delete:\(action.deleteTxt)]")
            }
            if report.actions.count > 20 {
                print("- ... and \(report.actions.count - 20) more")
            }
        }

        if !apply {
            print("\nRun with --apply to persist changes. Add --delete-txt to remove migrated .txt files.")
        }
    }

    private func isSupportedAnchor(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return FileStore.supportedAudioExtensions.contains(ext) || FileStore.supportedDocumentExtensions.contains(ext)
    }

    private func pickTarget(from siblings: [URL]) -> URL? {
        siblings.sorted { lhs, rhs in
            let lRank = targetRank(lhs)
            let rRank = targetRank(rhs)
            if lRank == rRank {
                return lhs.lastPathComponent < rhs.lastPathComponent
            }
            return lRank < rRank
        }.first
    }

    private func targetRank(_ url: URL) -> Int {
        switch url.pathExtension.lowercased() {
        case "m4a": return 0
        case "pdf": return 1
        case "heic": return 2
        case "png": return 3
        case "jpg", "jpeg": return 4
        default: return 10
        }
    }

    private func readTextFile(_ url: URL) -> String? {
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        if let text = try? String(contentsOf: url, encoding: .utf16) { return text }
        if let text = try? String(contentsOf: url, encoding: .isoLatin1) { return text }
        return nil
    }
}

private struct TxtStubMigrationAction: Codable {
    let txtFile: String
    let targetFile: String
    let setDocumentText: Bool
    let updateNoteFile: Bool
    let removeSelfAttachment: Bool
    let deleteTxt: Bool
}

private struct TxtStubDeleteError: Codable {
    let file: String
    let error: String
}

private struct TxtStubMigrationReport: Codable {
    let dryRun: Bool
    let deleteTxt: Bool
    let aggressive: Bool
    var scannedTxt: Int = 0
    var candidates: Int = 0
    var updatedDocumentText: Int = 0
    var updatedNoteFileField: Int = 0
    var cleanedSelfAttachments: Int = 0
    var deletedTxtFiles: Int = 0
    var deleteErrors: [TxtStubDeleteError] = []
    var actions: [TxtStubMigrationAction] = []
}

private func printJSON<T: Encodable>(_ payload: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(payload)
    if let output = String(data: data, encoding: .utf8) {
        print(output)
    }
}
