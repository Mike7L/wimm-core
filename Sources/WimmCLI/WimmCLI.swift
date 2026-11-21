import ArgumentParser
import Foundation

@main
struct WimmCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "WIMM (Where Is My Mind) Command Line Interface",
        subcommands: [
            Notes.self, Export.self, Doctor.self, Stats.self, Cost.self, Clean.self, Meta.self,
            Attachments.self, Transcript.self, OCR.self, Photos.self,
            Sync.self, AuditSilence.self, AuditTranscripts.self, SilenceMapCommand.self, Speakers.self,
            ProfileModels.self, Speak.self, MCP.self, MCPBuild.self, Inbox.self, Comments.self, Secretary.self, Doc.self,
        ]
    )
}
