import ArgumentParser
import Foundation
import WimmInfrastructure

/// Local inspection through the same Core entry point as the Reader. Never
/// processes a note, saves metadata, archives a map, or calls a provider.
struct Depersonalize: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "depersonalize",
        abstract: "Preview depersonalized note/text locally (read-only, no model call)",
        discussion: "Names and organizations are masked only when marked sensitive in Vocabulary. "
            + "A successful preview is not a guarantee of anonymity. "
            + "Use --text-file - to read UTF-8 text from stdin."
    )

    @Argument(help: "Note path, filename, or ID (includes its analysis context and attachments)")
    var note: String?

    @Option(name: .long, help: "Read raw UTF-8 text instead of a note; '-' reads stdin")
    var textFile: String?

    @Flag(name: .long, help: "Print masked text/payload and inspection diagnostics as JSON (no reverse map)")
    var json = false

    func validate() throws {
        guard (note != nil) != (textFile != nil) else {
            throw ValidationError("Provide a note reference OR --text-file <path|->.")
        }
    }

    func run() async throws {
        let preview: PrivateEgressPreview
        if let textFile {
            let data = try textFile == "-"
                ? FileHandle.standardInput.readToEnd() ?? Data()
                : Data(contentsOf: fileURL(textFile))
            guard let text = String(data: data, encoding: .utf8) else {
                throw ValidationError("Input must be UTF-8 text.")
            }
            preview = try await NoteProcessor.shared.privateEgressPreview(text: text)
        } else if let note {
            let candidate = fileURL(note)
            var directory: ObjCBool = false
            let file: URL
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &directory) {
                guard !directory.boolValue else { throw ValidationError("Expected a note file, not a directory.") }
                file = candidate
            } else {
                let library = await LibraryRecallSource(buildMode: .inProcess).load()
                guard let found = NoteRecall.find(library, reference: note) else {
                    throw ValidationError("No single note matches the supplied reference.")
                }
                file = URL(fileURLWithPath: found.filePath)
            }
            preview = try await NoteProcessor.shared.privateEgressPreview(file: file)
        } else {
            throw ValidationError("Missing input.")
        }

        let suspects = PseudonymSuspects.find(inMasked: preview.maskedNoteText)
        if json {
            let report = Report(
                wouldSend: preview.wouldSend,
                text: preview.wouldSend ? preview.readableNoteText : nil,
                maskedUser: preview.wouldSend ? preview.maskedUser : nil,
                dictionaryTerms: preview.dictionaryTerms,
                maskedEntities: preview.legend.count,
                suspects: suspects.map { .init(surface: $0.surface, reason: $0.reason.rawValue, count: $0.count) },
                blockedKinds: preview.blockedKinds, refusal: preview.refusal)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
        } else if preview.wouldSend {
            print(preview.readableNoteText)
            diagnostic("Masked entities: \(preview.legend.count); possibly not hidden: \(suspects.count).")
        }

        guard preview.wouldSend else {
            diagnostic(preview.refusal ?? "Private-mode preview blocked: \(preview.blockedKinds.joined(separator: ", ")).")
            throw ExitCode.failure
        }
    }

    private func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    private func diagnostic(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private struct Report: Encodable {
        struct Suspect: Encodable {
            let surface: String
            let reason: String
            let count: Int
        }
        let wouldSend: Bool
        let text: String?
        let maskedUser: String?
        let dictionaryTerms: Int
        let maskedEntities: Int
        let suspects: [Suspect]
        let blockedKinds: [String]
        let refusal: String?
    }
}
