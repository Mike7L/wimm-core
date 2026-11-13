import Foundation
import WimmDomain

/// Type-safe accessors for localized strings.
/// This file mimics what tools like SwiftGen generate.

private class BundleToken {}

private let l10nBundle: Bundle = {
    let bundleName = "Wimm_Wimm"
    
    let candidates = [
        Bundle.main.resourceURL,
        Bundle(for: BundleToken.self).resourceURL,
        Bundle.main.bundleURL,
        Bundle.main.resourceURL?.appendingPathComponent("Resources")
    ]
    
    for candidate in candidates {
        let bundlePath = candidate?.appendingPathComponent(bundleName + ".bundle")
        if let bundle = bundlePath.flatMap(Bundle.init(url:)) {
            return bundle
        }
    }
    
    if Bundle.main.path(forResource: "Localizable", ofType: "strings") != nil ||
       Bundle.main.path(forResource: "en", ofType: "lproj") != nil {
        return .main
    }
    
#if SWIFT_PACKAGE
    return .module
#else
    return .main
#endif
}()

@inline(__always)
private func NSLocalizedString(_ key: String, comment: String) -> String {
    Foundation.NSLocalizedString(key, tableName: nil, bundle: l10nBundle, value: key, comment: comment)
}

internal enum L10n {
    internal enum SpeechLabel {
        static let menu = NSLocalizedString("speech_label.menu", comment: "Recording speech label menu")
        static let automatic = NSLocalizedString("speech_label.automatic", comment: "Clear manual correction")
        static let unknown = NSLocalizedString("speech_label.unknown", comment: "Speech not classified yet")
        static let saveFailed = NSLocalizedString("speech_label.save_failed", comment: "Could not save label")
        static func title(_ label: AudioSpeechLabel) -> String {
            switch label {
            case .noSpeech: NSLocalizedString("speech_label.no_speech", comment: "Recording speech label")
            case .owner: NSLocalizedString("speech_label.owner", comment: "Recording speech label")
            case .onePerson: NSLocalizedString("speech_label.one_person", comment: "Recording speech label")
            case .twoPeople: NSLocalizedString("speech_label.two_people", comment: "Recording speech label")
            case .threeOrMore: NSLocalizedString("speech_label.three_or_more", comment: "Recording speech label")
            }
        }
    }
    internal enum PersonalDocument {
        static let title = NSLocalizedString("personal_document.title", comment: "Personal document window")
        static let choose = NSLocalizedString("personal_document.choose", comment: "Choose Markdown file")
        static let chooseDescription = NSLocalizedString("personal_document.choose_description", comment: "Empty window")
        static let fromMac = NSLocalizedString("personal_document.from_mac", comment: "iOS: show the copy the Mac publishes")
        static let notSyncedYet = NSLocalizedString("personal_document.not_synced_yet", comment: "iOS: no copy from the Mac yet")
        static func syncedFromMac(_ when: String) -> String {
            String(format: NSLocalizedString("personal_document.synced_from_mac", comment: "iOS: when the Mac published the copy"), when)
        }
        static let unsorted = NSLocalizedString("personal_document.unsorted", comment: "Unsorted notes heading")
        static let emptyInbox = NSLocalizedString("personal_document.empty_inbox", comment: "Empty unsorted section")
        static let saved = NSLocalizedString("personal_document.saved", comment: "Save status")
        static let pending = NSLocalizedString("personal_document.pending", comment: "Pending save status")
        static let conflict = NSLocalizedString("personal_document.conflict", comment: "External edit conflict")
        static let retry = NSLocalizedString("personal_document.retry", comment: "Retry action")
        static let saveCopy = NSLocalizedString("personal_document.save_copy", comment: "Save draft copy")
        static let reload = NSLocalizedString("personal_document.reload", comment: "Reload document")
        static let reveal = NSLocalizedString("personal_document.reveal", comment: "Reveal file in Finder")
        static let edit = NSLocalizedString("personal_document.edit", comment: "Edit paragraph")
        static let editHint = NSLocalizedString("personal_document.edit_hint", comment: "Inline editor hint")
        static let done = NSLocalizedString("personal_document.done", comment: "Finish editing")
        static let sources = NSLocalizedString("personal_document.sources", comment: "Paragraph sources")
        static let about = NSLocalizedString("personal_document.about", comment: "Editorial preamble")
        static let image = NSLocalizedString("personal_document.image", comment: "Image from a note")
        static let zoomIn = NSLocalizedString("personal_document.zoom_in", comment: "Document text zoom in")
        static let zoomOut = NSLocalizedString("personal_document.zoom_out", comment: "Document text zoom out")
        static let zoomReset = NSLocalizedString("personal_document.zoom_reset", comment: "Document text zoom reset")

        enum Speech {
            static let readFromHere = NSLocalizedString("personal_document.speech.read_from_here", comment: "Read aloud from this paragraph and continue")
            static let readDocument = NSLocalizedString("personal_document.speech.read_document", comment: "Read document aloud from the beginning")
            static let stop = NSLocalizedString("personal_document.speech.stop", comment: "Stop reading aloud")
        }

        enum Comments {
            static let add = NSLocalizedString("personal_document.comments.add", comment: "React to the selection (opens the reaction bar)")
            static let custom = NSLocalizedString("personal_document.comments.custom", comment: "Custom reaction: a comment in own words")
            static let customHelp = NSLocalizedString("personal_document.comments.custom_help", comment: "Custom reaction help")
            static let reactionAgree = NSLocalizedString("personal_document.comments.reaction_agree", comment: "Reaction: correct")
            static let reactionWrong = NSLocalizedString("personal_document.comments.reaction_wrong", comment: "Reaction: wrong")
            static let reactionUnclear = NSLocalizedString("personal_document.comments.reaction_unclear", comment: "Reaction: unclear")
            static let reactionExpand = NSLocalizedString("personal_document.comments.reaction_expand", comment: "Reaction: expand")
            static let reactionTrim = NSLocalizedString("personal_document.comments.reaction_trim", comment: "Reaction: remove")
            static let reactionImportant = NSLocalizedString("personal_document.comments.reaction_important", comment: "Reaction: important")
            static let statusOpen = NSLocalizedString("personal_document.comments.status_open", comment: "Thread status")
            static let statusAnswered = NSLocalizedString("personal_document.comments.status_answered", comment: "Thread status")
            static let statusApplied = NSLocalizedString("personal_document.comments.status_applied", comment: "Thread status")
            static let statusResolved = NSLocalizedString("personal_document.comments.status_resolved", comment: "Thread status")
            static let statusDropped = NSLocalizedString("personal_document.comments.status_dropped", comment: "Thread status")
            static let authorOwner = NSLocalizedString("personal_document.comments.author_owner", comment: "Comment author: the owner")
            static let authorSecretary = NSLocalizedString("personal_document.comments.author_secretary", comment: "Comment author: the secretary")
            static let placeholder = NSLocalizedString("personal_document.comments.placeholder", comment: "Comment field")
            static let replyPlaceholder = NSLocalizedString("personal_document.comments.reply_placeholder", comment: "Reply field")
            static let secretaryHint = NSLocalizedString("personal_document.comments.secretary_hint", comment: "Composer footnote")
            static let send = NSLocalizedString("personal_document.comments.send", comment: "Send comment")
            static let cancel = NSLocalizedString("personal_document.comments.cancel", comment: "Cancel comment")
            static let reply = NSLocalizedString("personal_document.comments.reply", comment: "Reply to thread")
            static let resolve = NSLocalizedString("personal_document.comments.resolve", comment: "Resolve thread")
            static let reopen = NSLocalizedString("personal_document.comments.reopen", comment: "Reopen thread")
            static let remove = NSLocalizedString("personal_document.comments.remove", comment: "Withdraw comment")
            static let detached = NSLocalizedString("personal_document.comments.detached", comment: "Threads whose text is gone")
            static let none = NSLocalizedString("personal_document.comments.none", comment: "No open comments")
            static let showResolved = NSLocalizedString("personal_document.comments.show_resolved", comment: "Show resolved threads")
            static let revealFile = NSLocalizedString("personal_document.comments.reveal_file", comment: "Reveal threads file")
            static let menuHelp = NSLocalizedString("personal_document.comments.menu_help", comment: "Comments menu help")
            static let selectionHint = NSLocalizedString("personal_document.comments.selection_hint", comment: "Text block help")
        }

        enum Secretary {
            static let title = NSLocalizedString("personal_document.secretary.title", comment: "Secretary title")
            static let help = NSLocalizedString("personal_document.secretary.help", comment: "Toolbar help")
            static func answer(_ count: Int) -> String { String(format: NSLocalizedString("personal_document.secretary.answer", comment: "Start a comments run; %d = pending threads"), count) }
            static let running = NSLocalizedString("personal_document.secretary.running", comment: "Run in progress")
            static let pass = NSLocalizedString("personal_document.secretary.pass", comment: "Start a full secretary pass by hand")
            static let passNote = NSLocalizedString("personal_document.secretary.pass_note", comment: "What a full pass does")
            static let openPanel = NSLocalizedString("personal_document.secretary.open_panel", comment: "Open the secretary panel")
            static let editingLocked = NSLocalizedString("personal_document.secretary.editing_locked", comment: "Edit refused during a run")
            static let noPending = NSLocalizedString("personal_document.secretary.no_pending", comment: "Nothing to do")
            static let notWorkspace = NSLocalizedString("personal_document.secretary.not_workspace", comment: "Document outside a workspace")
            static let cloudNote = NSLocalizedString("personal_document.secretary.cloud_note", comment: "Privacy footnote")
            static let cancel = NSLocalizedString("personal_document.secretary.cancel", comment: "Stop the run")
            static let close = NSLocalizedString("personal_document.secretary.close", comment: "Close the panel")
            static let showRun = NSLocalizedString("personal_document.secretary.show_run", comment: "Reveal run folder")
            static let showBackup = NSLocalizedString("personal_document.secretary.show_backup", comment: "Reveal backup")
            static let succeeded = NSLocalizedString("personal_document.secretary.succeeded", comment: "Run outcome")
            static let incomplete = NSLocalizedString("personal_document.secretary.incomplete", comment: "Run outcome")
            static let costUnavailable = NSLocalizedString("personal_document.secretary.cost_unavailable", comment: "Unknown run cost")
            static let codexCostExplanation = NSLocalizedString("personal_document.secretary.codex_cost_explanation", comment: "Codex does not report dollar cost")
            static let tokenUsage = NSLocalizedString("personal_document.secretary.token_usage", comment: "Input and output token counts")
            static let remainingNotes = NSLocalizedString("personal_document.secretary.remaining_notes", comment: "Host queue count")
            static let failed = NSLocalizedString("personal_document.secretary.failed", comment: "Run outcome")
            static let cancelled = NSLocalizedString("personal_document.secretary.cancelled", comment: "Run outcome")
            static let findings = NSLocalizedString("personal_document.secretary.findings", comment: "Verification findings heading")
            static let checksPassed = NSLocalizedString("personal_document.secretary.checks_passed", comment: "All checks passed")
            static let log = NSLocalizedString("personal_document.secretary.log", comment: "Log heading")
        }

        enum Timeline {
            static let toggle = NSLocalizedString("personal_document.timeline.toggle", comment: "Show or hide the notes timeline")
            static let day = NSLocalizedString("personal_document.timeline.day", comment: "Timeline zoom: days")
            static let week = NSLocalizedString("personal_document.timeline.week", comment: "Timeline zoom: weeks")
            static let month = NSLocalizedString("personal_document.timeline.month", comment: "Timeline zoom: months")
            static let year = NSLocalizedString("personal_document.timeline.year", comment: "Timeline zoom: years")
            static let zoomHint = NSLocalizedString("personal_document.timeline.zoom_hint", comment: "Timeline zoom help")
            static let legendCited = NSLocalizedString("personal_document.timeline.legend_cited", comment: "Legend: bright vs faint")
            static let citedOnly = NSLocalizedString("personal_document.timeline.cited_only", comment: "Filter: only cited notes")
            static let citedSummary = NSLocalizedString("personal_document.timeline.cited_summary", comment: "%d cited of %d notes")
            static let citedSummaryHint = NSLocalizedString("personal_document.timeline.cited_summary_hint", comment: "Counts help")
            static let kindVoice = NSLocalizedString("personal_document.timeline.kind_voice", comment: "Legend: voice notes")
            static let kindText = NSLocalizedString("personal_document.timeline.kind_text", comment: "Legend: text notes")
            static let kindPDF = NSLocalizedString("personal_document.timeline.kind_pdf", comment: "Legend: PDF notes")
            static let kindImage = NSLocalizedString("personal_document.timeline.kind_image", comment: "Legend: image notes")
            static let openInReader = NSLocalizedString("personal_document.timeline.open_in_reader", comment: "Open note in Reader")
            static let showInDocument = NSLocalizedString("personal_document.timeline.show_in_document", comment: "Scroll to the citing paragraph")
            static let cited = NSLocalizedString("personal_document.timeline.cited", comment: "Note is cited in the document")
            static let clickShowsParagraph = NSLocalizedString("personal_document.timeline.click_shows_paragraph", comment: "Tooltip: click jumps to paragraph")
            static let clickOpensReader = NSLocalizedString("personal_document.timeline.click_opens_reader", comment: "Tooltip: click opens Reader")
            static let minutes = NSLocalizedString("personal_document.timeline.minutes", comment: "Note size in minutes; %.1f")
        }
    }
    
    internal enum App {
        
        internal enum Terminate {
            internal enum Streaming {
                /// Streaming recording in progress. Stop recording?
                internal static let title = NSLocalizedString("app.terminate.streaming.title", comment: "Alert title when quitting during streaming")
                /// Current note will be saved and sent for processing.
                internal static let message = NSLocalizedString("app.terminate.streaming.message", comment: "Alert message when quitting during streaming")
                /// Stop & Save
                internal static let stopSave = NSLocalizedString("app.terminate.streaming.stop_save", comment: "Button to stop and save")
                /// Cancel
                internal static let cancel = NSLocalizedString("app.terminate.streaming.cancel", comment: "Button to cancel quit")
            }
        }
        
        internal enum Language {
            internal static let system = NSLocalizedString("app_language.system", comment: "System language option")
            internal static let english = NSLocalizedString("app_language.english", comment: "English language option")
            internal static let russian = NSLocalizedString("app_language.russian", comment: "Russian language option")
            internal static let german = NSLocalizedString("app_language.german", comment: "German language option")
        }
    }

    internal enum Menu {
        internal enum App {
            internal static func about(appName: String) -> String {
                let format = NSLocalizedString("menu.app.about_fmt", comment: "Menu item")
                return String(format: format, locale: Locale.current, appName)
            }
            internal static let preferences = NSLocalizedString("menu.app.preferences", comment: "Menu item")
            internal static let maintenance = NSLocalizedString("menu.app.maintenance", comment: "Menu item")
            internal static func hide(appName: String) -> String {
                let format = NSLocalizedString("menu.app.hide_fmt", comment: "Menu item")
                return String(format: format, locale: Locale.current, appName)
            }
            internal static let hideOthers = NSLocalizedString("menu.app.hide_others", comment: "Menu item")
            internal static let showAll = NSLocalizedString("menu.app.show_all", comment: "Menu item")
            internal static func quit(appName: String) -> String {
                let format = NSLocalizedString("menu.app.quit_fmt", comment: "Menu item")
                return String(format: format, locale: Locale.current, appName)
            }
        }

        internal enum Window {
            internal static let title = NSLocalizedString("menu.window.title", comment: "Menu title")
            internal static let closeWindow = NSLocalizedString("menu.window.close_window", comment: "Menu item")
            internal static let queueStatus = NSLocalizedString("menu.window.queue_status", comment: "Menu item")
        }

        internal enum Edit {
            internal static let title = NSLocalizedString("menu.edit.title", comment: "Menu title")
            internal static let undo = NSLocalizedString("menu.edit.undo", comment: "Menu item")
            internal static let redo = NSLocalizedString("menu.edit.redo", comment: "Menu item")
            internal static let cut = NSLocalizedString("menu.edit.cut", comment: "Menu item")
            internal static let copy = NSLocalizedString("menu.edit.copy", comment: "Menu item")
            internal static let paste = NSLocalizedString("menu.edit.paste", comment: "Menu item")
            internal static let selectAll = NSLocalizedString("menu.edit.select_all", comment: "Menu item")
            internal static let find = NSLocalizedString("menu.edit.find", comment: "Menu item")
            internal static let findNext = NSLocalizedString("menu.edit.find_next", comment: "Menu item")
            internal static let findPrevious = NSLocalizedString("menu.edit.find_previous", comment: "Menu item")
        }

        internal enum Import {
            internal static let importFiles = NSLocalizedString("menu.import.files", comment: "Menu item")
            internal static let importAppleNotes = NSLocalizedString("menu.import.apple_notes", comment: "Menu item")
            internal static let importVoiceMemos = NSLocalizedString("menu.import.voice_memos", comment: "Menu item")
        }
    }
    
