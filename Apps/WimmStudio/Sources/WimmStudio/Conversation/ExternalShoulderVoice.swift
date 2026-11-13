import Foundation
import WimmDomain
import WimmInfrastructure

/// One line of the web panel's command file: what Studio should read aloud.
struct ShoulderVoiceCommand: Decodable, Equatable {
    /// `speak`, `stop` or `prepare`.
    var action: String
    /// The panel's id for this command, echoed in the `ack` event.
    var id: String?
    /// The panel's turn; events carry it back so a stale turn is ignored there.
    var turn: String?
    var index: Int?
    var speaker: String?
    var text: String?
    var voice: String?
    var speed: Double?
}

/// Reads the complete lines appended to a file since the last call. The web
/// server only appends; a file that got shorter was started over.
struct AppendedLineReader {
    let url: URL
    private(set) var offset: UInt64

    /// Starts at the end: commands written before Studio launched are not replayed.
    init(url: URL) {
        self.url = url
        offset = Self.size(of: url)
    }

    mutating func next() -> [String] {
        let size = Self.size(of: url)
        if size < offset { offset = 0 }
        guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(),
              let lastNewline = data.lastIndex(of: 0x0A) else { return [] }
        // A line still being written stays for the next call.
        let complete = data[data.startIndex...lastNewline]
        offset += UInt64(complete.count)
        return String(decoding: complete, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private static func size(of url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }
}

/// Reads the web panel's angel-and-demon lines aloud in Studio, where the
/// Supertonic-3 model stays loaded. The panel used to start `wimm-cli speak`
/// per line, which reloaded the model each time: 13–20 s before the first
/// sound (measured 2026-11-10).
///
/// The web server appends commands to `Conversation/shoulders_voice_commands.jsonl`;
/// Studio answers in `Conversation/shoulders_voice_events.jsonl` (`ack` with
/// `ready`, `started`, `idle`, `failed`). Files, because the server has no faster way
/// to reach Studio and already watches this folder.
@MainActor
final class ExternalShoulderVoice {
    nonisolated static var commandsURL: URL { directory.appendingPathComponent("shoulders_voice_commands.jsonl") }
    nonisolated static var eventsURL: URL { directory.appendingPathComponent("shoulders_voice_events.jsonl") }
    private nonisolated static var directory: URL {
        StoragePaths.baseDirectory().appendingPathComponent("Conversation", isDirectory: true)
    }

    private let player = ShoulderVoicePlayer()
    private var reader: AppendedLineReader?
    private var timer: Timer?
    private var turn: String?

    func start() {
        guard timer == nil else { return }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        // Events are for the running panel only; an old file would just grow.
        try? Data().write(to: Self.eventsURL, options: .atomic)
        reader = AppendedLineReader(url: Self.commandsURL)
        player.onLineStarted = { [weak self] in self?.emit("started", index: $0) }
        player.onIdle = { [weak self] in self?.emit("idle") }
        player.onFailure = { [weak self] in self?.emit("failed") }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // Loading takes about a minute and a half after launch: start now, not at the first line.
        player.prepare()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        silence()
    }

    private func poll() {
        guard let lines = reader?.next(), !lines.isEmpty else { return }
        for line in lines {
            guard let command = try? JSONDecoder().decode(ShoulderVoiceCommand.self, from: Data(line.utf8)) else { continue }
            handle(command)
        }
    }

    private func handle(_ command: ShoulderVoiceCommand) {
        // A fresh Studio loads the model for about a minute and a half. Until then the
        // answer is "not ready" and the panel reads the line its slower way.
        let ready = command.action != "speak" || player.isReady
        emit("ack", id: command.id, turn: command.turn, ready: ready)
        switch command.action {
        case "prepare":
            player.prepare()
            player.warmUp()
        case "stop":
            silence()
        case "speak":
            guard ready else { player.prepare(); return }
            guard let text = command.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
            if command.turn != turn {
                silence()
                turn = command.turn
            }
            let speaker: ShoulderSpeaker = command.speaker == "demon" ? .demon : .angel
            let voices = ShoulderSpeaker.availableFemaleVoices + ShoulderSpeaker.availableMaleVoices
            let voice = command.voice.flatMap { voices.contains($0) ? NeuralSpeech.Voice($0) : nil }
            let speed = command.speed.map { Float(max(0.7, min(1.8, $0))) }
            let index = command.index ?? 0
            player.enqueue(text, speaker: speaker, index: index, voice: voice, speed: speed)
        default:
            break
        }
    }

    private func silence() {
        player.stop()
    }

    private func emit(_ event: String, index: Int? = nil, id: String? = nil, turn: String? = nil,
                      ready: Bool? = nil) {
        var object: [String: Any] = ["event": event]
        if let turn = turn ?? self.turn { object["turn"] = turn }
        if let index { object["index"] = index }
        if let id { object["id"] = id }
        if let ready { object["ready"] = ready }
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        guard let handle = try? FileHandle(forWritingTo: Self.eventsURL) else {
            try? data.write(to: Self.eventsURL, options: .atomic)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
