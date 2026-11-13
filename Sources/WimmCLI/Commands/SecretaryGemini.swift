import ArgumentParser
import Foundation
import WimmSecretary

extension Secretary {
    struct GeminiBenchmark: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "benchmark-gemini", abstract: "Evaluate captured benchmark text using isolated fixtures; cannot apply")
        @Option(name: .long) var prompt: String
        @Option(name: .long) var input: String
        @Option(name: .long) var documentSnapshot: String
        @Option(name: .long) var registry: String
        @Option(name: .long) var output: String
        @Option(name: .long) var model: String
        @Option(name: .long) var response: String?
        @Flag(name: .long) var send = false
        func run() async throws {
            let data = try await SecretaryGeminiBenchmark.run(promptFile: URL(fileURLWithPath: prompt), inputFile: URL(fileURLWithPath: input),
                documentSnapshot: URL(fileURLWithPath: documentSnapshot), registry: URL(fileURLWithPath: registry), output: URL(fileURLWithPath: output),
                model: model, responseFile: response.map { URL(fileURLWithPath: $0) }, send: send)
            print(String(decoding: data, as: UTF8.self))
        }
    }

    struct GeminiReplay: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "replay-gemini", abstract: "Replay an exact historical Gemini request in an isolated dry run; cannot apply")
        @Argument var runID: String
        @Option(name: .long) var originalRequest: String
        @Option(name: .long) var output: String
        @Option(name: .long) var model: String
        @Flag(name: .long) var send = false
        func run() async throws {
            let data = try await SecretaryPacketFiles.replayGemini(runID: runID,
                originalRequest: URL(fileURLWithPath: originalRequest), output: URL(fileURLWithPath: output), model: model, send: send)
            print(String(decoding: data, as: UTF8.self))
        }
    }

    struct GeminiPacket: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "gemini", abstract: "Send a prepared format-2 packet through Gemini; preview by default")
        @Argument var runID: String
        @Flag(name: .long) var send = false
        @Flag(name: .long) var apply = false
        @Option(name: .long) var model = "gemini-3.8-flash"
        func run() async throws {
            guard send || !apply else { throw ValidationError("--apply requires --send") }
            let data = try await SecretaryPacketFiles.gemini(runID: runID, send: send, commit: apply, model: model)
            print(String(decoding: data, as: UTF8.self))
            let report = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let v = report?["validation"] as? [String: Any],
               v["accepted"] as? Bool != true || !(v["findings"] as? [String] ?? []).isEmpty { throw ExitCode(1) }
        }
    }
}
