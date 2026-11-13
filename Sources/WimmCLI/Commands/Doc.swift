import ArgumentParser
import Foundation
import WimmInfrastructure
import WimmSecretary

/// Read-only access to a personal Markdown document for agents outside a secretary run
/// (Studio's "У меня вопрос" command). Same section rules as the secretary's addressed
/// reads. Prints JSON to stdout. Refuses in private mode: the caller sends the text to a
/// cloud model.
struct Doc: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doc",
        abstract: "Read a personal document's outline, sections and search hits as JSON",
        subcommands: [Outline.self, Section.self, Find.self]
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
}
