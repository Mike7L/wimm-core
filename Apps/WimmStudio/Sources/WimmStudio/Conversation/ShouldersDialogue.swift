@preconcurrency import AVFoundation
import SwiftUI

/// The angel-and-demon version of "Друг": when the agent tags the lines of its
/// reply with `😇:` / `😈:` (or `Ангел:` / `Демон:`), the window seats two
/// characters on the user's shoulders and reads each line in its own voice.
enum ShoulderSpeaker: Equatable {
    case angel, demon

    var emoji: String { self == .angel ? "😇" : "😈" }
    var name: String { self == .angel ? "Ангел" : "Демон" }
    var tint: Color { self == .angel ? Color(red: 1, green: 0.84, blue: 0.45) : Color(red: 1, green: 0.36, blue: 0.3) }
    /// Pitch keeps the two apart even when only one Russian voice is installed.
    var pitch: Float { self == .angel ? 1.12 : 0.82 }
    /// +10% quicker than before (was 0.56 / 0.60): a brisk quarrel, not a lecture. The demon is the quicker one.
    var rate: Float { self == .angel ? 0.62 : 0.66 }

    /// The best installed Russian voice of the character's gender, any Russian voice otherwise.
    var voice: AVSpeechSynthesisVoice? { self == .angel ? Self.angelVoice : Self.demonVoice }

    private static let angelVoice = russianVoice(.female)
    private static let demonVoice = russianVoice(.male)

    private static func russianVoice(_ gender: AVSpeechSynthesisVoiceGender) -> AVSpeechSynthesisVoice? {
        let russian = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("ru") }
        let best = { (voices: [AVSpeechSynthesisVoice]) in voices.max { $0.quality.rawValue < $1.quality.rawValue } }
        return best(russian.filter { $0.gender == gender }) ?? best(russian) ?? AVSpeechSynthesisVoice(language: "ru-RU")
    }
}

struct ShoulderLine: Equatable {
    let speaker: ShoulderSpeaker
    var text: String
}

enum ShouldersDialogue {
    private static let tags: [(String, ShoulderSpeaker)] = [("😇", .angel), ("😈", .demon), ("ангел", .angel), ("демон", .demon)]

    /// The reply's lines by speaker, or nil for an ordinary "Друг" reply.
    /// An untagged line continues the line before it; leading ones go to the angel.
    static func lines(_ markdown: String) -> [ShoulderLine]? {
        var lines: [ShoulderLine] = []
        var hasTag = false
        for raw in markdown.split(separator: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let (speaker, text) = tagged(Substring(trimmed)) {
                hasTag = true
                lines.append(ShoulderLine(speaker: speaker, text: String(text)))
            } else if !lines.isEmpty {
                lines[lines.count - 1].text += "\n" + trimmed
            } else {
                lines.append(ShoulderLine(speaker: .angel, text: trimmed))
            }
        }
        return hasTag ? lines : nil
    }

    /// One line of a streamed reply: tagged, or the previous speaker going on
    /// (the angel when nobody spoke yet). Nil for a blank line.
    static func streamedLine(_ raw: String, previous: ShoulderSpeaker?) -> ShoulderLine? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let (speaker, text) = tagged(Substring(trimmed)) {
            return text.isEmpty ? nil : ShoulderLine(speaker: speaker, text: String(text))
        }
        return ShoulderLine(speaker: previous ?? .angel, text: trimmed)
    }

    /// `😈: …`, `**Демон:** …`, `Ангел — …` → the speaker and the text after the tag.
    private static func tagged(_ line: Substring) -> (ShoulderSpeaker, Substring)? {
        let isDecoration: (Character) -> Bool = { $0 == "*" || $0.isWhitespace }
        var rest = line.drop(while: isDecoration)
        guard let (tag, speaker) = tags.first(where: { rest.lowercased().hasPrefix($0.0) }) else { return nil }
        rest = rest.dropFirst(tag.count).drop(while: isDecoration)
        guard let separator = rest.first, ":—–-".contains(separator) else { return nil }
        return (speaker, rest.dropFirst().drop(while: isDecoration))
    }
}

/// The two characters over the mirror. A mirror shows the user's left shoulder
/// on the left, so the demon sits there and the angel on the right, as the
/// saying goes. Each bubble holds that character's lines of the current turn.
struct ShouldersView: View {
    let lines: [ShoulderLine]
    /// The line being read aloud right now.
    let speakingLine: Int?
    let dimmed: Bool

    var body: some View {
        GeometryReader { proxy in
            HStack(alignment: .top, spacing: 0) {
                side(.demon)
                    .frame(width: max(220, proxy.size.width * 0.32), alignment: .topLeading)
                Spacer(minLength: 0)
                side(.angel)
                    .frame(width: max(220, proxy.size.width * 0.32), alignment: .topTrailing)
            }
        }
    }

    private func side(_ speaker: ShoulderSpeaker) -> some View {
        let active = speakingLine.flatMap { lines.indices.contains($0) ? lines[$0].speaker == speaker : nil }
        let alignment: HorizontalAlignment = speaker == .demon ? .leading : .trailing
        return VStack(alignment: alignment, spacing: 10) {
            bubble(speaker)
            VStack(spacing: 2) {
                Text(speaker.emoji)
                    .font(.system(size: 84))
                    .shadow(color: speaker.tint.opacity(active == true ? 0.95 : 0), radius: 22)
                    .scaleEffect(active == true ? 1.14 : 1)
                Text(speaker.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(speaker.tint)
            }
            .opacity(active == false ? 0.5 : 1)
            .animation(.spring(duration: 0.35), value: active)
        }
    }

    /// Lines not yet read aloud stay hidden, so the bubbles fill in as the dialogue plays.
    @ViewBuilder private func bubble(_ speaker: ShoulderSpeaker) -> some View {
        let shown = lines.indices.filter { lines[$0].speaker == speaker && $0 <= (speakingLine ?? lines.count) }
        if !shown.isEmpty {
            ViewThatFits(in: .vertical) {
                bubbleText(shown, size: 21)
                bubbleText(shown, size: 18)
                ScrollView { bubbleText(shown, size: 16) }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(speaker.tint.opacity(0.45), lineWidth: 1))
            .opacity(dimmed ? 0.45 : 1)
            .animation(.easeInOut(duration: 0.3), value: dimmed)
        }
    }

    private func bubbleText(_ shown: [Int], size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(shown, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if index == speakingLine {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: size * 0.8))
                            .foregroundStyle(lines[index].speaker.tint)
                            .symbolEffect(.variableColor.iterative, isActive: true)
                            .transition(.opacity)
                    }
                    Text(FriendConversation.attributed(lines[index].text))
                        // The line being spoken (or, in silence, the latest one) is the bright one.
                        .opacity(index == (speakingLine ?? shown.last) ? 1 : 0.55)
                }
            }
        }
        .font(.system(size: size, weight: .regular, design: .serif))
        .lineSpacing(4)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}