    internal enum Common {
        internal static let close = NSLocalizedString("common.close", comment: "Close button")
        internal static let copy = NSLocalizedString("common.copy", comment: "Copy button")
        internal static let recalculate = NSLocalizedString("common.recalculate", comment: "Recalculate action")
        internal static let `import` = NSLocalizedString("common.import", comment: "Import action")
        internal static let ok = NSLocalizedString("common.ok", comment: "OK button")
        internal static let cancel = NSLocalizedString("common.cancel", comment: "Cancel button")
        internal static let done = NSLocalizedString("common.done", comment: "Done button")
        internal static let delete = NSLocalizedString("common.delete", comment: "Delete button")
        internal static let cancelled = NSLocalizedString("common.cancelled", comment: "Action cancelled")
        internal static let copied = NSLocalizedString("common.copied", comment: "Data copied")
        internal static let copiedToClipboard = NSLocalizedString("common.copied_to_clipboard", comment: "Data copied to clipboard")
        internal static let saved = NSLocalizedString("common.saved", comment: "Data saved")
    }

    internal enum VoiceMemos {
        internal static let folderNotFound = NSLocalizedString("voice_memos.folder_not_found", comment: "Voice Memos folder not found")
        internal static let panelMessage = NSLocalizedString("voice_memos.panel.message", comment: "OpenPanel message for Voice Memos import")

        internal enum AutoImport {
            internal static let accessDenied = NSLocalizedString("voice_memos.auto_import.access_denied", comment: "HUD hint when macOS denies access to the Voice Memos folder")
        }
    }
    
    internal enum Reader {
        internal static let emptyDetail = NSLocalizedString("reader.empty_detail", comment: "Placeholder shown when no note is open")

        internal enum NoteKind {
            internal static let voiceCapture = NSLocalizedString("reader.note_kind.voice_capture", comment: "Note kind label")
            internal static let image = NSLocalizedString("reader.note_kind.image", comment: "Note kind label")
            internal static let pdf = NSLocalizedString("reader.note_kind.pdf", comment: "Note kind label")
            internal static let note = NSLocalizedString("reader.note_kind.note", comment: "Note kind label")
        }

        internal enum SidebarFooter {
            internal static let newCapture = NSLocalizedString("reader.sidebar_footer.new_capture", comment: "Button to start a recording")

            internal static func storageUsed(_ formattedSize: String) -> String {
                let format = NSLocalizedString("reader.sidebar_footer.storage_used_fmt", comment: "Storage line, e.g. '2.4 GB used'")
                return String(format: format, locale: Locale.current, formattedSize)
            }
        }

        internal enum Analysis {
            internal static let title = NSLocalizedString("reader.analysis.title", comment: "Header title for Analysis")
            internal static let generating = NSLocalizedString("reader.analysis.generating", comment: "Status: Generating...")
            internal static let tapRecalculate = NSLocalizedString("reader.analysis.tap_recalculate", comment: "Placeholder text")
            internal static let saveView = NSLocalizedString("reader.analysis.save_view", comment: "Button to save view")
        }
        
        internal enum Search {
            internal static let previousMatch = NSLocalizedString("reader.search.previous_match", comment: "Previous match tooltip")
            internal static let nextMatch = NSLocalizedString("reader.search.next_match", comment: "Next match tooltip")
            internal static let filter = NSLocalizedString("reader.search.filter", comment: "Filter button")
            internal static let filtersHelp = NSLocalizedString("reader.search.filters_help", comment: "Tooltip for filters")
            
            internal enum Filter {
                internal static let matchesOnly = NSLocalizedString("reader.search.filter.matches_only", comment: "Filter option")
                internal static let failedOnly = NSLocalizedString("reader.search.filter.failed_only", comment: "Filter option")
                internal static let suspectedNoSpeechOnly = NSLocalizedString("reader.search.filter.suspected_no_speech_only", comment: "Filter option")
                internal static let retryAllSuspectedNoSpeech = NSLocalizedString("reader.search.filter.retry_all_suspected_no_speech", comment: "Filter action: retry transcription for all flagged notes")
                internal static let screenshotOnly = NSLocalizedString("reader.search.filter.screenshot_only", comment: "Filter option")
            }
        }
        
        internal enum Ai {
            internal static let toolsHelp = NSLocalizedString("reader.ai.tools_help", comment: "Tooltip for AI tools")
            
            internal enum Debug {
                internal static let addTestDraft = NSLocalizedString("reader.ai.debug.add_test_draft", comment: "Debug action")
                internal static let addTestArtifact = NSLocalizedString("reader.ai.debug.add_test_artifact", comment: "Debug action")
            }
        }

        internal enum Header {
            internal static let wordmark = "WIMM"
            internal static let searchPlaceholder = NSLocalizedString("reader.header.search_placeholder", comment: "Search field placeholder")
            internal static let editing = NSLocalizedString("reader.header.editing", comment: "Status pill: note is being edited")
            internal static let shareHelp = NSLocalizedString("reader.header.share", comment: "Tooltip")
            internal static let more = NSLocalizedString("reader.header.more", comment: "Tooltip for the overflow menu")
            internal static let showLLMContext = NSLocalizedString("reader.header.show_llm_context", comment: "Menu item")
            internal static let showRawJSON = NSLocalizedString("reader.header.show_raw_json", comment: "Menu item")

            internal enum Selection {
                internal static let select = NSLocalizedString("reader.header.selection.select", comment: "Button")
                internal static let done = NSLocalizedString("reader.header.selection.done", comment: "Button")
                internal static let selectHelp = NSLocalizedString("reader.header.selection.select_help", comment: "Tooltip")
                internal static let clear = NSLocalizedString("reader.header.selection.clear", comment: "Button")
                internal static let clearHelp = NSLocalizedString("reader.header.selection.clear_help", comment: "Tooltip")
            }

            internal enum Share {
                internal static let title = NSLocalizedString("reader.header.share.title", comment: "Menu title")
                internal static let copyContext = NSLocalizedString("reader.header.share.copy_context", comment: "Menu item")
                internal static let help = NSLocalizedString("reader.header.share.help", comment: "Tooltip")
            }

            internal enum Ai {
                internal static let title = NSLocalizedString("reader.header.ai.title", comment: "Label")
                internal static let debugMenu = NSLocalizedString("reader.header.ai.debug_menu", comment: "Menu title")
            }

        }

        internal enum Sidebar {
            internal static let collapseHelp = NSLocalizedString("reader.sidebar.collapse_help", comment: "Tooltip")
            internal static let expandHelp = NSLocalizedString("reader.sidebar.expand_help", comment: "Tooltip")
            internal static let sectionGeneral = NSLocalizedString("reader.sidebar.section.general", comment: "Sidebar section")
            internal static let imported = NSLocalizedString("reader.sidebar.imported", comment: "Imported notes category")
        }

        internal enum Trash {
            internal static let title = NSLocalizedString("reader.trash.title", comment: "View title")
            internal static let emptyTrash = NSLocalizedString("reader.trash.empty_trash", comment: "Button")
            internal static let empty = NSLocalizedString("reader.trash.empty", comment: "Empty state")

            internal enum Action {
                internal static let restoreHelp = NSLocalizedString("reader.trash.action.restore_help", comment: "Tooltip")
                internal static let deletePermanentlyHelp = NSLocalizedString("reader.trash.action.delete_permanently_help", comment: "Tooltip")
                internal static let restore = NSLocalizedString("reader.trash.action.restore", comment: "Label")
                internal static let deletePermanently = NSLocalizedString("reader.trash.action.delete_permanently", comment: "Label")
            }

            internal enum ConfirmEmpty {
                internal static let title = NSLocalizedString("reader.trash.confirm_empty.title", comment: "Alert title")
                internal static let message = NSLocalizedString("reader.trash.confirm_empty.message", comment: "Alert message")
                internal static let emptyButton = NSLocalizedString("reader.trash.confirm_empty.empty_button", comment: "Button")
            }

            internal enum ConfirmPermanentDelete {
                internal static let title = NSLocalizedString("reader.trash.confirm_delete.title", comment: "Alert title")
                internal static let message = NSLocalizedString("reader.trash.confirm_delete.message", comment: "Alert message")
            }
        }

        internal enum Window {
            internal static let readerTitle = NSLocalizedString("reader.window.title", comment: "Window title")
        }

        internal enum Note {
            internal static func rawResponseTitle(fileName: String) -> String {
                let format = NSLocalizedString("reader.note.raw_response.title_fmt", comment: "Window title")
                return String(format: format, locale: Locale.current, fileName)
            }
        }

        internal enum Root {
            internal static let collapseHelp = NSLocalizedString("reader.root.collapse_help", comment: "Tooltip")
        }

        internal enum SceneKit {
            internal static let simulationTitle = NSLocalizedString("reader.scenekit.simulation.title", comment: "Label")
            internal static let pauseSimulation = NSLocalizedString("reader.scenekit.simulation.pause", comment: "Tooltip")
            internal static let startSimulation = NSLocalizedString("reader.scenekit.simulation.start", comment: "Tooltip")
            internal static let resetSimulation = NSLocalizedString("reader.scenekit.simulation.reset", comment: "Tooltip")
            internal static let fitToScreen = NSLocalizedString("reader.scenekit.fit_to_screen", comment: "Tooltip")
            internal static let focus = NSLocalizedString("reader.scenekit.focus", comment: "Button")
            internal static let focusHelp = NSLocalizedString("reader.scenekit.focus_help", comment: "Tooltip")
            internal static let parameters = NSLocalizedString("reader.scenekit.parameters", comment: "Button")
            internal static let analysis = NSLocalizedString("reader.scenekit.analysis", comment: "Button")
            internal static let analysisHelp = NSLocalizedString("reader.scenekit.analysis_help", comment: "Tooltip")
        }

        internal enum NoteRow {
            internal static let canceled = NSLocalizedString("reader.note_row.canceled", comment: "Badge")
            internal static let noTextRecognized = NSLocalizedString("reader.note_row.no_text_recognized", comment: "Badge")
            internal static let transcriptionFailed = NSLocalizedString("reader.note_row.transcription_failed", comment: "Badge")
            internal static let suspectedNoSpeech = NSLocalizedString("reader.note_row.suspected_no_speech", comment: "Badge")
            internal static let transcript = NSLocalizedString("reader.note_row.transcript", comment: "Disclosure title")
            internal static let audio = NSLocalizedString("reader.note_row.audio", comment: "Badge")
            internal static let image = NSLocalizedString("reader.note_row.image", comment: "Badge")
            internal static let note = NSLocalizedString("reader.note_row.note", comment: "Badge")
            internal static let doc = NSLocalizedString("reader.note_row.doc", comment: "Attachment type")
            internal static let sheet = NSLocalizedString("reader.note_row.sheet", comment: "Attachment type")
            internal static let archive = NSLocalizedString("reader.note_row.archive", comment: "Attachment type")
            internal static let video = NSLocalizedString("reader.note_row.video", comment: "Attachment type")
            internal static let file = NSLocalizedString("reader.note_row.file", comment: "Attachment type")

            internal static func pdfPages(_ pages: Int) -> String {
                let format = NSLocalizedString("reader.note_row.pdf_pages_fmt", comment: "PDF pages badge")
                return String(format: format, locale: Locale.current, pages)
            }

            internal static func lines(_ count: String) -> String {
                let format = NSLocalizedString("reader.note_row.lines_fmt", comment: "Text length indicator")
                return String(format: format, locale: Locale.current, count)
            }

            internal enum Action {
                internal static let copy = NSLocalizedString("reader.note_row.action.copy", comment: "Menu action")
                internal static let revealInFinder = NSLocalizedString("reader.note_row.action.reveal_in_finder", comment: "Menu action")
                internal static let edit = NSLocalizedString("reader.note_row.action.edit", comment: "Menu action")
                internal static let retryTranscription = NSLocalizedString("reader.note_row.action.retry_transcription", comment: "Menu action")
                internal static let uncancel = NSLocalizedString("reader.note_row.action.uncancel", comment: "Menu action")
                internal static let playOnlyThisRecording = NSLocalizedString("reader.note_row.action.play_only_this_recording", comment: "Menu action")
                internal static let viewScreenshot = NSLocalizedString("reader.note_row.action.view_screenshot", comment: "Menu action")
                internal static let editTranscript = NSLocalizedString("reader.note_row.action.edit_transcript", comment: "Menu action")
                internal static let showRaw = NSLocalizedString("reader.note_row.action.show_raw", comment: "Menu action")
                internal static let copyNote = NSLocalizedString("reader.note_row.action.copy_note", comment: "Menu action")
                internal static let copyAsRedacted = NSLocalizedString("reader.note_row.action.copy_as_redacted", comment: "Menu action")
                internal static let reprocessNote = NSLocalizedString("reader.note_row.action.reprocess_note", comment: "Menu action")
                internal static let deleteRecording = NSLocalizedString("reader.note_row.action.delete_recording", comment: "Menu action")
            }

            internal enum Help {
                internal static let playOnlyThisRecording = NSLocalizedString("reader.note_row.help.play_only_this_recording", comment: "Tooltip")
                internal static let copyNote = NSLocalizedString("reader.note_row.help.copy_note", comment: "Tooltip")
                internal static let copyAsRedacted = NSLocalizedString("reader.note_row.help.copy_as_redacted", comment: "Tooltip")
                internal static let editTranscript = NSLocalizedString("reader.note_row.help.edit_transcript", comment: "Tooltip")
                internal static let showRaw = NSLocalizedString("reader.note_row.help.show_raw", comment: "Tooltip")
                internal static let revealInFinder = NSLocalizedString("reader.note_row.help.reveal_in_finder", comment: "Tooltip")
                internal static let retryTranscription = NSLocalizedString("reader.note_row.help.retry_transcription", comment: "Tooltip")
                internal static let deleteRecordingAndRelatedFiles = NSLocalizedString("reader.note_row.help.delete_recording_related_files", comment: "Tooltip")
                internal static let openDetailedView = NSLocalizedString("reader.note_row.help.open_detailed_view", comment: "Tooltip")
                internal static let viewScreenshot = NSLocalizedString("reader.note_row.help.view_screenshot", comment: "Tooltip")
                internal static let subconscious = NSLocalizedString("reader.note_row.help.subconscious", comment: "Tooltip")
            }

            internal enum Model {
                internal static let native = NSLocalizedString("reader.note_row.model.native", comment: "Model badge")
                internal static let geminiPro = NSLocalizedString("reader.note_row.model.gemini_pro", comment: "Model badge")
                internal static let geminiFlash = NSLocalizedString("reader.note_row.model.gemini_flash", comment: "Model badge")
                internal static let gemini = NSLocalizedString("reader.note_row.model.gemini", comment: "Model badge")
            }

            internal enum Preview {
                internal static let close = NSLocalizedString("reader.note_row.preview.close", comment: "Button")
                internal static let closeWindowTooltip = NSLocalizedString("reader.note_row.preview.close_window_tooltip", comment: "Tooltip")
                internal static let copy = NSLocalizedString("reader.note_row.preview.copy", comment: "Button")
                internal static let copyToClipboardTooltip = NSLocalizedString("reader.note_row.preview.copy_to_clipboard_tooltip", comment: "Tooltip")
            }
        }

        internal enum StatusBar {
            internal static let visionJobs = NSLocalizedString("reader.status_bar.vision_jobs", comment: "Label")
            internal static let extract = NSLocalizedString("reader.status_bar.extract", comment: "Label")
            internal static let audio = NSLocalizedString("reader.status_bar.audio", comment: "Label")
            internal static let analysis = NSLocalizedString("reader.status_bar.analysis", comment: "Label")
            internal static let chat = NSLocalizedString("reader.status_bar.chat", comment: "Label")
            internal static let visual = NSLocalizedString("reader.status_bar.visual", comment: "Label")
            internal static let ready = NSLocalizedString("reader.status_bar.ready", comment: "Status")
            internal static let processingVerb = NSLocalizedString("reader.status_bar.processing_verb", comment: "Verb")
            internal static let visionHelp = NSLocalizedString("reader.status_bar.vision_help", comment: "Tooltip")
            internal static let extractHelp = NSLocalizedString("reader.status_bar.extract_help", comment: "Tooltip")
            internal static let other = NSLocalizedString("reader.status_bar.other", comment: "Label")
            internal static let queue = NSLocalizedString("reader.status_bar.queue", comment: "Label")
            internal static let queueHelp = NSLocalizedString("reader.status_bar.queue_help", comment: "Tooltip")
            internal static let queuePopoverTitle = NSLocalizedString("reader.status_bar.queue_popover_title", comment: "Popover title")
            internal static let queueEmpty = NSLocalizedString("reader.status_bar.queue_empty", comment: "Status")
            internal static let pause = NSLocalizedString("reader.status_bar.pause", comment: "Button")
            internal static let resume = NSLocalizedString("reader.status_bar.resume", comment: "Button")
            internal static let cancelAll = NSLocalizedString("reader.status_bar.cancel_all", comment: "Button")
            internal static let cancelJob = NSLocalizedString("reader.status_bar.cancel_job", comment: "Button")
            internal static let clearFinished = NSLocalizedString("reader.status_bar.clear_finished", comment: "Button")
            internal static let recentErrors = NSLocalizedString("reader.status_bar.recent_errors", comment: "Section title")
            internal static let pausedSuffix = NSLocalizedString("reader.status_bar.paused_suffix", comment: "Status suffix")

            internal static func queueFinished(_ count: Int) -> String {
                let format = NSLocalizedString("reader.status_bar.queue_finished_fmt", comment: "Finished jobs count")
                return String(format: format, locale: Locale.current, count)
            }

            internal static func queueFailed(_ count: Int) -> String {
                let format = NSLocalizedString("reader.status_bar.queue_failed_fmt", comment: "Failed jobs count")
                return String(format: format, locale: Locale.current, count)
            }

