import ArgumentParser
import Foundation
import WimmDomain
import WimmInfrastructure

struct Meta: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Metadata tools",
        subcommands: [
            MetaValidate.self, MetaMigrateProcessed.self, MetaMigrateTxtStubs.self, MetaMigrateAttachments.self, MetaBackfillText.self, MetaLinkConversation.self,
        ]
    )
}

struct MetaLinkConversation: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "link-conversation",
        abstract: "Link a note's sidecar to the conversation and document section it replied to"
    )

    @Argument(help: "Recording file name or path")
    var file: String

    @Option(name: .long, help: "Origin source identifier (e.g. shoulders-conversation)")
    var source: String = "shoulders-conversation"

    @Option(name: .long, help: "Document relative path")
    var doc: String?

    @Option(name: .long, help: "Document section id")
    var section: String?

    @Option(name: .long, help: "Document section heading")
    var heading: String?

    @Option(name: .long, help: "Conversation session id")
    var conversationId: String?

    @Option(name: .long, help: "Relative path to the conversation transcript file")
    var conversationFile: String?

    @Option(name: .long, help: "Preceding dialogue turn(s) the user replied to")
    var prompt: String?

    func run() async throws {
        let expanded = (file as NSString).expandingTildeInPath
        let url: URL
        if expanded.contains("/") {
            url = URL(fileURLWithPath: expanded).standardizedFileURL
        } else {
            url = FileStore.recordingsDirectory().appendingPathComponent(expanded)
        }
        try RecallSidecar.linkConversation(
            forRecordingURL: url,
            source: source,
            doc: doc,
            section: section,
            heading: heading,
            conversationId: conversationId,
            conversationFile: conversationFile,
            prompt: prompt
        )
    }
}

struct MetaValidate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Validate .meta.json files"
    )

    @Flag(
        name: .long,
        help: "Attempt safe in-place fixes (legacy transcription/redundant keys/missing file)")
    var fix: Bool = false

    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false

    @Flag(name: .long, help: "Exit non-zero when warnings or errors are present")
    var strict: Bool = false

    func run() async throws {
        let service = MetadataAuditService()
        let report = await service.validateAll(fix: fix)

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            if let payload = String(data: data, encoding: .utf8) {
                print(payload)
            }
        } else {
            print("Meta validation complete.")
            print("Scanned: \(report.scannedFiles)")
            print("Warnings: \(report.warnings)")
            print("Errors: \(report.errors)")
            if fix {
                print("Fixed: \(report.fixed)")
            }
            if !report.issues.isEmpty {
                print("\nFindings:")
                for issue in report.issues.prefix(20) {
                    let mark = issue.fixed ? " (fixed)" : ""
                    print("- \(issue.file): \(issue.code) - \(issue.message)\(mark)")
                }
                if report.issues.count > 20 {
                    print("- ... and \(report.issues.count - 20) more")
                }
            }
        }

        if strict && (report.errors > 0 || report.warnings > 0) {
            throw ExitCode(1)
        }
    }
}
