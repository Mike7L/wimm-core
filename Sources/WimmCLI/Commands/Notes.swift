import ArgumentParser
import Foundation

struct Notes: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Note maintenance: split attachments, lost media, Voice Memos import, trash",
        subcommands: [NotesConvertAttachments.self, NotesSplitAttachments.self, NotesInheritSplitMarks.self, NotesLostToText.self, NotesImportVoiceMemos.self, NotesMergeVoiceMemosDuplicates.self, NotesFillVoiceMemosFields.self, NotesTrash.self]
    )
}