            internal static func moreJobs(_ count: Int) -> String {
                let format = NSLocalizedString("reader.status_bar.more_jobs_fmt", comment: "Hidden jobs count")
                return String(format: format, locale: Locale.current, count)
            }
        }

        internal enum NewNote {
            internal static let title = NSLocalizedString("reader.new_note.title", comment: "Note-list placeholder row")
            internal static let help = NSLocalizedString("reader.new_note.help", comment: "Tooltip for the new-note action")
            internal static let emptyDraft = NSLocalizedString("reader.new_note.empty_draft", comment: "List subtitle for a note with nothing in it yet")
            internal static let bodyPlaceholder = NSLocalizedString("reader.new_note.body_placeholder", comment: "Placeholder inside an empty note body")
            internal static let draftHint = NSLocalizedString("reader.new_note.draft_hint", comment: "Explains what else can go into an empty note")
            internal static let autosaves = NSLocalizedString("reader.new_note.autosaves", comment: "Save status when idle")
            internal static let analyze = NSLocalizedString("reader.new_note.analyze", comment: "Button title")
            internal static let analyzeHelp = NSLocalizedString("reader.new_note.analyze_help", comment: "Tooltip")
            internal static let attachFile = NSLocalizedString("reader.new_note.attach_file", comment: "Tooltip")
            internal static let pasteClipboard = NSLocalizedString("reader.new_note.paste_clipboard", comment: "Tooltip")
        }

        internal enum NoteView {
            internal static let focusHelp = NSLocalizedString("reader.note_view.focus_help", comment: "Tooltip")
            internal static let reprocessHelp = NSLocalizedString("reader.note_view.reprocess_help", comment: "Tooltip")
            internal static let like = NSLocalizedString("reader.note_view.like", comment: "Tooltip")
            internal static let unlike = NSLocalizedString("reader.note_view.unlike", comment: "Tooltip")
            internal static let recording = NSLocalizedString("reader.note_view.recording", comment: "Status")
            internal static let recordInstructionHelp = NSLocalizedString("reader.note_view.record_instruction_help", comment: "Tooltip")
            internal static let summary = NSLocalizedString("reader.note_view.summary", comment: "Label")
            internal static let refinedText = NSLocalizedString("reader.note_view.refined_text", comment: "Section title")
            internal static let transcription = NSLocalizedString("reader.note_view.transcription", comment: "Section title")
            internal static let text = NSLocalizedString("reader.note_view.text", comment: "Section title")
            internal static let context = NSLocalizedString("reader.note_view.context", comment: "Section title")
            internal static let attachments = NSLocalizedString("reader.note_view.attachments", comment: "Section title")
            internal static let metadata = NSLocalizedString("reader.note_view.metadata", comment: "Section title")
            internal static let saving = NSLocalizedString("reader.note_view.saving", comment: "Autosave status")
            internal static let saved = NSLocalizedString("reader.note_view.saved", comment: "Autosave status")
            internal static let titlePlaceholder = NSLocalizedString("reader.note_view.title_placeholder", comment: "Placeholder for an untitled note")

            internal enum Variants {
                internal static let transcriptions = NSLocalizedString("reader.note_view.variants.transcriptions", comment: "Note text variants")
                internal static let current = NSLocalizedString("reader.note_view.variants.current", comment: "Note text variants")
                internal static let realtime = NSLocalizedString("reader.note_view.variants.realtime", comment: "Note text variants: live text captured while recording")
                internal static let local = NSLocalizedString("reader.note_view.variants.local", comment: "Note text variants: latest on-device file transcription")
                internal static let cloud = NSLocalizedString("reader.note_view.variants.cloud", comment: "Note text variants: latest cloud file transcription")
                internal static let currentRun = NSLocalizedString("reader.note_view.variants.current_run", comment: "Note text variants: tag on the run the note was built from")
                internal static let previous = NSLocalizedString("reader.note_view.variants.previous", comment: "Note text variants")
                internal static func speakers(_ count: Int) -> String {
                    String(format: NSLocalizedString("reader.note_view.variants.speakers", comment: "Transcript split by speaker; %d = number of speakers"), count)
                }
                internal static func speakerLabel(_ number: Int) -> String {
                    String(format: NSLocalizedString("reader.note_view.variants.speaker_label", comment: "Label before a speaker's turn; %d = speaker number"), number)
                }
                internal static let sameAsText = NSLocalizedString("reader.note_view.variants.same_as_text", comment: "Note text variants")
                internal static let useAsText = NSLocalizedString("reader.note_view.variants.use_as_text", comment: "Note text variants")
            }

            internal enum History {
                internal static let title = NSLocalizedString("reader.note_view.history.title", comment: "Note text variants")
                internal static let baseline = NSLocalizedString("reader.note_view.history.baseline", comment: "Note text variants")
                internal static let manual = NSLocalizedString("reader.note_view.history.manual", comment: "Note text variants")
                internal static let restored = NSLocalizedString("reader.note_view.history.restored", comment: "Note text variants")
                internal static let restore = NSLocalizedString("reader.note_view.history.restore", comment: "Note text variants")
            }

            internal static func editedAgo(_ relative: String) -> String {
                let format = NSLocalizedString("reader.note_view.edited_ago_fmt", comment: "Meta line, e.g. 'Edited 3 min ago'")
                return String(format: format, locale: Locale.current, relative)
            }

            internal static func seconds(_ value: Double) -> String {
                let format = NSLocalizedString("reader.note_view.seconds_fmt", comment: "Seconds value")
                return String(format: format, locale: Locale.current, value)
            }

            internal enum Tab {
                internal static let visual = NSLocalizedString("reader.note_view.tab.visual", comment: "Tab title")
                internal static let llmContext = NSLocalizedString("reader.note_view.tab.llm_context", comment: "Tab title")
                internal static let rawJSON = NSLocalizedString("reader.note_view.tab.raw_json", comment: "Tab title")
            }

            internal enum Metadata {
                internal static let filename = NSLocalizedString("reader.note_view.metadata.filename", comment: "Field title")
                internal static let pages = NSLocalizedString("reader.note_view.metadata.pages", comment: "Field title")
                internal static let created = NSLocalizedString("reader.note_view.metadata.created", comment: "Field title")
                internal static let modified = NSLocalizedString("reader.note_view.metadata.modified", comment: "Field title")
                internal static let start = NSLocalizedString("reader.note_view.metadata.start", comment: "Field title")
                internal static let end = NSLocalizedString("reader.note_view.metadata.end", comment: "Field title")
                internal static let transcriber = NSLocalizedString("reader.note_view.metadata.transcriber", comment: "Field title")
                internal static let extraction = NSLocalizedString("reader.note_view.metadata.extraction", comment: "Field title")
                internal static let origin = NSLocalizedString("reader.note_view.metadata.origin", comment: "Field title: which device created the note")
            }
        }

        internal enum EditTranscriptSheet {
            internal static let title = NSLocalizedString("reader.edit_transcript_sheet.title", comment: "Sheet title")
            internal static let save = NSLocalizedString("reader.edit_transcript_sheet.save", comment: "Button")
        }

        internal enum AnalysisResult {
            internal static let title = NSLocalizedString("reader.analysis_result.title", comment: "Window title")
        }

        internal enum SourceControlCard {
            internal static let pdfDocument = NSLocalizedString("reader.source_control_card.pdf_document", comment: "Card title")
            internal static let audioRecording = NSLocalizedString("reader.source_control_card.audio_recording", comment: "Card title")
            internal static let reOCR = NSLocalizedString("reader.source_control_card.re_ocr", comment: "Button")

            internal static func pages(_ count: Int) -> String {
                let format = NSLocalizedString("reader.source_control_card.pages_fmt", comment: "Pages count")
                return String(format: format, locale: Locale.current, count)
            }

            internal static func seconds(_ value: Double) -> String {
                let format = NSLocalizedString("reader.source_control_card.seconds_fmt", comment: "Duration in seconds")
                return String(format: format, locale: Locale.current, value)
            }
        }

        internal enum CardPreview {
            internal static let fresh = NSLocalizedString("reader.card_preview.fresh", comment: "Badge")
            internal static let listen = NSLocalizedString("reader.card_preview.listen", comment: "Action")
            internal static let open = NSLocalizedString("reader.card_preview.open", comment: "Action")
        }

        internal enum ImportTypePicker {
            internal static let title = NSLocalizedString("reader.import_type_picker.title", comment: "Title")
            internal static let notSupported = NSLocalizedString("reader.import_type_picker.not_supported", comment: "State")
            internal static let started = NSLocalizedString("reader.import_type_picker.started", comment: "Button")
            internal static let noNew = NSLocalizedString("reader.import_type_picker.no_new", comment: "Button")
            internal static let `import` = NSLocalizedString("reader.import_type_picker.import", comment: "Button")
            internal static let showDuplicates = NSLocalizedString("reader.import_type_picker.show_duplicates", comment: "Disclosure title")
            internal static let importAll = NSLocalizedString("reader.import_type_picker.import_all", comment: "Button")
            internal static let importing = NSLocalizedString("reader.import_type_picker.importing", comment: "Import progress title")
            internal static let processing = NSLocalizedString("reader.import_type_picker.processing", comment: "Processing progress title")
            internal static let completed = NSLocalizedString("reader.import_type_picker.completed", comment: "Completed progress title")
            internal static let failed = NSLocalizedString("reader.import_type_picker.failed", comment: "Failed progress title")

            internal static func foundFiles(_ count: Int) -> String {
                let format = NSLocalizedString("reader.import_type_picker.found_files_fmt", comment: "Found files")
                return String(format: format, locale: Locale.current, count)
            }

            internal static func duplicatesSkipped(_ count: Int) -> String {
                let format = NSLocalizedString("reader.import_type_picker.duplicates_skipped_fmt", comment: "Duplicates info")
                return String(format: format, locale: Locale.current, count)
            }

            internal static func andMore(_ count: Int) -> String {
                let format = NSLocalizedString("reader.import_type_picker.and_more_fmt", comment: "And more items")
                return String(format: format, locale: Locale.current, count)
            }

            internal static func scanningFound(_ count: Int) -> String {
                let format = NSLocalizedString("reader.import_type_picker.scanning_found_fmt", comment: "Directory scan progress")
                return String(format: format, locale: Locale.current, count)
            }

            internal static func checkingFiles(_ count: Int) -> String {
                let format = NSLocalizedString("reader.import_type_picker.checking_files_fmt", comment: "Duplicate check progress")
                return String(format: format, locale: Locale.current, count)
            }

            internal static func showFiles(_ count: Int) -> String {
                let format = NSLocalizedString("reader.import_type_picker.show_files_fmt", comment: "Files disclosure title")
                return String(format: format, locale: Locale.current, count)
            }

            internal static func resultCounts(imported: Int, failed: Int) -> String {
                let format = NSLocalizedString("reader.import_type_picker.result_counts_fmt", comment: "Import result counters")
                return String(format: format, locale: Locale.current, imported, failed)
            }
        }

        internal enum AttachmentCard {
            internal static let transcribe = NSLocalizedString("reader.attachment_card.transcribe", comment: "Button")
            internal static let ocr = NSLocalizedString("reader.attachment_card.ocr", comment: "Button/label")
            internal static let open = NSLocalizedString("reader.attachment_card.open", comment: "Button")
            internal static let finder = NSLocalizedString("reader.attachment_card.finder", comment: "Button")
            internal static let pdf = NSLocalizedString("reader.attachment_card.pdf", comment: "Label")
            internal static let textContent = NSLocalizedString("reader.attachment_card.text_content", comment: "Section title")
            internal static let showLess = NSLocalizedString("reader.attachment_card.show_less", comment: "Button")
            internal static let showMore = NSLocalizedString("reader.attachment_card.show_more", comment: "Button")
            internal static let noContentAvailable = NSLocalizedString("reader.attachment_card.no_content_available", comment: "Empty state")
            internal static let noTextRecognized = NSLocalizedString("reader.attachment_card.no_text_recognized", comment: "Empty state")
        }

        internal enum CardsSettings {
            internal static let title = NSLocalizedString("reader.cards_settings.title", comment: "Panel title")
            internal static let cardStyle = NSLocalizedString("reader.cards_settings.card_style", comment: "Picker label")
            internal static let minimal = NSLocalizedString("reader.cards_settings.minimal", comment: "Option")
            internal static let medium = NSLocalizedString("reader.cards_settings.medium", comment: "Option")
            internal static let reset = NSLocalizedString("reader.cards_settings.reset", comment: "Button")
            internal static let layout = NSLocalizedString("reader.cards_settings.layout", comment: "Section title")
            internal static let mode = NSLocalizedString("reader.cards_settings.mode", comment: "Picker label")
            internal static let yCycle = NSLocalizedString("reader.cards_settings.y_cycle", comment: "Picker label")
            internal static let camera = NSLocalizedString("reader.cards_settings.camera", comment: "Section title")
            internal static let texture = NSLocalizedString("reader.cards_settings.texture", comment: "Section title")
            internal static let physics = NSLocalizedString("reader.cards_settings.physics", comment: "Section title")
            internal static let background = NSLocalizedString("reader.cards_settings.background", comment: "Section title")
            internal static let selection = NSLocalizedString("reader.cards_settings.selection", comment: "Section title")
        }

        internal enum VisualizationSettings {
            internal static let title = NSLocalizedString("reader.visualization_settings.title", comment: "Panel title")
            internal static let saveAsDefault = NSLocalizedString("reader.visualization_settings.save_as_default", comment: "Menu item")
            internal static let restoreMyDefaults = NSLocalizedString("reader.visualization_settings.restore_my_defaults", comment: "Menu item")
            internal static let resetToFactory = NSLocalizedString("reader.visualization_settings.reset_to_factory", comment: "Menu item")
            internal static let cards = NSLocalizedString("reader.visualization_settings.cards", comment: "Row title")
            internal static let on = NSLocalizedString("reader.visualization_settings.on", comment: "Toggle value")
            internal static let off = NSLocalizedString("reader.visualization_settings.off", comment: "Toggle value")
            internal static let sorting = NSLocalizedString("reader.visualization_settings.sorting", comment: "Picker label")
            internal static let axisX = NSLocalizedString("reader.visualization_settings.axis_x", comment: "Picker label")
            internal static let axisY = NSLocalizedString("reader.visualization_settings.axis_y", comment: "Picker label")
            internal static let algorithm = NSLocalizedString("reader.visualization_settings.algorithm", comment: "Picker label")
        }
    }

    internal enum Settings {
        internal enum Secretary {
            static let packetSize = NSLocalizedString("settings.secretary.packet_size", comment: "Source packet size")
            static let packetSizeHint = NSLocalizedString("settings.secretary.packet_size_hint", comment: "Packet source budget and solo exception")
            static let packetSizeUnit = NSLocalizedString("settings.secretary.packet_size_unit", comment: "Decimal kilobytes")
            internal static let title = NSLocalizedString("settings.secretary.title", comment: "Settings card")
            internal static let subtitle = NSLocalizedString("settings.secretary.subtitle", comment: "Settings card")
            internal static let agent = NSLocalizedString("settings.secretary.agent", comment: "Picker label")
            internal static let model = NSLocalizedString("settings.secretary.model", comment: "Field label")
            internal static let modelPlaceholder = NSLocalizedString("settings.secretary.model_placeholder", comment: "Field placeholder")
            internal static let modelHint = NSLocalizedString("settings.secretary.model_hint", comment: "Field hint")
            internal static let budget = NSLocalizedString("settings.secretary.budget", comment: "Stepper label")
            internal static let budgetHint = NSLocalizedString("settings.secretary.budget_hint", comment: "Stepper hint")
            internal static let codexHint = NSLocalizedString("settings.secretary.codex_hint", comment: "Where the agent logs in")
            internal static let claudeHint = NSLocalizedString("settings.secretary.claude_hint", comment: "Where the agent logs in")
            internal static let privateModeNote = NSLocalizedString("settings.secretary.private_mode_note", comment: "Private mode refuses runs")
            internal static func found(_ name: String) -> String { String(format: NSLocalizedString("settings.secretary.found", comment: "Agent installed; %@ = name"), name) }
            internal static func missing(_ name: String) -> String { String(format: NSLocalizedString("settings.secretary.missing", comment: "Agent not installed; %@ = name"), name) }
        }

        internal static let general = NSLocalizedString("settings.tab.general", comment: "Settings Tab")
        internal static let development = NSLocalizedString("settings.tab.development", comment: "Settings Tab")
        internal static let agent = NSLocalizedString("settings.tab.agent", comment: "Settings Tab")
        internal static let windowTitle = NSLocalizedString("settings.window.title", comment: "Window title")
        internal static let appearance = NSLocalizedString("settings.appearance.title", comment: "Section Header")
        internal static let appearanceDesc = NSLocalizedString("settings.appearance.subtitle", comment: "Section Description")
        internal static let theme = NSLocalizedString("settings.theme.title", comment: "Option Label")
        internal static let themeDesc = NSLocalizedString("settings.theme.subtitle", comment: "Option Description")
        internal static let appLanguage = NSLocalizedString("settings.app_language.title", comment: "Option Label")
        internal static let appLanguageDesc = NSLocalizedString("settings.app_language.subtitle", comment: "Option Description")

        internal enum Performance {
            internal static let debounceRangeHelp = NSLocalizedString("settings.performance.debounce_range_help", comment: "Tooltip")
        }

