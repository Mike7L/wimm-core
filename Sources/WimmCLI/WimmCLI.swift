import ArgumentParser
import Foundation

@main
struct WimmCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "WIMM (Where Is My Mind) Command Line Interface",
        subcommands: [
            List.self, Search.self, Notes.self, ImportCommand.self, Export.self, Interactive.self,
            Process.self, Queue.self, Doctor.self, Stats.self, Cost.self, Clean.self, Meta.self,
            Attachments.self, Transcript.self, OCR.self, Photos.self,
            Sync.self, AuditSilence.self, AuditTranscripts.self, SilenceMapCommand.self, Speakers.self,
            ProfileModels.self, Speak.self, TUI.self, MCP.self, MCPBuild.self, Depersonalize.self, Comments.self, Secretary.self, Doc.self,
        ],
        defaultSubcommand: List.self
    )
}
