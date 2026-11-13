import Foundation
import WimmDomain

func hudInputAction(for character: Character) -> HUDAction? {
    if character.unicodeScalars.count == 1, character.unicodeScalars.first?.value == 3 {
        return .interrupt
    }
    if character.unicodeScalars.count == 1, character.unicodeScalars.first?.value == 27 {
        return .cancelRecording
    }

    let raw = String(character)
    if raw == "X" || raw == "Ч" {
        return .exitApp
    }

    switch raw {
    case "x", "ч", "w", "ц": return .toggleRecording
    case "c", "с": return .processQueue
    case "d", "в": return .deleteLastNote
    case "e", "у": return .exportNotes
    case "m", "ь": return .requestEditLastTranscript
    case "r", "к": return .refresh
    case "a", "ф": return .toggleAutoProcess
    case "h", "р", "?": return .toggleHelp
    case "l", "д": return .listRecent
    case "s", "ы": return .showStats
    case "q", "й": return .close
    default:
        return nil
    }
}