        internal enum Capability {
            internal static let think = NSLocalizedString("settings.capability.think", comment: "Capability name")
            internal static let understand = NSLocalizedString("settings.capability.understand", comment: "Capability name")
            internal static let hear = NSLocalizedString("settings.capability.hear", comment: "Capability name")
            internal static let see = NSLocalizedString("settings.capability.see", comment: "Capability name")
        }

        internal enum Provider {
            internal static let vision = NSLocalizedString("settings.provider.vision", comment: "Provider name")
            internal static let gemini = NSLocalizedString("settings.provider.gemini", comment: "Provider name")
            internal static let openRouter = NSLocalizedString("settings.provider.openrouter", comment: "Provider name")
            internal static let local = NSLocalizedString("settings.provider.local", comment: "Provider name")
            internal static let localMLX = NSLocalizedString("settings.provider.local_mlx", comment: "Provider option")
            internal static let apple = NSLocalizedString("settings.provider.apple", comment: "Provider option")
            internal static let appleVision = NSLocalizedString("settings.provider.apple_vision", comment: "Provider option")
            internal static let appleOnDevice = NSLocalizedString("settings.provider.apple_on_device", comment: "Provider name")
            internal static let appleOnDeviceLLM = NSLocalizedString("settings.provider.apple_on_device_llm", comment: "Provider name")
        }

        internal enum ModelPicker {
            internal static let provider = NSLocalizedString("settings.model_picker.provider", comment: "Picker label")
            internal static let model = NSLocalizedString("settings.model_picker.model", comment: "Picker label")
            internal static let openRouterModelId = NSLocalizedString("settings.model_picker.openrouter_model_id", comment: "Text field placeholder")
            internal static let loading = NSLocalizedString("settings.model_picker.loading", comment: "Button label")
            internal static let reload = NSLocalizedString("settings.model_picker.reload", comment: "Button label")
            internal static let localDescription = NSLocalizedString("settings.model_picker.local_description", comment: "Description")
            internal static let parakeetDescription = NSLocalizedString("settings.model_picker.parakeet_description", comment: "Description of the on-device Parakeet transcription model")
            internal static let available = NSLocalizedString("settings.model_picker.available", comment: "Availability state")
            internal static let unavailable = NSLocalizedString("settings.model_picker.unavailable", comment: "Availability state")
            internal static let appleOnDeviceDescription = NSLocalizedString("settings.model_picker.apple_on_device_description", comment: "Description")
            internal static let appleOnDeviceNotReady = NSLocalizedString("settings.model_picker.apple_on_device_not_ready", comment: "Description")
            internal static let appleOnDeviceEnableSteps = NSLocalizedString("settings.model_picker.apple_on_device_enable_steps", comment: "Steps")
            internal static let openSystemSettings = NSLocalizedString("settings.model_picker.open_system_settings", comment: "Button")

            internal static func providerModel(provider: String, model: String) -> String {
                let format = NSLocalizedString("settings.model_picker.provider_model_fmt", comment: "Provider and model title")
                return String(format: format, locale: Locale.current, provider, model)
            }
        }

        internal enum OpenRouterBrowser {
            internal static let loadingCatalog = NSLocalizedString("settings.openrouter.loading_catalog", comment: "Status")
            internal static let reloadToFetch = NSLocalizedString("settings.openrouter.reload_to_fetch", comment: "Hint")
            internal static let startTyping = NSLocalizedString("settings.openrouter.start_typing", comment: "Hint")

            internal static func noModelsMatching(_ filter: String) -> String {
                let format = NSLocalizedString("settings.openrouter.no_models_matching_fmt", comment: "No models found message")
                return String(format: format, locale: Locale.current, filter)
            }
        }

        internal enum General {
            internal static let screenshotScopeTitle = NSLocalizedString("settings.general.screenshot_scope.title", comment: "Label")
            internal static let screenshotScopeScreen = NSLocalizedString("settings.general.screenshot_scope.screen", comment: "Option")
            internal static let screenshotScopeActiveWindow = NSLocalizedString("settings.general.screenshot_scope.active_window", comment: "Option")
            internal static let useEmojisTitle = NSLocalizedString("settings.general.use_emojis.title", comment: "Toggle title")
            internal static let useEmojisDescription = NSLocalizedString("settings.general.use_emojis.description", comment: "Toggle description")
            internal static let showCanceledNotesTitle = NSLocalizedString("settings.general.show_canceled_notes.title", comment: "Toggle title")
            internal static let showCanceledNotesDescription = NSLocalizedString("settings.general.show_canceled_notes.description", comment: "Toggle description")
            internal static let llmResponseLanguageTitle = NSLocalizedString("settings.general.llm_response_language.title", comment: "Picker title")
            internal static let llmResponseLanguageDescription = NSLocalizedString("settings.general.llm_response_language.description", comment: "Description")
            internal static let transcriptionLanguageTitle = NSLocalizedString("settings.general.transcription_language.title", comment: "Picker title")
            internal static let transcriptionLanguageDescription = NSLocalizedString("settings.general.transcription_language.description", comment: "Description")
            internal static let cardTextLimitTitle = NSLocalizedString("settings.general.card_text_limit.title", comment: "Label")
            internal static let cardTextLimitDescription = NSLocalizedString("settings.general.card_text_limit.description", comment: "Description")
            internal static let ttsTitle = NSLocalizedString("settings.general.tts.title", comment: "Card title")
            internal static let ttsSubtitle = NSLocalizedString("settings.general.tts.subtitle", comment: "Card subtitle")
            internal static let ttsLanguageTitle = NSLocalizedString("settings.general.tts.language_title", comment: "Label")
            internal static let ttsLanguageDescription = NSLocalizedString("settings.general.tts.language_description", comment: "Description")
            internal static let ttsEngineDescription = NSLocalizedString("settings.general.tts.engine_description", comment: "Description")
            internal static let languagesTitle = NSLocalizedString("settings.general.languages.title", comment: "Card title")
            internal static let languagesSubtitle = NSLocalizedString("settings.general.languages.subtitle", comment: "Card subtitle")
            internal static let recordingTitle = NSLocalizedString("settings.general.recording.title", comment: "Card title")
            internal static let recordingSubtitle = NSLocalizedString("settings.general.recording.subtitle", comment: "Card subtitle")
            internal static let voiceMemosImportTitle = NSLocalizedString("settings.general.voice_memos_import.title", comment: "Card title")
            internal static let voiceMemosImportSubtitle = NSLocalizedString("settings.general.voice_memos_import.subtitle", comment: "Card subtitle")
            internal static let voiceMemosAutoImportTitle = NSLocalizedString("settings.general.voice_memos_auto_import.title", comment: "Toggle title")
            internal static let voiceMemosAutoImportDescription = NSLocalizedString("settings.general.voice_memos_auto_import.description", comment: "Toggle description")
            internal static let realtimeEngineTitle = NSLocalizedString("settings.general.recording.realtime_engine_title", comment: "Label")
            internal static let engineTitle = NSLocalizedString("settings.general.recording.engine", comment: "Picker title")
            internal static let realtimeEngineDescription = NSLocalizedString("settings.general.recording.realtime_engine_description", comment: "Description")
            internal static let flushBuffersTitle = NSLocalizedString("settings.general.recording.flush_buffers_title", comment: "Toggle title")
            internal static let flushBuffersDescription = NSLocalizedString("settings.general.recording.flush_buffers_description", comment: "Toggle description")
            internal static let flushIntervalTitle = NSLocalizedString("settings.general.recording.flush_interval_title", comment: "Label")
            internal static let flushIntervalDescription = NSLocalizedString("settings.general.recording.flush_interval_description", comment: "Description")
            internal static let silenceDurationTitle = NSLocalizedString("settings.general.recording.silence_duration_title", comment: "Label")
            internal static let silenceDurationDescription = NSLocalizedString("settings.general.recording.silence_duration_description", comment: "Description")
            internal static let splitActivationDelayTitle = NSLocalizedString("settings.general.recording.split_activation_delay_title", comment: "Label")
            internal static let splitActivationDelayDescription = NSLocalizedString("settings.general.recording.split_activation_delay_description", comment: "Description")
            internal static let splitCountdownDurationTitle = NSLocalizedString("settings.general.recording.split_countdown_duration_title", comment: "Label")
            internal static let splitCountdownDurationDescription = NSLocalizedString("settings.general.recording.split_countdown_duration_description", comment: "Description")
            internal static let silenceLevelThresholdTitle = NSLocalizedString("settings.general.recording.silence_level_threshold_title", comment: "Label")
            internal static let silenceLevelThresholdDescription = NSLocalizedString("settings.general.recording.silence_level_threshold_description", comment: "Description")
            internal static let silenceGateFloorTitle = NSLocalizedString("settings.general.recording.silence_gate_floor_title", comment: "Label")
            internal static let silenceGateFloorDescription = NSLocalizedString("settings.general.recording.silence_gate_floor_description", comment: "Description")
            internal static let silenceCardTitle = NSLocalizedString("settings.general.silence.title", comment: "Card title")
            internal static let silenceCardSubtitle = NSLocalizedString("settings.general.silence.subtitle", comment: "Card subtitle")
            internal static let microTrimFloorTitle = NSLocalizedString("settings.general.silence.micro_trim_floor_title", comment: "Label")
            internal static let microTrimFloorDescription = NSLocalizedString("settings.general.silence.micro_trim_floor_description", comment: "Description")
            internal static let visionModelTitle = NSLocalizedString("settings.general.vision_model.title", comment: "Card title")
            internal static let visionModelSubtitle = NSLocalizedString("settings.general.vision_model.subtitle", comment: "Card subtitle")
            internal static let appleVisionFrameworkTitle = NSLocalizedString("settings.general.vision_model.apple_vision_framework_title", comment: "Title")
            internal static let appleVisionFrameworkDescription = NSLocalizedString("settings.general.vision_model.apple_vision_framework_description", comment: "Description")
            internal static let visionGeminiDescription = NSLocalizedString("settings.general.vision_model.gemini_description", comment: "Description")
            internal static let modelId = NSLocalizedString("settings.general.vision_model.model_id", comment: "Text field placeholder")
            internal static let visionOpenRouterDescription = NSLocalizedString("settings.general.vision_model.openrouter_description", comment: "Description")
            internal static let processingTitle = NSLocalizedString("settings.general.processing.title", comment: "Card title")
            internal static let processingSubtitle = NSLocalizedString("settings.general.processing.subtitle", comment: "Card subtitle")
            internal static let processingOCRTitle = NSLocalizedString("settings.general.processing.ocr_title", comment: "Toggle title")
            internal static let processingOCRDescription = NSLocalizedString("settings.general.processing.ocr_description", comment: "Toggle description")
            internal static let processingAudioTitle = NSLocalizedString("settings.general.processing.audio_title", comment: "Toggle title")
            internal static let processingAudioDescription = NSLocalizedString("settings.general.processing.audio_description", comment: "Toggle description")
            internal static let processingNoteCardTitle = NSLocalizedString("settings.general.processing.notecard_title", comment: "Toggle title")
            internal static let processingNoteCardDescription = NSLocalizedString("settings.general.processing.notecard_description", comment: "Toggle description")
            internal static let processingAutoRouteTitle = NSLocalizedString("settings.general.processing.auto_route_title", comment: "Toggle title")
            internal static let processingAutoRouteDescription = NSLocalizedString("settings.general.processing.auto_route_description", comment: "Toggle description")

            internal static func cardTextLimitValue(_ count: Int) -> String {
                let format = NSLocalizedString("settings.general.card_text_limit.value_fmt", comment: "Card text limit value")
                return String(format: format, locale: Locale.current, count)
            }

            internal static func secondsValue(_ value: Double) -> String {
                let format = NSLocalizedString("settings.general.seconds_value_fmt", comment: "Seconds value")
                return String(format: format, locale: Locale.current, value)
            }

            internal static func percentValue(_ value: Double) -> String {
                let format = NSLocalizedString("settings.general.percent_value_fmt", comment: "Percent value")
                return String(format: format, locale: Locale.current, value * 100)
            }

            internal enum LanguageOption {
                internal static let autoDetected = NSLocalizedString("settings.general.language.auto_detected", comment: "Option")
                internal static let english = NSLocalizedString("settings.general.language.english", comment: "Option")
                internal static let russian = NSLocalizedString("settings.general.language.russian", comment: "Option")
                internal static let spanish = NSLocalizedString("settings.general.language.spanish", comment: "Option")
                internal static let french = NSLocalizedString("settings.general.language.french", comment: "Option")
                internal static let german = NSLocalizedString("settings.general.language.german", comment: "Option")
                internal static let chinese = NSLocalizedString("settings.general.language.chinese", comment: "Option")
                internal static let japanese = NSLocalizedString("settings.general.language.japanese", comment: "Option")
            }

            internal enum TTSOption {
                internal static let systemDefault = NSLocalizedString("settings.general.tts.option.system_default", comment: "Option")
                internal static let englishUS = NSLocalizedString("settings.general.tts.option.english_us", comment: "Option")
                internal static let englishUK = NSLocalizedString("settings.general.tts.option.english_uk", comment: "Option")
                internal static let spanishSpain = NSLocalizedString("settings.general.tts.option.spanish_spain", comment: "Option")
                internal static let frenchFrance = NSLocalizedString("settings.general.tts.option.french_france", comment: "Option")
                internal static let germanGermany = NSLocalizedString("settings.general.tts.option.german_germany", comment: "Option")
                internal static let italianItaly = NSLocalizedString("settings.general.tts.option.italian_italy", comment: "Option")
                internal static let portugueseBrazil = NSLocalizedString("settings.general.tts.option.portuguese_brazil", comment: "Option")
                internal static let russianRussia = NSLocalizedString("settings.general.tts.option.russian_russia", comment: "Option")
                internal static let ukrainianUkraine = NSLocalizedString("settings.general.tts.option.ukrainian_ukraine", comment: "Option")
                internal static let chineseSimplified = NSLocalizedString("settings.general.tts.option.chinese_simplified", comment: "Option")
                internal static let chineseTraditional = NSLocalizedString("settings.general.tts.option.chinese_traditional", comment: "Option")
                internal static let japaneseJapan = NSLocalizedString("settings.general.tts.option.japanese_japan", comment: "Option")
                internal static let koreanKorea = NSLocalizedString("settings.general.tts.option.korean_korea", comment: "Option")
            }
        }

        internal enum Development {
            internal static let profilingTitle = NSLocalizedString("settings.development.profiling.title", comment: "Card title")
            internal static let profilingSubtitle = NSLocalizedString("settings.development.profiling.subtitle", comment: "Card subtitle")
            internal static let enableProfilingTitle = NSLocalizedString("settings.development.profiling.enable_title", comment: "Toggle title")
            internal static let enableProfilingDescription = NSLocalizedString("settings.development.profiling.enable_description", comment: "Toggle description")
            internal static let autoSaveIntervalTitle = NSLocalizedString("settings.development.profiling.auto_save_interval_title", comment: "Value row title")
            internal static let off = NSLocalizedString("settings.development.profiling.off", comment: "Off state")
            internal static let saveProfilingReport = NSLocalizedString("settings.development.profiling.save_report", comment: "Button")
            internal static let profilingOn = NSLocalizedString("settings.development.profiling.on_status", comment: "Status")
            internal static let profilingOff = NSLocalizedString("settings.development.profiling.off_status", comment: "Status")
            internal static let performanceTuningTitle = NSLocalizedString("settings.development.performance.title", comment: "Card title")
            internal static let performanceTuningSubtitle = NSLocalizedString("settings.development.performance.subtitle", comment: "Card subtitle")
            internal static let searchDebounceTitle = NSLocalizedString("settings.development.performance.search_debounce_title", comment: "Value row title")
            internal static let regexCacheLimitTitle = NSLocalizedString("settings.development.performance.regex_cache_limit_title", comment: "Value row title")
            internal static let imageCacheLimitTitle = NSLocalizedString("settings.development.performance.image_cache_limit_title", comment: "Value row title")
            internal static let applyCacheLimits = NSLocalizedString("settings.development.performance.apply_cache_limits", comment: "Button")
            internal static let resetToDefaults = NSLocalizedString("settings.development.performance.reset_to_defaults", comment: "Button")
            internal static let performanceTuningHint = NSLocalizedString("settings.development.performance.hint", comment: "Hint")

            internal static func minutes(_ value: Int) -> String {
                let format = NSLocalizedString("settings.development.profiling.minutes_fmt", comment: "Minutes value")
                return String(format: format, locale: Locale.current, value)
            }

            internal static func milliseconds(_ value: Int) -> String {
                let format = NSLocalizedString("settings.development.performance.milliseconds_fmt", comment: "Milliseconds value")
                return String(format: format, locale: Locale.current, value)
            }
        }

