import Foundation

/// Recording-level labels. `owner` means a single voice matching the owner's
/// local profile; a conversation containing the owner still has its speaker count.
public enum AudioSpeechLabel: String, Codable, CaseIterable, Sendable {
    case noSpeech = "no_speech"
    case owner
    case onePerson = "one_person"
    case twoPeople = "two_people"
    case threeOrMore = "three_or_more"

    public static func speakerCount(_ count: Int) -> Self? {
        switch count {
        case 1: .onePerson
        case 2: .twoPeople
        case 3...: .threeOrMore
        default: nil // An uncovered quiet voice is not evidence of silence.
        }
    }

    public var systemImage: String {
        switch self {
        case .noSpeech: "waveform.slash"
        case .owner: "person.crop.circle.badge.checkmark"
        case .onePerson: "person"
        case .twoPeople: "person.2"
        case .threeOrMore: "person.3"
        }
    }
}
