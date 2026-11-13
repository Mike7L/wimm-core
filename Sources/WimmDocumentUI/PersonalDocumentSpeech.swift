import AVFoundation
import Foundation
import NaturalLanguage
import Observation
import WimmInfrastructure

@MainActor
public protocol PersonalDocumentSpeechSynthesizing: AnyObject {
    var speechRate: Float { get set }
    var voiceIdentifier: String? { get set }
    func speak(_ text: String, onFinish: @escaping @MainActor () -> Void)
    func stop()
}

/// One block the paragraph reader can show or speak. `heading` is the nearest
/// title above the block; a heading's own title is `text`.
public struct SpokenParagraph: Equatable, Sendable {
    public let id: Int
    public let text: String
    public let heading: String?
    public init(id: Int, text: String, heading: String?) {
        self.id = id
        self.text = text
        self.heading = heading
    }
}

public struct DocumentSpeechVoiceChoice: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let language: String
    /// `AVSpeechSynthesisVoiceQuality.rawValue` (1 compact, 2 enhanced, 3 premium).
    public let quality: Int
    public var isCompact: Bool { quality <= AVSpeechSynthesisVoiceQuality.default.rawValue }
    public init(id: String, name: String, language: String, quality: Int) {
        self.id = id
        self.name = name
        self.language = language
        self.quality = quality
    }
}

/// Speaks a Personal document block by block from any paragraph, advancing
/// through subsequent paragraphs until stopped or the end of the document.
@Observable @MainActor
public final class PersonalDocumentSpeech {
    public private(set) var speakingBlockID: Int?
    public private(set) var paragraphs: [SpokenParagraph] = []
    public private(set) var index: Int = 0
    public private(set) var rateMultiplier: Double = 1
    public private(set) var voiceIdentifier: String?
    public var isSpeaking: Bool { speakingBlockID != nil }
    public var currentParagraph: SpokenParagraph? {
        paragraphs.indices.contains(index) ? paragraphs[index] : nil
    }

    @ObservationIgnored private let synthesizer: PersonalDocumentSpeechSynthesizing
    @ObservationIgnored private var generation = 0

    public init(synthesizer: PersonalDocumentSpeechSynthesizing = AVPersonalDocumentSpeechSynthesizer()) {
        self.synthesizer = synthesizer
        synthesizer.speechRate = Self.utteranceRate(forMultiplier: 1)
    }

    public func toggle(blockID: Int, in document: PersonalDocument) {
        if speakingBlockID == blockID {
            stop()
        } else {
            start(from: blockID, in: document)
        }
    }

    public func startFromBeginning(in document: PersonalDocument) {
        let candidate = document.blocks.first { block in
            !Self.isEditorialPreamble(block) && Self.spokenText(for: block, in: document) != nil
        } ?? document.blocks.first { Self.spokenText(for: $0, in: document) != nil }
        guard let candidate else { stop(); return }
        start(from: candidate.id, in: document)
    }

    public func start(from blockID: Int, in document: PersonalDocument) {
        if let block = document.blocks.first(where: { $0.id == blockID }),
           Self.isEditorialPreamble(block),
           let text = Self.spokenText(for: block, in: document) {
            let rest = Self.spokenParagraphs(in: document).filter { $0.id > blockID }
            paragraphs = [SpokenParagraph(id: block.id, text: text, heading: nil)] + rest
            index = 0
            beginSpeaking()
            return
        }
        loadParagraphs(in: document)
        guard let start = paragraphs.firstIndex(where: { $0.id == blockID })
            ?? paragraphs.firstIndex(where: { $0.id > blockID }) else {
            stop()
            return
        }
        index = start
        beginSpeaking()
    }

    /// Rebuilds the paragraph list from the document and keeps the current block
    /// when it is still there. Restarts speech only when that block's text changed.
    public func align(to document: PersonalDocument) {
        let previousText = currentParagraph?.text
        let currentID = currentParagraph?.id
        loadParagraphs(in: document)
        guard !paragraphs.isEmpty else {
            index = 0
            if isSpeaking { stop() }
            return
        }
        if let currentID, let newIndex = paragraphs.firstIndex(where: { $0.id == currentID }) {
            index = newIndex
        } else {
            index = min(index, paragraphs.count - 1)
        }
        if isSpeaking, currentParagraph?.text != previousText {
            beginSpeaking()
        }
    }

    public func playCurrent() {
        guard currentParagraph != nil else { return }
        beginSpeaking()
    }