        internal enum Agent {
            internal static let profileTitle = NSLocalizedString("settings.agent.profile.title", comment: "Card title")
            internal static let profileSubtitle = NSLocalizedString("settings.agent.profile.subtitle", comment: "Card subtitle")
            internal static let profilePickerTitle = NSLocalizedString("settings.agent.profile.picker_title", comment: "Picker title")
            internal static let hearModelTitle = NSLocalizedString("settings.agent.hear_model.title", comment: "Card title")
            internal static let hearModelDescription = NSLocalizedString("settings.agent.hear_model.description", comment: "Card description")
            internal static let understandModelTitle = NSLocalizedString("settings.agent.understand_model.title", comment: "Card title")
            internal static let understandModelDescription = NSLocalizedString("settings.agent.understand_model.description", comment: "Card description")
            internal static let thinkModelTitle = NSLocalizedString("settings.agent.think_model.title", comment: "Card title")
            internal static let thinkModelDescription = NSLocalizedString("settings.agent.think_model.description", comment: "Card description")
            internal static let capabilitiesTitle = NSLocalizedString("settings.agent.capabilities.title", comment: "Card title")
            internal static let capabilitiesSubtitle = NSLocalizedString("settings.agent.capabilities.subtitle", comment: "Card subtitle")
            internal static let enableToolUseTitle = NSLocalizedString("settings.agent.capabilities.enable_tool_use_title", comment: "Toggle title")
            internal static let enableToolUseDescription = NSLocalizedString("settings.agent.capabilities.enable_tool_use_description", comment: "Toggle description")
            internal static let logInteractionsTitle = NSLocalizedString("settings.agent.capabilities.log_interactions_title", comment: "Toggle title")
            internal static let logInteractionsDescription = NSLocalizedString("settings.agent.capabilities.log_interactions_description", comment: "Toggle description")
            internal static let apiKeysTitle = NSLocalizedString("settings.agent.api_keys.title", comment: "Section title")
            internal static let apiKeysDescription = NSLocalizedString("settings.agent.api_keys.description", comment: "Section description")
            internal static let geminiApiKeyTitle = NSLocalizedString("settings.agent.api_keys.gemini_title", comment: "Label")
            internal static let geminiApiKeyPlaceholder = NSLocalizedString("settings.agent.api_keys.gemini_placeholder", comment: "Placeholder")
            internal static let openRouterKeyTitle = NSLocalizedString("settings.agent.api_keys.openrouter_title", comment: "Label")
            internal static let openRouterKeyPlaceholder = NSLocalizedString("settings.agent.api_keys.openrouter_placeholder", comment: "Placeholder")
            internal static let getKey = NSLocalizedString("settings.agent.api_keys.get_key", comment: "Link title")
            internal static let testConnection = NSLocalizedString("settings.agent.api_keys.test_connection", comment: "Button")
            internal static let reflexionDepthTitle = NSLocalizedString("settings.agent.reflexion_depth.title", comment: "Value row title")
            internal static let reflexionDepthDescription = NSLocalizedString("settings.agent.reflexion_depth.description", comment: "Description")
            internal static let customInstructionsTitle = NSLocalizedString("settings.agent.custom_instructions.title", comment: "Section title")
            internal static let customInstructionsDescription = NSLocalizedString("settings.agent.custom_instructions.description", comment: "Section description")
            internal static let recursionDepthTitle = NSLocalizedString("settings.agent.recursion_depth.title", comment: "Value row title")
            internal static let maxApiRetriesTitle = NSLocalizedString("settings.agent.max_api_retries.title", comment: "Value row title")
            internal static let maxApiRetriesDescription = NSLocalizedString("settings.agent.max_api_retries.description", comment: "Description")
            internal static let searchResultsLimitTitle = NSLocalizedString("settings.agent.search_results_limit.title", comment: "Value row title")
            internal static let searchResultsLimitDescription = NSLocalizedString("settings.agent.search_results_limit.description", comment: "Description")
        }
    }

    internal enum Maintenance {
        internal static let windowTitle = NSLocalizedString("maintenance.window.title", comment: "Window title")

        internal enum Section {
            internal static let databaseInformation = NSLocalizedString("maintenance.section.database_information", comment: "Section header")
            internal static let missingMetadata = NSLocalizedString("maintenance.section.missing_metadata", comment: "Section header")
            internal static let duplicateCleanup = NSLocalizedString("maintenance.section.duplicate_cleanup", comment: "Section header")
            internal static let orphanedTextFilesCleanup = NSLocalizedString("maintenance.section.orphaned_text_files_cleanup", comment: "Section header")
            internal static let maintenanceActions = NSLocalizedString("maintenance.section.maintenance_actions", comment: "Section header")
            internal static let systemPermissions = NSLocalizedString("maintenance.section.system_permissions", comment: "Section header")
        }

        internal enum Tab {
            internal static let overview = NSLocalizedString("maintenance.tab.overview", comment: "Tab title")
            internal static let permissions = NSLocalizedString("maintenance.tab.permissions", comment: "Tab title")
        }

        internal enum Database {
            internal static let location = NSLocalizedString("maintenance.database.location", comment: "Database field")
            internal static let size = NSLocalizedString("maintenance.database.size", comment: "Database field")
            internal static let notes = NSLocalizedString("maintenance.database.notes", comment: "Database field")
        }

        internal enum Missing {
            internal static let processing = NSLocalizedString("maintenance.missing.processing", comment: "Status")
            internal static let processMissingHint = NSLocalizedString("maintenance.missing.process_missing_hint", comment: "Hint")
            internal static let processMissing = NSLocalizedString("maintenance.missing.process_missing", comment: "Action")
            internal static let allNotesHaveMetadata = NSLocalizedString("maintenance.missing.all_notes_have_metadata", comment: "Status")

            internal static func missingNoteCard(_ count: Int) -> String {
                let format = NSLocalizedString("maintenance.missing.missing_notecard_fmt", comment: "Missing notecard count")
                return String(format: format, locale: Locale.current, count)
            }

            internal static func unprocessedFlag(_ count: Int) -> String {
                let format = NSLocalizedString("maintenance.missing.unprocessed_flag_fmt", comment: "Unprocessed flag count")
                return String(format: format, locale: Locale.current, count)
            }

            internal static func emptyTitleOrSummary(_ count: Int) -> String {
                let format = NSLocalizedString("maintenance.missing.empty_title_or_summary_fmt", comment: "Empty fields count")
                return String(format: format, locale: Locale.current, count)
            }
        }

        internal enum Duplicates {
            internal static let scanning = NSLocalizedString("maintenance.duplicates.scanning", comment: "Status")
            internal static let dryRun = NSLocalizedString("maintenance.duplicates.dry_run", comment: "Action")
            internal static let remove = NSLocalizedString("maintenance.duplicates.remove", comment: "Action")
            internal static let scan = NSLocalizedString("maintenance.duplicates.scan", comment: "Action")
            internal static let noneFound = NSLocalizedString("maintenance.duplicates.none_found", comment: "Status")
            internal static let scanComplete = NSLocalizedString("maintenance.duplicates.scan_complete", comment: "Status")
            internal static let removing = NSLocalizedString("maintenance.duplicates.removing", comment: "Status")
            internal static let dryRunResultsTitle = NSLocalizedString("maintenance.duplicates.dry_run_results_title", comment: "Sheet title")

            internal static func foundGroups(_ count: Int) -> String {
                let format = NSLocalizedString("maintenance.duplicates.found_groups_fmt", comment: "Duplicate groups count")
                return String(format: format, locale: Locale.current, count)
            }

            internal static func totalToRemove(_ count: Int) -> String {
                let format = NSLocalizedString("maintenance.duplicates.total_to_remove_fmt", comment: "Total duplicates to remove")
                return String(format: format, locale: Locale.current, count)
            }

            internal static func scanningProgress(processed: Int, total: Int) -> String {
                let format = NSLocalizedString("maintenance.duplicates.scanning_progress_fmt", comment: "Scan progress")
                return String(format: format, locale: Locale.current, processed, total)
            }

            internal static func removed(_ count: Int) -> String {
                let format = NSLocalizedString("maintenance.duplicates.removed_fmt", comment: "Removed duplicates")
                return String(format: format, locale: Locale.current, count)
            }

            internal enum DryRun {
                internal static let header = NSLocalizedString("maintenance.duplicates.dry_run.header", comment: "Dry run header")
                internal static let duplicatesToRemove = NSLocalizedString("maintenance.duplicates.dry_run.duplicates_to_remove", comment: "Dry run section")

                internal static func group(_ index: Int) -> String {
                    let format = NSLocalizedString("maintenance.duplicates.dry_run.group_fmt", comment: "Dry run group label")
                    return String(format: format, locale: Locale.current, index)
                }

                internal static func originalKept(_ name: String) -> String {
                    let format = NSLocalizedString("maintenance.duplicates.dry_run.original_kept_fmt", comment: "Dry run original file label")
                    return String(format: format, locale: Locale.current, name)
                }

                internal static func created(_ date: String) -> String {
                    let format = NSLocalizedString("maintenance.duplicates.dry_run.created_fmt", comment: "Dry run created date")
                    return String(format: format, locale: Locale.current, date)
                }

                internal static func duplicateEntry(name: String, created: String) -> String {
                    let format = NSLocalizedString("maintenance.duplicates.dry_run.duplicate_entry_fmt", comment: "Dry run duplicate entry")
                    return String(format: format, locale: Locale.current, name, created)
                }

                internal static func totalFilesToRemove(_ count: Int) -> String {
                    let format = NSLocalizedString("maintenance.duplicates.dry_run.total_files_to_remove_fmt", comment: "Dry run total")
                    return String(format: format, locale: Locale.current, count)
                }
            }
        }

        internal enum Orphans {
            internal static let scanning = NSLocalizedString("maintenance.orphans.scanning", comment: "Status")
            internal static let scanningForFiles = NSLocalizedString("maintenance.orphans.scanning_for_files", comment: "Status")
            internal static let dryRun = NSLocalizedString("maintenance.orphans.dry_run", comment: "Action")
            internal static let remove = NSLocalizedString("maintenance.orphans.remove", comment: "Action")
            internal static let scan = NSLocalizedString("maintenance.orphans.scan", comment: "Action")
            internal static let noneFound = NSLocalizedString("maintenance.orphans.none_found", comment: "Status")
            internal static let deleting = NSLocalizedString("maintenance.orphans.deleting", comment: "Status")
            internal static let recordingsDirectoryNotFound = NSLocalizedString("maintenance.orphans.recordings_directory_not_found", comment: "Status")
            internal static let dryRunTitle = NSLocalizedString("maintenance.orphans.dry_run_title", comment: "Sheet title")

            internal static func found(_ count: Int) -> String {
                let format = NSLocalizedString("maintenance.orphans.found_fmt", comment: "Found orphan files")
                return String(format: format, locale: Locale.current, count)
            }

            internal static func errorScanning(_ message: String) -> String {
                let format = NSLocalizedString("maintenance.orphans.error_scanning_fmt", comment: "Error while scanning orphans")
                return String(format: format, locale: Locale.current, message)
            }

            internal static func deleted(_ count: Int) -> String {
                let format = NSLocalizedString("maintenance.orphans.deleted_fmt", comment: "Deleted orphan files")
                return String(format: format, locale: Locale.current, count)
            }

            internal enum DryRun {
                internal static let header = NSLocalizedString("maintenance.orphans.dry_run.header", comment: "Dry run header")
                internal static let description = NSLocalizedString("maintenance.orphans.dry_run.description", comment: "Dry run description")

                internal static func total(_ count: Int) -> String {
                    let format = NSLocalizedString("maintenance.orphans.dry_run.total_fmt", comment: "Dry run total")
                    return String(format: format, locale: Locale.current, count)
                }
            }
        }

        internal enum Action {
            internal static let clearChatHistory = NSLocalizedString("maintenance.action.clear_chat_history", comment: "Action")
            internal static let clearLogs = NSLocalizedString("maintenance.action.clear_logs", comment: "Action")
        }

        internal enum Permissions {
            internal static let description = NSLocalizedString("maintenance.permissions.description", comment: "Description")
            internal static let microphone = NSLocalizedString("maintenance.permissions.microphone", comment: "Permission title")
            internal static let microphoneDetail = NSLocalizedString("maintenance.permissions.microphone_detail", comment: "Permission detail")
            internal static let speechRecognition = NSLocalizedString("maintenance.permissions.speech_recognition", comment: "Permission title")
            internal static let speechRecognitionDetail = NSLocalizedString("maintenance.permissions.speech_recognition_detail", comment: "Permission detail")
            internal static let accessibility = NSLocalizedString("maintenance.permissions.accessibility", comment: "Permission title")
            internal static let accessibilityDetail = NSLocalizedString("maintenance.permissions.accessibility_detail", comment: "Permission detail")
            internal static let screenRecording = NSLocalizedString("maintenance.permissions.screen_recording", comment: "Permission title")
            internal static let screenRecordingDetail = NSLocalizedString("maintenance.permissions.screen_recording_detail", comment: "Permission detail")
            internal static let refresh = NSLocalizedString("maintenance.permissions.refresh", comment: "Action")
            internal static let request = NSLocalizedString("maintenance.permissions.request", comment: "Action")
            internal static let openSettings = NSLocalizedString("maintenance.permissions.open_settings", comment: "Action")

            internal enum Status {
                internal static let authorized = NSLocalizedString("maintenance.permissions.status.authorized", comment: "Permission status")
                internal static let denied = NSLocalizedString("maintenance.permissions.status.denied", comment: "Permission status")
                internal static let notDetermined = NSLocalizedString("maintenance.permissions.status.not_determined", comment: "Permission status")
                internal static let restricted = NSLocalizedString("maintenance.permissions.status.restricted", comment: "Permission status")
                internal static let unavailable = NSLocalizedString("maintenance.permissions.status.unavailable", comment: "Permission status")
                internal static let unknown = NSLocalizedString("maintenance.permissions.status.unknown", comment: "Permission status")
            }
        }

        internal enum Status {
            internal static let calculating = NSLocalizedString("maintenance.status.calculating", comment: "Status")
            internal static let starting = NSLocalizedString("maintenance.status.starting", comment: "Status")
            internal static let chatHistoryCleared = NSLocalizedString("maintenance.status.chat_history_cleared", comment: "Status")

            internal static func processing(processed: Int, total: Int) -> String {
                let format = NSLocalizedString("maintenance.status.processing_fmt", comment: "Progress")
                return String(format: format, locale: Locale.current, processed, total)
            }

            internal static func logsCleared(_ count: Int) -> String {
                let format = NSLocalizedString("maintenance.status.logs_cleared_fmt", comment: "Status with deleted logs count")
                return String(format: format, locale: Locale.current, count)
            }

        }
    }

    internal enum QueueStatus {
        internal static let title = NSLocalizedString("queue_status.title", comment: "Window title")
        internal static func activeTotal(active: Int, total: Int) -> String {
            let format = NSLocalizedString("queue_status.active_total_fmt", comment: "Queue stats")
            return String(format: format, locale: Locale.current, active, total)
        }
        internal static let clearFinishedJobs = NSLocalizedString("queue_status.clear_finished_jobs", comment: "Tooltip")
        internal static let noJobs = NSLocalizedString("queue_status.no_jobs", comment: "Empty state")
        internal static let typeOCR = NSLocalizedString("queue_status.type.ocr", comment: "Type label")
        internal static let typeAudio = NSLocalizedString("queue_status.type.audio", comment: "Type label")
        internal static let typeExtract = NSLocalizedString("queue_status.type.extract", comment: "Type label")
        internal static let typeChat = NSLocalizedString("queue_status.type.chat", comment: "Type label")
        internal static let typeAnalysis = NSLocalizedString("queue_status.type.analysis", comment: "Type label")
        internal static let typeOther = NSLocalizedString("queue_status.type.other", comment: "Type label")
    }

    internal enum QueueStatusBar {
        internal static let activity = NSLocalizedString("queue_status_bar.activity", comment: "Status bar menu title")
        internal static let pausedSuffix = NSLocalizedString("queue_status_bar.paused_suffix", comment: "Paused suffix")
        internal static let resumeVisionOCR = NSLocalizedString("queue_status_bar.resume_vision_ocr", comment: "Action")
        internal static let pauseVisionOCR = NSLocalizedString("queue_status_bar.pause_vision_ocr", comment: "Action")
        internal static let quitWimm = NSLocalizedString("queue_status_bar.quit_wimm", comment: "Action")

        internal static func visionPending(_ count: Int) -> String {
            let format = NSLocalizedString("queue_status_bar.vision_pending_fmt", comment: "Vision pending count")
            return String(format: format, locale: Locale.current, count)
        }

        internal static func transcriptionPending(_ count: Int) -> String {
            let format = NSLocalizedString("queue_status_bar.transcription_pending_fmt", comment: "Transcription pending count")
            return String(format: format, locale: Locale.current, count)
        }

        internal static func processingPending(_ count: Int) -> String {
            let format = NSLocalizedString("queue_status_bar.processing_pending_fmt", comment: "Processing pending count")
            return String(format: format, locale: Locale.current, count)
        }

        internal enum Accessibility {
            internal static let status = NSLocalizedString("queue_status_bar.accessibility.status", comment: "Accessibility label")
            internal static let idle = NSLocalizedString("queue_status_bar.accessibility.idle", comment: "Accessibility label")
        }
    }

    internal enum HUD {

        internal enum Error {
            internal static let unsupported = NSLocalizedString("hud.error.unsupported", comment: "HUD error: feature unsupported")
            internal static let permission = NSLocalizedString("hud.error.permission", comment: "HUD error: permission denied")
            internal static let selectNotesFirst = NSLocalizedString("hud.error.select_notes_first", comment: "HUD error: ask user to select notes")
            internal static let recordingFailed = NSLocalizedString("hud.error.recording_failed", comment: "HUD error: recording failed")
            internal static let recordingNotFound = NSLocalizedString("hud.error.recording_not_found", comment: "HUD error: recording not found")
            internal static let transcriptionDisabled = NSLocalizedString("hud.error.transcription_disabled", comment: "HUD error: transcription disabled")
            internal static let transcriptionFailed = NSLocalizedString("hud.error.transcription_failed", comment: "HUD error: transcription failed")
            internal static let emptyInstruction = NSLocalizedString("hud.error.empty_instruction", comment: "HUD error: empty instruction")
            internal static let noNotes = NSLocalizedString("hud.error.no_notes", comment: "HUD error: no notes found")
            internal static let noRaw = NSLocalizedString("hud.error.no_raw", comment: "HUD error: no raw transcription available")

