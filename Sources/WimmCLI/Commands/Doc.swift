import ArgumentParser
import Foundation
import WimmInfrastructure
import WimmSecretary

/// Read-only access to a personal Markdown document for agents outside a secretary run
/// (Studio's "У меня вопрос" command). Same section rules as the secretary's addressed
/// reads. Prints JSON to stdout. Read subcommands refuse in private mode: the caller
/// sends the text to a cloud model. `replace-block` performs a local coordinated edit.
struct Doc: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doc",
        abstract: "Read or edit a personal document as JSON",
        subcommands: [Outline.self, Section.self, Find.self, ReplaceBlock.self]
    )

    struct Common: ParsableArguments {
        @Option(name: .long, help: "Path to the Markdown document")
        var document: String

        func text() throws -> String {
            guard !PrivateMode.isEnabled else {
                throw ValidationError("Private mode: document reads for cloud agents are refused.")
            }
            let url = URL(fileURLWithPath: (document as NSString).expandingTildeInPath)
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private struct ErrorPayload: Encodable {
        let code: String
        let error: String
    }

    static func printErrorJSON(code: String, error: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(ErrorPayload(code: code, error: error)) {
            FileHandle.standardError.write(data)
            FileHandle.standardError.write(Data("\n".utf8))
        }
    }

    struct Outline: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "All headings with block IDs and subtree sizes")
        @OptionGroup var common: Common
        func run() throws {
            try Doc.printJSON(["headings": SecretaryDocumentReader.outline(document: try common.text())])
        }
    }

    struct Section: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "One section with its subsections, paged by whole blocks")
        @OptionGroup var common: Common
        @Argument(help: "Heading block ID (b12) or exact heading title")
        var query: String
        @Option(name: .long, help: "First block of the page (from next_offset)") var offset = 0
        @Option(name: .long, help: "Maximum UTF-8 bytes per page (at least one block is returned)") var limitBytes = 24_000
        func run() throws {
            try Doc.printJSON(SecretaryDocumentReader.section(document: try common.text(), query: query,
                                                              offset: offset, byteLimit: limitBytes))
        }
    }

    struct Find: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Blocks matching a phrase or terms (secretary search)")
        @OptionGroup var common: Common
        @Argument(help: "Literal phrase or words to look for")
        var query: String
        @Option(name: .long, help: "Maximum UTF-8 bytes of returned blocks") var limitBytes = 24_000
        func run() throws {
            try Doc.printJSON(SecretaryDocumentReader.find(document: try common.text(), query: query, byteLimit: limitBytes))
        }
    }

    struct ReplaceBlock: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "replace-block",
            abstract: "Replace one block inside a coordinated write, verifying the file's SHA-256"
        )

        @Option(name: .long, help: "Path to the Markdown document")
        var document: String

        @Option(name: .long, help: "0-based PersonalDocument block ID to replace")
        var blockId: Int

        @Option(name: .long, help: "Expected SHA-256 hex digest of the current file")
        var expectedSha256: String

        @Option(name: .long, help: "Expected SHA-256 hex digest of the target block's current Markdown")
        var expectedBlockSha256: String

        private struct Result: Encodable {
            let ok: Bool
            let sha256: String
        }

        func run() async throws {
            let expected = expectedSha256.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !expected.isEmpty else {
                Doc.printErrorJSON(code: "invalid_input", error: "expected-sha256 must not be empty")
                throw ExitCode(2)
            }
            let expectedBlock = expectedBlockSha256.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !expectedBlock.isEmpty else {
                Doc.printErrorJSON(code: "invalid_input", error: "expected-block-sha256 must not be empty")
                throw ExitCode(2)
            }
            let stdinData = FileHandle.standardInput.readDataToEndOfFile()
            guard let markdown = String(data: stdinData, encoding: .utf8) else {
                Doc.printErrorJSON(code: "invalid_input", error: "stdin must be valid UTF-8")
                throw ExitCode(2)
            }
            let url = URL(fileURLWithPath: (document as NSString).expandingTildeInPath).standardizedFileURL
            let store = PersonalDocumentStore(url: url)
            do {
                let newSHA256 = try await store.replaceBlock(
                    id: blockId,
                    with: markdown,
                    expectingSHA256: expected,
                    expectingBlockSHA256: expectedBlock
                )
                try Doc.printJSON(Result(ok: true, sha256: newSHA256))
            } catch PersonalDocumentError.changedOnDisk {
                Doc.printErrorJSON(code: "changed_on_disk", error: PersonalDocumentError.changedOnDisk.localizedDescription)
                throw ExitCode(3)
            } catch PersonalDocumentError.blockNotFound(let id) {
                Doc.printErrorJSON(code: "block_not_found", error: "Block \(id) not found")
                throw ExitCode(4)
            } catch {
                Doc.printErrorJSON(code: "io_error", error: error.localizedDescription)
                throw ExitCode(1)
            }
        }
    }
}