    public func advanceParagraph() {
        guard !paragraphs.isEmpty else { return }
        guard index + 1 < paragraphs.count else {
            if isSpeaking { stop() }
            return
        }
        index += 1
        if isSpeaking { beginSpeaking() }
    }

    public func retreatParagraph() {
        guard !paragraphs.isEmpty else { return }
        if index > 0 { index -= 1 }
        if isSpeaking { beginSpeaking() }
    }

    /// `multiplier` is relative to the system default. The speech API tops out at 2×.
    public func setRateMultiplier(_ multiplier: Double, restartIfSpeaking: Bool = true) {
        rateMultiplier = min(2, max(0.75, multiplier))
        synthesizer.speechRate = Self.utteranceRate(forMultiplier: rateMultiplier)
        if restartIfSpeaking, isSpeaking { beginSpeaking() }
    }

    public func setVoiceIdentifier(_ identifier: String?, restartIfSpeaking: Bool = true) {
        let trimmed = identifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        voiceIdentifier = (trimmed?.isEmpty == false) ? trimmed : nil
        synthesizer.voiceIdentifier = voiceIdentifier
        if restartIfSpeaking, isSpeaking { beginSpeaking() }
    }

    public static func utteranceRate(forMultiplier multiplier: Double) -> Float {
        let clamped = min(2, max(0.75, multiplier))
        let rate = AVSpeechUtteranceDefaultSpeechRate * Float(clamped)
        return min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, rate))
    }

    /// How long a silent reader should hold a paragraph. 170 words/minute at 1×.
    public static func visualDwellSeconds(wordCount: Int, rateMultiplier: Double) -> Double {
        let multiplier = min(2, max(0.75, rateMultiplier))
        let words = max(wordCount, 1)
        return max(0.7, Double(words) / (170 * multiplier) * 60)
    }

    public static func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    public func stop() {
        generation += 1
        speakingBlockID = nil
        synthesizer.stop()
    }

    private func loadParagraphs(in document: PersonalDocument) {
        paragraphs = Self.spokenParagraphs(in: document)
    }

    private func beginSpeaking() {
        guard paragraphs.indices.contains(index) else {
            stop()
            return
        }
        generation += 1
        speak(paragraphs[index], generation: generation)
    }

    private func speak(_ item: SpokenParagraph, generation: Int) {
        speakingBlockID = item.id
        synthesizer.speechRate = Self.utteranceRate(forMultiplier: rateMultiplier)
        synthesizer.voiceIdentifier = voiceIdentifier
        synthesizer.speak(item.text) { [weak self] in
            guard let self, self.generation == generation else { return }
            if self.index + 1 < self.paragraphs.count {
                self.index += 1
                self.beginSpeaking()
            } else {
                self.speakingBlockID = nil
            }
        }
    }

    // MARK: - Block text extraction

    public static func spokenParagraphs(in document: PersonalDocument) -> [SpokenParagraph] {
        var stack: [(level: Int, title: String)] = []
        var result: [SpokenParagraph] = []
        for block in document.blocks {
            if isEditorialPreamble(block) { continue }
            guard let text = spokenText(for: block, in: document) else { continue }
            if case .heading(let level) = block.kind {
                stack.removeAll { $0.level >= level }
                result.append(SpokenParagraph(id: block.id, text: text, heading: stack.last?.title))
                stack.append((level, text))
            } else {
                result.append(SpokenParagraph(id: block.id, text: text, heading: stack.last?.title))
            }
        }
        return result
    }

    public static func queue(from startID: Int, in document: PersonalDocument) -> [(id: Int, text: String)] {
        document.blocks.compactMap { block in
            guard block.id >= startID else { return nil }
            if block.id != startID, isEditorialPreamble(block) { return nil }
            guard let text = spokenText(for: block, in: document) else { return nil }
            return (block.id, text)
        }
    }

    public static func isEditorialPreamble(_ block: PersonalDocument.Block) -> Bool {
        block.markdown.hasPrefix("**Редакция:")
    }

    public static func spokenText(for block: PersonalDocument.Block, in document: PersonalDocument) -> String? {
        if case .hidden = block.kind { return nil }
        let markdown = document.displayMarkdown(for: block)
        guard !markdown.isEmpty,
              markdown.range(of: #"^!\[[^\]]*\]\([^)]+\)$"#, options: .regularExpression) == nil else {
            return nil
        }
        let parsed = MarkdownDocumentParser.parse(markdown)
        var parts: [String] = []
        for item in parsed {
            switch item {
            case .heading(_, let text), .paragraph(let text), .quote(let text):
                if let plain = inlinePlainText(text) { parts.append(plain) }
            case .list(let listItems):
                for entry in listItems {
                    if let plain = inlinePlainText(entry.content) { parts.append(plain) }
                }
            case .table(let header, let rows):
                for row in [header] + rows {
                    let line = row.compactMap(inlinePlainText).joined(separator: ", ")
                    if !line.isEmpty { parts.append(line) }
                }
            case .code(_, let content):
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { parts.append(trimmed) }
            case .rule:
                break
            }
        }
        let joined = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private static func inlinePlainText(_ markdown: String) -> String? {
        let withoutImages = markdown.replacingOccurrences(
            of: #"!\[([^\]]*)\]\([^)]+\)"#,
            with: "$1",
            options: .regularExpression
        )
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        let raw: String
        if let parsed = try? AttributedString(markdown: withoutImages, options: options) {
            raw = String(parsed.characters)
        } else {
            raw = withoutImages
        }
        let cleaned = raw
            .replacingOccurrences(of: #"\s+([.,;:!?])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}

@MainActor
public final class AVPersonalDocumentSpeechSynthesizer: NSObject, PersonalDocumentSpeechSynthesizing, AVSpeechSynthesizerDelegate {
    public override init() { super.init() }
    public var speechRate: Float = AVSpeechUtteranceDefaultSpeechRate
    public var voiceIdentifier: String?
    private var synthesizer: AVSpeechSynthesizer?
    private var activeUtteranceID: ObjectIdentifier?
    private var onFinish: (@MainActor () -> Void)?

    public func speak(_ text: String, onFinish: @escaping @MainActor () -> Void) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, speechRate))
        if let voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        } else {
            utterance.voice = Self.bestVoice(for: text)
        }
        activeUtteranceID = ObjectIdentifier(utterance)
        self.onFinish = onFinish
        let synth = AVSpeechSynthesizer()
        synth.delegate = self
        synthesizer = synth
        synth.speak(utterance)
    }

    public func stop() {
        activeUtteranceID = nil
        onFinish = nil
        synthesizer?.delegate = nil
        synthesizer?.stopSpeaking(at: .immediate)
        synthesizer = nil
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let finishedID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, self.activeUtteranceID == finishedID else { return }
            self.activeUtteranceID = nil
            let callback = self.onFinish
            self.onFinish = nil
            callback?()
        }
    }

    public static func voiceChoices(languagePrefix: String) -> [DocumentSpeechVoiceChoice] {
        let prefix = languagePrefix.lowercased()
        return AVSpeechSynthesisVoice.speechVoices().compactMap { voice in
            guard voice.language.lowercased().hasPrefix(prefix) else { return nil }
            return DocumentSpeechVoiceChoice(
                id: voice.identifier, name: voice.name, language: voice.language, quality: voice.quality.rawValue)
        }
        .sorted { lhs, rhs in
            if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    public static func bestVoice(for text: String) -> AVSpeechSynthesisVoice? {
        let language = preferredLanguageTag(for: text)
        let prefix = String(language.prefix(2)).lowercased()
        let matching = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.lowercased().hasPrefix(prefix)
        }
        if let best = matching.max(by: { $0.quality.rawValue < $1.quality.rawValue }) {
            return best
        }
        return AVSpeechSynthesisVoice(language: language)
    }

    public static func preferredLanguageTag(for text: String) -> String {
        if let configured = UserDefaults.standard.string(forKey: DefaultsKey.ttsLanguage),
           !configured.isEmpty, configured != "system" {
            return configured
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if let dominant = recognizer.dominantLanguage {
            switch dominant {
            case .russian: return "ru-RU"
            case .ukrainian: return "uk-UA"
            case .english: return "en-US"
            case .german: return "de-DE"
            case .french: return "fr-FR"
            case .spanish: return "es-ES"
            case .italian: return "it-IT"
            case .portuguese: return "pt-BR"
            case .simplifiedChinese: return "zh-CN"
            case .traditionalChinese: return "zh-TW"
            case .japanese: return "ja-JP"
            case .korean: return "ko-KR"
            default: break
            }
        }
        if text.range(of: #"[А-Яа-яЁё]"#, options: .regularExpression) != nil {
            return "ru-RU"
        }
        return AVSpeechSynthesisVoice.currentLanguageCode()
    }
}