            internal static func failed(_ message: String) -> String {
                let format = NSLocalizedString("hud.error.failed_fmt", comment: "HUD error: generic failure with message")
                return String(format: format, locale: Locale.current, message)
            }

            internal enum Summary {
                internal static let noVisibleNotes = NSLocalizedString("hud.summary.error.no_visible_notes", comment: "HUD error: no visible notes")
                internal static let noValidNotes = NSLocalizedString("hud.summary.error.no_valid_notes", comment: "HUD error: no valid notes")
                internal static let noSelectedNotes = NSLocalizedString("hud.summary.error.no_selected_notes", comment: "HUD error: no selected notes")
                internal static func failed(_ message: String) -> String {
                    let format = NSLocalizedString("hud.summary.error.failed_fmt", comment: "HUD error: summary failed with message")
                    return String(format: format, locale: Locale.current, message)
                }
            }

            internal enum Analysis {
                internal static let noNotes = NSLocalizedString("hud.analysis.error.no_notes", comment: "HUD error: no notes for analysis")
                internal static func failed(_ message: String) -> String {
                    let format = NSLocalizedString("hud.analysis.error.failed_fmt", comment: "HUD error: analysis failed with message")
                    return String(format: format, locale: Locale.current, message)
                }
            }
        }

        internal enum Agent {
            internal static let started = NSLocalizedString("hud.agent.started", comment: "HUD: agent started")
        }

        internal enum LLM {
            internal static let thinking = NSLocalizedString("hud.llm.thinking", comment: "HUD: LLM is thinking")
            internal static let failed = NSLocalizedString("hud.llm.failed", comment: "HUD: LLM call failed")
        }

        internal enum Instruction {
            internal static let recording = NSLocalizedString("hud.instruction.recording", comment: "HUD: recording instruction")
            internal static let performing = NSLocalizedString("hud.instruction.performing", comment: "HUD: performing instruction")
        }

        internal enum Summary {
            internal static let success = NSLocalizedString("hud.summary.success", comment: "HUD: summary created")
            internal static func processing(count: Int) -> String {
                let format = NSLocalizedString("hud.summary.processing_fmt", comment: "HUD: summarizing notes")
                return String(format: format, locale: Locale.current, count)
            }
        }

        internal enum Export {
            internal static let chronicleCopied = NSLocalizedString("hud.export.chronicle_copied", comment: "HUD: chronicle copied to clipboard")
        }

        internal enum Clipboard {
            internal static let noActiveFile = NSLocalizedString("hud.clipboard.no_active_file", comment: "HUD: no active file")
            internal static let nothingToPaste = NSLocalizedString("hud.clipboard.nothing_to_paste", comment: "HUD: nothing to paste")

            internal static func attachedItems(_ count: Int) -> String {
                let format = NSLocalizedString("hud.clipboard.attached_items_fmt", comment: "HUD: attached items count")
                return String(format: format, locale: Locale.current, count)
            }

            internal static func failedToAttach(_ files: String) -> String {
                let format = NSLocalizedString("hud.clipboard.failed_to_attach_fmt", comment: "HUD: failed to attach files")
                return String(format: format, locale: Locale.current, files)
            }
        }

        internal enum Insert {
            internal static let noText = NSLocalizedString("hud.insert.no_text", comment: "HUD: no insertable Wimm text")
            internal static let copiedOnly = NSLocalizedString("hud.insert.copied_only", comment: "HUD: copied text when auto-paste unavailable")
            internal static let inserted = NSLocalizedString("hud.insert.inserted", comment: "HUD: pasted the latest note")
        }

        internal enum Action {
            internal static let paste = NSLocalizedString("hud.action.paste", comment: "Button")
            internal static let edit = NSLocalizedString("hud.action.edit", comment: "Tooltip")
            internal static let screenshot = NSLocalizedString("hud.action.screenshot", comment: "Tooltip")
            internal static let pasteFromClipboard = NSLocalizedString("hud.action.paste_from_clipboard", comment: "Tooltip")
            internal static let stop = NSLocalizedString("hud.action.stop", comment: "Tooltip")
            internal static let close = NSLocalizedString("hud.action.close", comment: "Tooltip")
            internal static let focusNote = NSLocalizedString("hud.action.focus_note", comment: "Tooltip")
        }

        internal enum Edit {
            internal static let editTranscript = NSLocalizedString("hud.edit.edit_transcript", comment: "Section title")
            internal static let pasteNow = NSLocalizedString("hud.edit.paste_now", comment: "Button")
        }

        internal enum Status {
            internal static let streaming = NSLocalizedString("hud.status.streaming", comment: "Status label")
            internal static let listening = NSLocalizedString("hud.status.listening", comment: "Status label")
            internal static let transcribing = NSLocalizedString("hud.status.transcribing", comment: "Status label")
            internal static let done = NSLocalizedString("hud.status.done", comment: "Status label")
        }

        internal enum Session {
            internal static func notes(_ count: Int) -> String {
                let format = NSLocalizedString("hud.session.notes_fmt", comment: "Streaming notes count")
                return String(format: format, locale: Locale.current, count)
            }

            internal static func splitIn(_ seconds: Double) -> String {
                let format = NSLocalizedString("hud.session.split_in_fmt", comment: "Split timer")
                return String(format: format, locale: Locale.current, seconds)
            }
        }

        internal enum Analysis {
            internal static let successSaved = NSLocalizedString("hud.analysis.success_saved", comment: "HUD: analysis view saved")
            internal static func processing(count: Int) -> String {
                let format = NSLocalizedString("hud.analysis.processing_fmt", comment: "HUD: analyzing cards")
                return String(format: format, locale: Locale.current, count)
            }
        }

        internal enum Transcription {
           internal static let processing = NSLocalizedString("hud.transcription.processing", comment: "HUD: transcription in progress")
           internal static let failedPlaceholder = NSLocalizedString("transcription.failed_placeholder", comment: "Placeholder text in note when transcription fails")
        }

        internal enum Queue {
            internal enum TypeLabel {
                internal static let recording = NSLocalizedString("hud.queue.type.recording", comment: "Status label")
                internal static let transcribing = NSLocalizedString("hud.queue.type.transcribing", comment: "Status label")
                internal static let transcribingQueued = NSLocalizedString("hud.queue.type.transcribing_queued", comment: "Status label")
                internal static let ocr = NSLocalizedString("hud.queue.type.ocr", comment: "Status label")
                internal static let ocrQueued = NSLocalizedString("hud.queue.type.ocr_queued", comment: "Status label")
                internal static let metadata = NSLocalizedString("hud.queue.type.metadata", comment: "Status label")
                internal static let metadataQueued = NSLocalizedString("hud.queue.type.metadata_queued", comment: "Status label")
                internal static let chat = NSLocalizedString("hud.queue.type.chat", comment: "Status label")
                internal static let chatQueued = NSLocalizedString("hud.queue.type.chat_queued", comment: "Status label")
                internal static let analysis = NSLocalizedString("hud.queue.type.analysis", comment: "Status label")
                internal static let analysisQueued = NSLocalizedString("hud.queue.type.analysis_queued", comment: "Status label")
                internal static let generic = NSLocalizedString("hud.queue.type.generic", comment: "Status label")
                internal static let genericQueued = NSLocalizedString("hud.queue.type.generic_queued", comment: "Status label")
                internal static let transcribed = NSLocalizedString("hud.queue.type.transcribed", comment: "Status label")
                internal static let analyzed = NSLocalizedString("hud.queue.type.analyzed", comment: "Status label")
                internal static let savedNotAnalyzed = NSLocalizedString("hud.queue.type.saved_not_analyzed", comment: "Status label")
                internal static let noSpeech = NSLocalizedString("hud.queue.type.no_speech", comment: "Status label")
                internal static let failed = NSLocalizedString("hud.queue.type.failed", comment: "Status label")
                internal static let awaitingTranscription = NSLocalizedString("hud.queue.type.awaiting_transcription", comment: "Status label")
                internal static let awaitingTextExtraction = NSLocalizedString("hud.queue.type.awaiting_text_extraction", comment: "Status label")
            }
        }

        internal enum Processing {
            internal static let disabled = NSLocalizedString("hud.processing.disabled", comment: "HUD: processing is disabled")
            internal static let generic = NSLocalizedString("hud.processing.generic", comment: "HUD: generic processing")

            internal static func progress(current: Int, total: Int) -> String {
                let format = NSLocalizedString("hud.processing.progress_fmt", comment: "HUD: processing progress format")
                return String(format: format, locale: Locale.current, current, total)
            }
        }

        internal enum NoteCards {
            internal static let allHaveMetadata = NSLocalizedString("hud.note_cards.all_have_metadata", comment: "HUD: all notes have metadata")

            internal static func foundMissing(_ count: Int) -> String {
                let format = NSLocalizedString("hud.note_cards.found_missing_fmt", comment: "HUD: found missing metadata")
                return String(format: format, locale: Locale.current, count)
            }

            internal static func enriched(_ count: Int) -> String {
                let format = NSLocalizedString("hud.note_cards.enriched_fmt", comment: "HUD: notes enriched")
                return String(format: format, locale: Locale.current, count)
            }

            internal static func failed(_ count: Int) -> String {
                let format = NSLocalizedString("hud.note_cards.failed_fmt", comment: "HUD: failed count")
                return String(format: format, locale: Locale.current, count)
            }
        }

        /// "Transcribe again" with a chosen kind, from the note list's context menu.
        internal enum Retranscribe {
            internal static let menu = NSLocalizedString("hud.retranscribe.menu", comment: "Context menu: transcribe again")
            internal static func menuSelected(_ count: Int) -> String {
                let format = NSLocalizedString("hud.retranscribe.menu_selected_fmt", comment: "Context menu: transcribe the selected notes again")
                return String(format: format, locale: Locale.current, count)
            }
            internal static func hearModel(_ model: String) -> String {
                let format = NSLocalizedString("hud.retranscribe.hear_model_fmt", comment: "Transcribe again with the hear model from Settings")
                return String(format: format, locale: Locale.current, model)
            }
            internal static let onDevice = NSLocalizedString("hud.retranscribe.on_device", comment: "Transcribe again on-device with Parakeet")
            internal static func cloud(_ model: String) -> String {
                let format = NSLocalizedString("hud.retranscribe.cloud_fmt", comment: "Transcribe again with the cloud model")
                return String(format: format, locale: Locale.current, model)
            }
            internal static let cloudPrivateMode = NSLocalizedString("hud.retranscribe.cloud_private_mode", comment: "Cloud transcription unavailable in private mode")
            internal static func started(_ count: Int) -> String {
                let format = NSLocalizedString("hud.retranscribe.started_fmt", comment: "HUD: bulk re-transcription queued")
                return String(format: format, locale: Locale.current, count)
            }
            internal static func progress(current: Int, total: Int) -> String {
                let format = NSLocalizedString("hud.retranscribe.progress_fmt", comment: "HUD: bulk re-transcription progress")
                return String(format: format, locale: Locale.current, current, total)
            }
            internal static func finished(done: Int, failed: Int) -> String {
                let format = NSLocalizedString("hud.retranscribe.finished_fmt", comment: "HUD: bulk re-transcription finished")
                return String(format: format, locale: Locale.current, done, failed)
            }
        }

        internal enum RetrySuspectedNoSpeech {
            internal static let none = NSLocalizedString("hud.retry_suspected_no_speech.none", comment: "HUD: no flagged notes to retry")

            internal static func started(_ count: Int) -> String {
                let format = NSLocalizedString("hud.retry_suspected_no_speech.started_fmt", comment: "HUD: started retrying flagged notes")
                return String(format: format, locale: Locale.current, count)
            }

            internal static func progress(current: Int, total: Int) -> String {
                let format = NSLocalizedString("hud.retry_suspected_no_speech.progress_fmt", comment: "HUD: progress while retrying flagged notes")
                return String(format: format, locale: Locale.current, current, total)
            }

            internal static func finished(_ count: Int) -> String {
                let format = NSLocalizedString("hud.retry_suspected_no_speech.finished_fmt", comment: "HUD: finished retrying flagged notes")
                return String(format: format, locale: Locale.current, count)
            }
        }

        internal enum Create {
            internal static let noteCreated = NSLocalizedString("hud.note.created", comment: "HUD: note created")
            internal static let artifactCreated = NSLocalizedString("hud.artifact.created", comment: "HUD: artifact created")
            internal static let artifactSaved = NSLocalizedString("hud.artifact.saved", comment: "HUD: artifact saved")
            internal static let failed = NSLocalizedString("hud.create.failed", comment: "HUD: create failed")
        }

        internal enum Trash {
            internal static let moved = NSLocalizedString("hud.trash.moved", comment: "HUD: moved to trash")
            internal static let restoreFailed = NSLocalizedString("hud.trash.restore_failed", comment: "HUD: restore failed")
            internal static let restored = NSLocalizedString("hud.trash.restored", comment: "HUD: restored")
            internal static let permanentlyDeleted = NSLocalizedString("hud.trash.permanently_deleted", comment: "HUD: permanently deleted")
            internal static let emptied = NSLocalizedString("hud.trash.emptied", comment: "HUD: trash emptied")
        }

        internal enum Recording {
            internal static let livePreviewUnavailable = NSLocalizedString("hud.recording.live_preview_unavailable", comment: "HUD info: live preview unavailable")

            internal enum Error {
                internal static let stopStreamingFirst = NSLocalizedString("hud.recording.error.stop_streaming_first", comment: "HUD error: must stop streaming first")
                internal static let stopFailed = NSLocalizedString("hud.recording.error.stop_failed", comment: "HUD error: stop failed")
                internal static let streamStartFailed = NSLocalizedString("hud.recording.error.stream_start_failed", comment: "HUD error: stream start failed")
                internal static let streamInterrupted = NSLocalizedString("hud.recording.error.stream_interrupted", comment: "HUD error: stream interrupted")
                internal static let streamSplitFailed = NSLocalizedString("hud.recording.error.stream_split_failed", comment: "HUD error: stream split failed")
            }

            internal enum Streaming {
                internal static let initialStatus = NSLocalizedString("hud.recording.streaming.status_initial", comment: "Initial status for streaming")
                internal static func noteSeparator(count: Int) -> String {
                    let format = NSLocalizedString("hud.recording.streaming.note_separator_fmt", comment: "Separator between streaming notes")
                    return String(format: format, locale: Locale.current, count)
                }
            }
        }

        internal enum Import {
            internal static let noImportableFiles = NSLocalizedString("hud.import.no_importable_files", comment: "HUD: no importable files")
            internal static let noActiveWindow = NSLocalizedString("hud.import.no_active_window", comment: "HUD: no active window")
            internal static let typeNotSupported = NSLocalizedString("hud.import.type_not_supported", comment: "HUD: import type not supported")
            internal static let starting = NSLocalizedString("hud.import.starting", comment: "HUD: starting import")
            internal static let processingInBackground = NSLocalizedString("hud.import.processing_in_background", comment: "HUD: processing in background")
            internal static let failed = NSLocalizedString("hud.import.failed", comment: "HUD: import failed")
            internal static let noFilesFound = NSLocalizedString("hud.import.no_files_found", comment: "HUD: no files found")

            internal static func recovered(count: Int) -> String {
                let format = NSLocalizedString("hud.import.recovered_fmt", comment: "HUD: recovered imports")
                return String(format: format, locale: Locale.current, count)
            }

            internal static func copying(current: Int, total: Int, name: String) -> String {
                let format = NSLocalizedString("hud.import.copying_fmt", comment: "HUD: copying progress format")
                return String(format: format, locale: Locale.current, current, total, name)
            }

            internal static func importedFilesRefreshing(_ count: Int) -> String {
                let format = NSLocalizedString("hud.import.imported_files_refreshing_fmt", comment: "HUD: imported files refreshing")
                return String(format: format, locale: Locale.current, count)
            }

            internal enum ENEX {
                internal static let starting = NSLocalizedString("hud.import.enex.starting", comment: "HUD: starting ENEX import")
                internal static let failed = NSLocalizedString("hud.import.enex.failed", comment: "HUD: ENEX import failed")
                internal static let noNotesFound = NSLocalizedString("hud.import.enex.no_notes_found", comment: "HUD: no ENEX notes found")

                internal static func importedNotesRefreshing(_ count: Int) -> String {
                    let format = NSLocalizedString("hud.import.enex.imported_notes_refreshing_fmt", comment: "HUD: imported ENEX notes refreshing")
                    return String(format: format, locale: Locale.current, count)
                }
            }

            internal enum Audio {
                internal static let failed = NSLocalizedString("hud.import.audio.failed", comment: "HUD: audio import failed")
                internal static let noneImported = NSLocalizedString("hud.import.audio.none_imported", comment: "HUD: no audio imported")

