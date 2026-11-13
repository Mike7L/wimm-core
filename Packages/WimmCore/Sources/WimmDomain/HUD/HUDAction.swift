import Foundation

public enum HUDAction: Sendable, Equatable {
    case toggleRecording
    case cancelRecording
    case requestEditLastTranscript
    case applyTranscriptEdit(String?)
    case deleteLastNote
    case toggleHelp
    case refresh
    case toggleAutoProcess
    case processQueue
    case exportNotes
    case showStats
    case listRecent
    case close
    case exitApp
    case interrupt
}

public enum HUDExternalAction: Sendable, Equatable {
    case processQueue
    case exportNotes
    case showStats
    case listRecent
}

public struct HUDTranscriptEditContext: Sendable, Equatable {
    public let shortID: String
    public let currentText: String

    public init(shortID: String, currentText: String) {
        self.shortID = shortID
        self.currentText = currentText
    }
}

public enum HUDControllerEffect: Sendable, Equatable {
    case none
    case promptTranscriptEdit(HUDTranscriptEditContext)
    case runExternalAction(HUDExternalAction)
    case close
    case exitApp
}