                internal static func importing(current: Int, total: Int, name: String) -> String {
                    let format = NSLocalizedString("hud.import.audio.importing_fmt", comment: "HUD: importing audio format")
                    return String(format: format, locale: Locale.current, current, total, name)
                }

                internal static func transcribing(current: Int, total: Int, name: String) -> String {
                    let format = NSLocalizedString("hud.import.audio.transcribing_fmt", comment: "HUD: transcribing audio format")
                    return String(format: format, locale: Locale.current, current, total, name)
                }

                internal static func importedRefreshing(_ count: Int) -> String {
                    let format = NSLocalizedString("hud.import.audio.imported_refreshing_fmt", comment: "HUD: imported audio refreshing")
                    return String(format: format, locale: Locale.current, count)
                }
            }

            internal enum AppleNotes {
                internal static let starting = NSLocalizedString("hud.import.apple_notes.starting", comment: "HUD: starting Apple Notes import")
                internal static let failed = NSLocalizedString("hud.import.apple_notes.failed", comment: "HUD: Apple Notes import failed")
                internal static let allAlreadyImported = NSLocalizedString("hud.import.apple_notes.all_already_imported", comment: "HUD: all Apple Notes already imported")

                internal static func importedRefreshing(_ count: Int) -> String {
                    let format = NSLocalizedString("hud.import.apple_notes.imported_refreshing_fmt", comment: "HUD: imported Apple Notes refreshing")
                    return String(format: format, locale: Locale.current, count)
                }

                internal static func importedRefreshingWithSkipped(imported: Int, skipped: Int) -> String {
                    let format = NSLocalizedString("hud.import.apple_notes.imported_refreshing_with_skipped_fmt", comment: "HUD: imported Apple Notes with skipped duplicates refreshing")
                    return String(format: format, locale: Locale.current, imported, skipped)
                }
            }

            internal static func skippedDuplicates(_ count: Int) -> String {
                let format = NSLocalizedString("hud.import.skipped_duplicates_fmt", comment: "HUD: skipped duplicates")
                return String(format: format, locale: Locale.current, count)
            }

            internal static func processingImage(_ name: String) -> String {
                let format = NSLocalizedString("hud.import.processing_image_fmt", comment: "HUD: processing image")
                return String(format: format, locale: Locale.current, name)
            }
        }

        internal enum Save {
            internal static let failed = NSLocalizedString("hud.save.failed", comment: "HUD: save failed")
        }

        internal enum OCR {
            internal static let disabled = NSLocalizedString("hud.ocr.disabled", comment: "HUD: OCR disabled")
            internal static let failed = NSLocalizedString("hud.ocr.failed", comment: "HUD: OCR failed")

            internal static func processingEngine(_ label: String) -> String {
                let format = NSLocalizedString("hud.ocr.processing_engine_fmt", comment: "HUD: OCR processing engine label")
                return String(format: format, locale: Locale.current, label)
            }
        }

        internal enum Attachment {
            internal static let processing = NSLocalizedString("hud.attachment.processing", comment: "HUD: processing attachment")
        }

        internal enum Generic {
            internal static let unsupportedType = NSLocalizedString("hud.unsupported_type", comment: "HUD: unsupported type")
            internal static let noTextFound = NSLocalizedString("hud.no_text_found", comment: "HUD: no text found")
        }

        internal enum Note {
            internal static let thinking = NSLocalizedString("hud.note.thinking", comment: "HUD: thinking placeholder")
            internal static let errorCreating = NSLocalizedString("hud.note.error_creating", comment: "HUD: error creating note")
        }
    }

    internal enum Markdown {
        internal enum Analysis {
            internal static let keyPoints = NSLocalizedString("markdown.analysis.key_points", comment: "Markdown header")
            internal static let keyInfo = NSLocalizedString("markdown.analysis.key_info", comment: "Markdown header")
            internal static let todos = NSLocalizedString("markdown.analysis.todos", comment: "Markdown header")
        }
    }
    
    internal enum iOS {
        internal enum Queue {
            internal static let title = NSLocalizedString("ios.queue.title", comment: "iOS processing queue")
            internal static let findUnprocessed = NSLocalizedString("ios.queue.find_unprocessed", comment: "iOS processing queue")
            internal static let findFooter = NSLocalizedString("ios.queue.find_footer", comment: "iOS processing queue")
            internal static let empty = NSLocalizedString("ios.queue.empty", comment: "iOS processing queue")
            internal static let backgroundFooter = NSLocalizedString("ios.queue.background_footer", comment: "iOS processing queue")
            internal static let retry = NSLocalizedString("ios.queue.retry", comment: "iOS processing queue")
            internal static let clearFinished = NSLocalizedString("ios.queue.clear_finished", comment: "iOS processing queue")
            internal static let finished = NSLocalizedString("ios.queue.finished", comment: "iOS processing queue")
            internal static let pause = NSLocalizedString("ios.queue.pause", comment: "iOS processing queue")
            internal static let start = NSLocalizedString("ios.queue.start", comment: "iOS processing queue")
            internal static func addTitle(_ count: Int) -> String {
                let format = NSLocalizedString("ios.queue.add_title_fmt", comment: "iOS processing queue")
                return String(format: format, locale: Locale.current, count)
            }
            internal static func addAndStart(_ count: Int) -> String {
                let format = NSLocalizedString("ios.queue.add_and_start_fmt", comment: "iOS processing queue")
                return String(format: format, locale: Locale.current, count)
            }
            internal static let addOnly = NSLocalizedString("ios.queue.add_only", comment: "iOS processing queue")
            internal static let addMessage = NSLocalizedString("ios.queue.add_message", comment: "iOS processing queue")
            internal static let nothingFound = NSLocalizedString("ios.queue.nothing_found", comment: "iOS processing queue")
            internal static let running = NSLocalizedString("ios.queue.running", comment: "iOS processing queue")
            internal static let pausing = NSLocalizedString("ios.queue.pausing", comment: "iOS processing queue")
            internal static let paused = NSLocalizedString("ios.queue.paused", comment: "iOS processing queue")
            internal static let queued = NSLocalizedString("ios.queue.queued", comment: "iOS processing queue")
            internal static let kindAuto = NSLocalizedString("ios.queue.kind_auto", comment: "iOS processing queue")
        }
        internal enum Settings {
            internal static let title = NSLocalizedString("ios.settings.title", comment: "iOS models and re-run")
            internal static let modelsHeader = NSLocalizedString("ios.settings.models_header", comment: "iOS models and re-run")
            internal static let modelsFooter = NSLocalizedString("ios.settings.models_footer", comment: "iOS models and re-run")
            internal static let transcriptionModel = NSLocalizedString("ios.settings.transcription_model", comment: "iOS models and re-run")
            internal static let enableAnalysis = NSLocalizedString("ios.settings.enable_analysis", comment: "iOS models and re-run")
            internal static let analysisModel = NSLocalizedString("ios.settings.analysis_model", comment: "iOS models and re-run")
            internal static let geminiFooter = NSLocalizedString("ios.settings.gemini_footer", comment: "iOS models and re-run")
            internal static let openRouterFooter = NSLocalizedString("ios.settings.openrouter_footer", comment: "iOS models and re-run")
            internal static let keySaved = NSLocalizedString("ios.settings.key_saved", comment: "iOS models and re-run")
            internal static let removeKey = NSLocalizedString("ios.settings.remove_key", comment: "iOS models and re-run")
            internal static let pasteKey = NSLocalizedString("ios.settings.paste_key", comment: "iOS models and re-run")
            internal static let saveKey = NSLocalizedString("ios.settings.save_key", comment: "iOS models and re-run")
            internal static let searchModels = NSLocalizedString("ios.settings.search_models", comment: "iOS models and re-run")
            internal static let microphoneHeader = NSLocalizedString("ios.settings.microphone_header", comment: "iOS recording microphone")
            internal static let microphone = NSLocalizedString("ios.settings.microphone", comment: "iOS recording microphone")
            internal static let microphoneBluetooth = NSLocalizedString("ios.settings.microphone_bluetooth", comment: "iOS recording microphone")
            internal static let microphoneBuiltIn = NSLocalizedString("ios.settings.microphone_builtin", comment: "iOS recording microphone")
            internal static let microphoneFooter = NSLocalizedString("ios.settings.microphone_footer", comment: "iOS recording microphone")
            internal static let noKeysForModels = NSLocalizedString("ios.settings.no_keys_for_models", comment: "iOS models and re-run")
            internal static let onDeviceModels = NSLocalizedString("ios.settings.on_device_models", comment: "iOS model picker section header")
            internal static let parakeetFooter = NSLocalizedString("ios.settings.parakeet_footer", comment: "iOS model picker: on-device Parakeet")
            internal static func useTypedModel(_ value: String) -> String {
                let format = NSLocalizedString("ios.settings.use_typed_model_fmt", comment: "iOS models and re-run")
                return String(format: format, locale: Locale.current, value)
            }
        }
        internal enum Reprocess {
            internal static let menu = NSLocalizedString("ios.reprocess.menu", comment: "iOS models and re-run")
            internal static let retranscribe = NSLocalizedString("ios.reprocess.retranscribe", comment: "iOS models and re-run")
            internal static let reanalyze = NSLocalizedString("ios.reprocess.reanalyze", comment: "iOS models and re-run")
            internal static let retranscribeOnDevice = NSLocalizedString("ios.reprocess.retranscribe_on_device", comment: "iOS: transcribe again on the phone with Parakeet")
            internal static func retranscribeCloud(_ model: String) -> String {
                let format = NSLocalizedString("ios.reprocess.retranscribe_cloud_fmt", comment: "iOS: transcribe again with the cloud model")
                return String(format: format, locale: Locale.current, model)
            }
            internal static let select = NSLocalizedString("ios.reprocess.select", comment: "iOS: enter note selection mode")
            internal static func selected(_ count: Int) -> String {
                let format = NSLocalizedString("ios.reprocess.selected_fmt", comment: "iOS: number of selected notes")
                return String(format: format, locale: Locale.current, count)
            }
            internal static let running = NSLocalizedString("ios.reprocess.running", comment: "iOS models and re-run")
            internal static let failedTitle = NSLocalizedString("ios.reprocess.failed_title", comment: "iOS models and re-run")
            internal static let missingGeminiKey = NSLocalizedString("ios.reprocess.missing_gemini_key", comment: "iOS models and re-run")
            internal static let missingOpenRouterKey = NSLocalizedString("ios.reprocess.missing_openrouter_key", comment: "iOS models and re-run")
            internal static let notAudio = NSLocalizedString("ios.reprocess.not_audio", comment: "iOS models and re-run")
            internal static func transcriptionFailed(_ value: String) -> String {
                let format = NSLocalizedString("ios.reprocess.transcription_failed_fmt", comment: "iOS models and re-run")
                return String(format: format, locale: Locale.current, value)
            }
            internal static let analysisFailed = NSLocalizedString("ios.reprocess.analysis_failed", comment: "iOS models and re-run")
        }
        internal enum NewNote {
            internal static let title = NSLocalizedString("ios.new_note.title", comment: "Create text note action and editor title")
            internal static let placeholder = NSLocalizedString("ios.new_note.placeholder", comment: "Empty text note editor prompt")
            internal static let saveFailed = NSLocalizedString("ios.new_note.save_failed", comment: "Alert title when a text note cannot be saved")
            internal static let discardPrompt = NSLocalizedString("ios.new_note.discard_prompt", comment: "Confirmation before discarding a written entry")
            internal static let discard = NSLocalizedString("ios.new_note.discard", comment: "Discard written entry action")
        }

        internal enum Root {
            internal static let title = NSLocalizedString("ios.root.title", comment: "Main screen title")
            internal static let loading = NSLocalizedString("ios.root.loading", comment: "Loading indicator")
            internal static let recoveryTitle = NSLocalizedString("ios.root.recovery_title", comment: "Alert title")
        }
        
        internal enum Recording {
            internal static let title = NSLocalizedString("ios.recording.title", comment: "Recording detail title")
            internal static let titlePhoto = NSLocalizedString("ios.recording.title_photo", comment: "Photo detail title")
            internal static let titleNote = NSLocalizedString("ios.recording.title_note", comment: "Text note detail title")
            internal static let titleDocument = NSLocalizedString("ios.recording.title_document", comment: "Document detail title")
            internal static let summary = NSLocalizedString("ios.recording.summary", comment: "Section header")
            internal static let suggestedProject = NSLocalizedString("ios.recording.suggested_project", comment: "Section header")
            internal static let details = NSLocalizedString("ios.recording.details", comment: "Section header")
            internal static let created = NSLocalizedString("ios.recording.created", comment: "Label")
            internal static let time = NSLocalizedString("ios.recording.time", comment: "Label")
            internal static let duration = NSLocalizedString("ios.recording.duration", comment: "Label")
            internal static let attachments = NSLocalizedString("ios.recording.attachments", comment: "Section header")
            internal static let pdf = NSLocalizedString("ios.recording.pdf", comment: "PDF label")
            internal static let text = NSLocalizedString("ios.recording.text", comment: "Text label")
            internal static let scannedDocument = NSLocalizedString("ios.recording.scanned_document", comment: "Default title for scans")
            internal static let device = NSLocalizedString("ios.recording.device", comment: "Detail label: which device created the recording")
            internal static let source = NSLocalizedString("ios.recording.source", comment: "Detail label: app, site or file a shared item came from")
            internal static let sourceDate = NSLocalizedString("ios.recording.source_date", comment: "Detail label: when the shared original was made")
            internal static let sourceVoiceMemos = NSLocalizedString("ios.recording.source_voice_memos", comment: "Name of Apple's Voice Memos app as a note source")
            internal static let note = NSLocalizedString("ios.recording.note", comment: "Note body section header")
            internal static let edit = NSLocalizedString("ios.recording.edit", comment: "Button")
            internal static let save = NSLocalizedString("ios.recording.save", comment: "Button")
            internal static let cancel = NSLocalizedString("ios.recording.cancel", comment: "Button")
            internal static let edited = NSLocalizedString("ios.recording.edited", comment: "Badge: note text manually edited")
            internal static let sources = NSLocalizedString("ios.recording.sources", comment: "Section header for source spoilers")
            internal static let sourceOCR = NSLocalizedString("ios.recording.source_ocr", comment: "Source row title: OCR text")
            internal static let sourceDocument = NSLocalizedString("ios.recording.source_document", comment: "Source row title: extracted document text")
            internal static let shareFile = NSLocalizedString("ios.recording.share_file", comment: "Button: share the source file")
            
            internal static func rowTitle(id: String) -> String {
                let format = NSLocalizedString("ios.recording.row_title_fmt", comment: "Default recording title")
                return String(format: format, locale: Locale.current, id)
            }
        }
        
        internal enum Capture {
            internal static let title = NSLocalizedString("ios.capture.title", comment: "Sheet title")
            internal static let close = NSLocalizedString("ios.capture.close", comment: "Button")
            internal static let done = NSLocalizedString("ios.capture.done", comment: "Button")
            internal static let processing = NSLocalizedString("ios.capture.processing", comment: "Phase title")
            internal static let saved = NSLocalizedString("ios.capture.saved", comment: "Phase title")
            internal static let transcribing = NSLocalizedString("ios.capture.transcribing", comment: "Processing label")
            internal static let reviewEdit = NSLocalizedString("ios.capture.review_edit", comment: "Saved phase label")
            internal static let listening = NSLocalizedString("ios.capture.listening", comment: "Active segment placeholder")
            internal static let noInput = NSLocalizedString("ios.capture.no_input", comment: "Empty segment placeholder")
            internal static let liveTranscription = NSLocalizedString("ios.capture.live_transcription", comment: "Label")

            internal static func input(_ name: String) -> String {
                let format = NSLocalizedString("ios.capture.input_fmt", comment: "Current recording input")
                return String(format: format, locale: Locale.current, name)
            }

            internal static func attachmentsCount(_ count: Int) -> String {
                let format = NSLocalizedString("ios.capture.attachments_fmt", comment: "Attachments counter")
                return String(format: format, locale: Locale.current, count)
            }
            internal static let photoQuality = NSLocalizedString("ios.capture.photo_quality", comment: "Slider label")
            internal static let paste = NSLocalizedString("ios.capture.paste", comment: "Button")
            internal static let photos = NSLocalizedString("ios.capture.photos", comment: "Button")
            internal static let photo = NSLocalizedString("ios.capture.photo", comment: "Button")
            internal static let scan = NSLocalizedString("ios.capture.scan", comment: "Button")
            internal static let scanDocument = NSLocalizedString("ios.capture.scan_document", comment: "Attachment menu item")
            internal static let quickCapture = NSLocalizedString("ios.capture.quick_capture", comment: "Bar title")
            internal static let takePhoto = NSLocalizedString("ios.capture.take_photo", comment: "Attachment menu item")
            internal static let attachFile = NSLocalizedString("ios.capture.attach_file", comment: "Attachment menu item")
            internal static let addAttachment = NSLocalizedString("ios.capture.add_attachment", comment: "Attachment menu accessibility label")
            internal static let tapToRecord = NSLocalizedString("ios.capture.tap_to_record", comment: "Bar subtitle")
        }
        
        internal enum Chat {
            internal static let recording = NSLocalizedString("ios.chat.recording", comment: "Bubble title")
            internal static let transcription = NSLocalizedString("ios.chat.transcription", comment: "Bubble title")
            internal static let system = NSLocalizedString("ios.chat.system", comment: "Bubble title")
            internal static let location = NSLocalizedString("ios.chat.location", comment: "Placeholder")
            
            internal static func audioLabel(duration: String) -> String {
                let format = NSLocalizedString("ios.chat.audio_label_fmt", comment: "Audio message label")
                return String(format: format, locale: Locale.current, duration)
            }
            
            internal static func accessibilitySavedAt(time: String, isSaved: Bool) -> String {
                let key = isSaved ? "ios.chat.accessibility_saved_at_fmt" : "ios.chat.accessibility_saving_at_fmt"
                let format = NSLocalizedString(key, comment: "Accessibility label")
                return String(format: format, locale: Locale.current, time)
            }
        }
        
        internal enum Error {
            internal static let cameraUnavailable = NSLocalizedString("ios.error.camera_unavailable", comment: "Alert message")
            internal static let clipboardNoImage = NSLocalizedString("ios.error.clipboard_no_image", comment: "Alert message")
            internal static let clipboardEmpty = NSLocalizedString("ios.error.clipboard_empty", comment: "Alert message")
            internal static let unsupportedFile = NSLocalizedString("ios.error.unsupported_file", comment: "Alert message")
            internal static let unavailable = NSLocalizedString("ios.error.unavailable", comment: "Alert title")
        }
        
        internal enum Success {
            internal static let recoveryComplete = NSLocalizedString("ios.success.recovery_complete", comment: "Alert title")
            
            internal static func recovered(count: Int) -> String {
                let format = NSLocalizedString("ios.success.recovered_fmt", comment: "Recovery message")
                return String(format: format, locale: Locale.current, count)
            }
        }
        
        internal enum SaveStatus {
            internal static let saving = NSLocalizedString("ios.save_status.saving", comment: "Status label")
            internal static let saved = NSLocalizedString("ios.save_status.saved", comment: "Status label")
            internal static let error = NSLocalizedString("ios.save_status.error", comment: "Status label")
            
            internal static let accessibilitySaving = NSLocalizedString("ios.save_status.accessibility_saving", comment: "Accessibility label")
            internal static let accessibilitySaved = NSLocalizedString("ios.save_status.accessibility_saved", comment: "Accessibility label")
            
            internal static func accessibilityError(_ message: String) -> String {
                let format = NSLocalizedString("ios.save_status.accessibility_error_fmt", comment: "Accessibility label")
                return String(format: format, locale: Locale.current, message)
            }
        }
        
        internal enum List {
            internal static let emptyTitle = NSLocalizedString("ios.list.empty_title", comment: "Empty state title")
            internal static let emptyDescription = NSLocalizedString("ios.list.empty_description", comment: "Empty state description")
            internal static let searchPrompt = NSLocalizedString("ios.list.search_prompt", comment: "Search field prompt")
        }
        
        internal enum Day {
            internal static let today = NSLocalizedString("ios.day.today", comment: "Day separator: today")
            internal static let yesterday = NSLocalizedString("ios.day.yesterday", comment: "Day separator: yesterday")
        }
    }

    // MARK: - Personal Wiki

    internal enum Wiki {
        internal static let searchPlaceholder = NSLocalizedString("wiki.search_placeholder", comment: "Wiki search field placeholder")
        internal static let refreshHelp = NSLocalizedString("wiki.refresh_help", comment: "Tooltip: refresh the wiki")
        internal static let chooseFolderHelp = NSLocalizedString("wiki.choose_folder_help", comment: "Tooltip: choose the wiki folder")
        internal static let detailEmpty = NSLocalizedString("wiki.detail.empty", comment: "Placeholder in the article detail pane")

        internal enum Picker {
            internal static let title = NSLocalizedString("wiki.picker.title", comment: "Open panel title for choosing the wiki folder")
            internal static let prompt = NSLocalizedString("wiki.picker.prompt", comment: "Open panel confirm button")
        }

        internal enum List {
            internal static let sortRecent = NSLocalizedString("wiki.list.sort_recent", comment: "Sort articles by recency")
            internal static let refreshHelp = NSLocalizedString("wiki.list.refresh_help", comment: "Tooltip: refresh the article list")
            internal static let chooseFolderHelp = NSLocalizedString("wiki.list.choose_folder_help", comment: "Tooltip: choose the wiki folder")
            internal static let emptyNoFolderTitle = NSLocalizedString("wiki.list.empty_no_folder_title", comment: "Empty state: no wiki folder chosen yet")
            internal static let emptyNoFolderAction = NSLocalizedString("wiki.list.empty_no_folder_action", comment: "Empty state action: choose a folder")
            internal static let emptyNoArticles = NSLocalizedString("wiki.list.empty_no_articles", comment: "Empty state: folder has no markdown articles")
            internal static let emptyNoMatches = NSLocalizedString("wiki.list.empty_no_matches", comment: "Empty state: search found nothing")
        }

        internal enum Article {
            internal static let edit = NSLocalizedString("wiki.article.edit", comment: "Start editing an article")
            internal static let done = NSLocalizedString("wiki.article.done", comment: "Finish editing an article")
            internal static let summary = NSLocalizedString("wiki.article.summary", comment: "Article summary section")
            internal static let backlinks = NSLocalizedString("wiki.article.backlinks", comment: "Section listing articles that link here")
            internal static let markdown = NSLocalizedString("wiki.article.markdown", comment: "Footer label: markdown source")
            internal static let markdownAutosave = NSLocalizedString("wiki.article.markdown_autosave", comment: "Footer label while editing, autosave is on")
            internal static let savePending = NSLocalizedString("wiki.article.save_pending", comment: "Save state: unsaved changes")
            internal static let saveSaving = NSLocalizedString("wiki.article.save_saving", comment: "Save state: in progress")
            internal static let saveSaved = NSLocalizedString("wiki.article.save_saved", comment: "Save state: saved")
            internal static let saveFailed = NSLocalizedString("wiki.article.save_failed", comment: "Save state: failed")

            internal static func wordCount(_ words: Int, modified: String) -> String {
                let format = NSLocalizedString("wiki.article.word_count_fmt", comment: "Footer: word count and modified date")
                return String(format: format, locale: Locale.current, words, modified)
            }
        }
    }

    // MARK: - Import picker

    internal enum ImportKind {
        internal static let image = NSLocalizedString("import.kind.image", comment: "Import category: images")
        internal static let audio = NSLocalizedString("import.kind.audio", comment: "Import category: audio")
        internal static let text = NSLocalizedString("import.kind.text", comment: "Import category: text")
        internal static let other = NSLocalizedString("import.kind.other", comment: "Import category: everything else")
        internal static let appleNotesDetail = NSLocalizedString("import.detail.apple_notes", comment: "Import source detail: Notes.app")
        internal static let unsupportedDetail = NSLocalizedString("import.detail.unsupported", comment: "Import source detail: unsupported type")

        internal enum Duplicate {
            internal static let alreadyImported = NSLocalizedString("import.duplicate.already_imported", comment: "Duplicate reason: already in the library")
            internal static let inSelection = NSLocalizedString("import.duplicate.in_selection", comment: "Duplicate reason: picked twice in one selection")
        }
    }

    internal enum NoteSection {
        internal static let mentionedIn = NSLocalizedString("note.section.mentioned_in", comment: "Note section listing wiki articles citing this note")
    }

    // MARK: - Personal vocabulary

    internal enum Vocabulary {
        internal static let tabTitle = NSLocalizedString("settings.tab.vocabulary", comment: "Settings tab title")
        internal static let title = NSLocalizedString("vocabulary.title", comment: "Screen title")
        internal static let subtitle = NSLocalizedString("vocabulary.subtitle", comment: "Screen subtitle")
        internal static let includeBuiltin = NSLocalizedString("vocabulary.include_builtin", comment: "Toggle")
        internal static let termEnabled = NSLocalizedString("vocabulary.term_enabled", comment: "Per-term toggle")
        internal static let add = NSLocalizedString("vocabulary.add", comment: "Button")
        internal static let reload = NSLocalizedString("vocabulary.reload", comment: "Button")
        internal static let rememberNameMenu = NSLocalizedString("reader.note_view.remember_name", comment: "Reader note menu item")

        internal enum Editor {
            internal static let title = NSLocalizedString("vocabulary.editor.title", comment: "Remember-name sheet")
            internal static let canonical = NSLocalizedString("vocabulary.editor.canonical", comment: "Remember-name sheet")
            internal static let context = NSLocalizedString("vocabulary.editor.context", comment: "Remember-name sheet")
            internal static let variants = NSLocalizedString("vocabulary.editor.variants", comment: "Remember-name sheet")
            internal static let hint = NSLocalizedString("vocabulary.editor.hint", comment: "Remember-name sheet")
            internal static let reload = NSLocalizedString("vocabulary.editor.reload", comment: "Remember-name sheet")
            internal static let save = NSLocalizedString("vocabulary.editor.save", comment: "Remember-name sheet")
            internal static let kind = NSLocalizedString("vocabulary.editor.kind", comment: "Remember-name sheet: what the name refers to")
            internal static let sensitive = NSLocalizedString("vocabulary.editor.sensitive", comment: "Remember-name sheet toggle")
            internal static let sensitiveHint = NSLocalizedString("vocabulary.editor.sensitive_hint", comment: "Remember-name sheet")
        }

        internal static func kindName(_ kind: PersonalGlossaryKind?) -> String {
            switch kind {
            case .person: return NSLocalizedString("vocabulary.kind.person", comment: "Glossary kind")
            case .org: return NSLocalizedString("vocabulary.kind.org", comment: "Glossary kind")
            case .place: return NSLocalizedString("vocabulary.kind.place", comment: "Glossary kind")
            case .other, nil: return NSLocalizedString("vocabulary.kind.other", comment: "Glossary kind")
            }
        }
        internal static let sensitiveBadge = NSLocalizedString("vocabulary.sensitive_badge", comment: "Badge on a sensitive term")
    }

    // MARK: - Private mode

    internal enum PrivateMode {
        internal static let cardTitle = NSLocalizedString("private_mode.card.title", comment: "Settings card")
        internal static let cardSubtitle = NSLocalizedString("private_mode.card.subtitle", comment: "Settings card")
        internal static let toggleTitle = NSLocalizedString("private_mode.toggle.title", comment: "Settings toggle")
        internal static let toggleDescription = NSLocalizedString("private_mode.toggle.description", comment: "Settings toggle")
        internal static let transcriptionRefused = NSLocalizedString("private_mode.refused.transcription", comment: "HUD / placeholder")
        internal static let ocrRefused = NSLocalizedString("private_mode.refused.ocr", comment: "HUD")

        internal enum Toggle {
            internal static let original = NSLocalizedString("private_mode.toggle.original", comment: "NoteView text switch")
            internal static let depersonalized = NSLocalizedString("private_mode.toggle.depersonalized", comment: "NoteView text switch")
        }

        internal enum Preview {
            internal static let menu = NSLocalizedString("private_mode.preview.menu", comment: "Reader ··· menu item")
            internal static let title = NSLocalizedString("private_mode.preview.title", comment: "Sheet title")
            internal static let loading = NSLocalizedString("private_mode.preview.loading", comment: "Sheet")
            internal static let modeOn = NSLocalizedString("private_mode.preview.mode_on", comment: "Sheet status")
            internal static let modeOff = NSLocalizedString("private_mode.preview.mode_off", comment: "Sheet status")
            internal static let wouldSend = NSLocalizedString("private_mode.preview.would_send", comment: "Guard status")
            internal static let wouldBlockFormat = NSLocalizedString("private_mode.preview.would_block", comment: "Guard status; %@ = categories")
            internal static let refusedFormat = NSLocalizedString("private_mode.preview.refused", comment: "Guard status; %@ = reason")
            internal static let noteText = NSLocalizedString("private_mode.preview.note_text", comment: "Section")
            internal static let payload = NSLocalizedString("private_mode.preview.payload", comment: "Section")
            internal static let legend = NSLocalizedString("private_mode.preview.legend", comment: "Section")
            internal static let legendEmpty = NSLocalizedString("private_mode.preview.legend_empty", comment: "Section")
            internal static let token = NSLocalizedString("private_mode.preview.token", comment: "Column")
            internal static let value = NSLocalizedString("private_mode.preview.value", comment: "Column")
            internal static let kind = NSLocalizedString("private_mode.preview.kind", comment: "Column")
            internal static let detector = NSLocalizedString("private_mode.preview.detector", comment: "Column")
            internal static let footnoteFormat = NSLocalizedString("private_mode.preview.footnote", comment: "%d = sensitive terms")
            internal static let copyPayload = NSLocalizedString("private_mode.preview.copy_payload", comment: "Button")
            internal static let button = NSLocalizedString("private_mode.preview.button", comment: "NoteView button help")
            internal static let wouldSendWithSuspectsFormat = NSLocalizedString("private_mode.preview.would_send_with_suspects", comment: "Guard status; %d = suspect count")
            internal static let details = NSLocalizedString("private_mode.preview.details", comment: "Opens the full private text preview")
            internal static let copyText = NSLocalizedString("private_mode.preview.copy_text", comment: "Copies the depersonalized note text")
            internal static let suspects = NSLocalizedString("private_mode.preview.suspects", comment: "Section")
            internal static let suspectsHint = NSLocalizedString("private_mode.preview.suspects_hint", comment: "Section hint")
            internal static let suspectsEmpty = NSLocalizedString("private_mode.preview.suspects_empty", comment: "Section")
            internal static let hide = NSLocalizedString("private_mode.preview.hide", comment: "Button: add the word to the vocabulary as sensitive")
            internal static let notIdentifier = NSLocalizedString("private_mode.preview.not_identifier", comment: "Button: dismiss a suspect")
            internal static let suspectContext = NSLocalizedString("private_mode.preview.suspect_context", comment: "Prefilled vocabulary context")
            /// `raw` is a `PseudonymSuspect.Reason` raw value. Literal keys, so the parity test sees them.
            internal static func reason(_ raw: String) -> String {
                switch raw {
                case "name": return NSLocalizedString("private_mode.preview.reason.name", comment: "Why a word looks identifying")
                case "quotedName": return NSLocalizedString("private_mode.preview.reason.quotedName", comment: "Why a word looks identifying")
                case "acronym": return NSLocalizedString("private_mode.preview.reason.acronym", comment: "Why a word looks identifying")
                case "organization": return NSLocalizedString("private_mode.preview.reason.organization", comment: "Why a word looks identifying")
                case "longNumber": return NSLocalizedString("private_mode.preview.reason.longNumber", comment: "Why a word looks identifying")
                default: return raw
                }
            }
        }
    }

    // MARK: - My document

    internal enum MyDocument {
        internal static let title = NSLocalizedString("myDocument.title", comment: "My document")
        internal static let description = NSLocalizedString("myDocument.description", comment: "My document")
        internal static let documentURL = NSLocalizedString("myDocument.documentURL", comment: "My document")
        internal static let save = NSLocalizedString("myDocument.save", comment: "My document")
        internal static let open = NSLocalizedString("myDocument.open", comment: "My document")
        internal static let connected = NSLocalizedString("myDocument.connected", comment: "My document")
        internal static let disconnect = NSLocalizedString("myDocument.disconnect", comment: "My document")
        internal static let connect = NSLocalizedString("myDocument.connect", comment: "My document")
        internal static let model = NSLocalizedString("myDocument.model", comment: "My document")
        internal static let localUnavailable = NSLocalizedString("myDocument.localUnavailable", comment: "My document")
        internal static let enabled = NSLocalizedString("myDocument.enabled", comment: "My document")
        internal static let automaticDescription = NSLocalizedString("myDocument.automaticDescription", comment: "My document")
        internal static let queued = NSLocalizedString("myDocument.queued", comment: "My document")
        internal static let retry = NSLocalizedString("myDocument.retry", comment: "My document")
        internal static let addSelected = NSLocalizedString("myDocument.addSelected", comment: "My document")
        internal static let selectedDescription = NSLocalizedString("myDocument.selectedDescription", comment: "My document")
        internal static let connectionSetup = NSLocalizedString("myDocument.connectionSetup", comment: "My document")
        internal static let connectionDescription = NSLocalizedString("myDocument.connectionDescription", comment: "My document")
        internal static let importClient = NSLocalizedString("myDocument.importClient", comment: "My document")
        internal static let setupHelp = NSLocalizedString("myDocument.setupHelp", comment: "My document")
        internal static let addHelp = NSLocalizedString("myDocument.addHelp", comment: "My document")
        internal static let queuePreview = NSLocalizedString("myDocument.queuePreview", comment: "My document")
        internal static let removePending = NSLocalizedString("myDocument.removePending", comment: "My document")
        internal static let localSetup = NSLocalizedString("myDocument.localSetup", comment: "My document")

        internal enum Status {
            internal static let waiting = NSLocalizedString("myDocument.status.waiting", comment: "My document")
            internal static let writing = NSLocalizedString("myDocument.status.writing", comment: "My document")
            internal static let sending = NSLocalizedString("myDocument.status.sending", comment: "My document")
            internal static let updated = NSLocalizedString("myDocument.status.updated", comment: "My document")
            internal static let paused = NSLocalizedString("myDocument.status.paused", comment: "My document")
        }

        internal enum Errors {
            internal static let destinationLocked = NSLocalizedString("myDocument.error.destinationLocked", comment: "My document")
            internal static let noText = NSLocalizedString("myDocument.error.noText", comment: "My document")
            internal static let tooLong = NSLocalizedString("myDocument.error.tooLong", comment: "My document")
        }
    }
}
