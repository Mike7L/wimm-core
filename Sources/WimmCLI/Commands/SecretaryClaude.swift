import ArgumentParser
import Foundation
import WimmSecretary

extension Secretary {
    struct ClaudePacket: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "claude", abstract: "Send a prepared format-2 packet to Haiku; preview by default")
        @Argument var runID: String
        @Flag(name: .long) var send = false
        @Flag(name: .long) var apply = false
        @Option(name: .long, help: "Reasoning effort: low, medium or high") var effort = "high"
        func run() async throws {
            guard send || !apply else { throw ValidationError("--apply requires --send") }
            guard ["low", "medium", "high"].contains(effort) else { throw ValidationError("--effort must be low, medium or high") }
            let data = try await SecretaryPacketFiles.claude(runID: runID, send: send, commit: apply, effort: effort)
            print(String(decoding: data, as: UTF8.self))
            let report = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let v = report?["validation"] as? [String: Any],
               v["accepted"] as? Bool != true || !(v["findings"] as? [String] ?? []).isEmpty { throw ExitCode(1) }
        }
    }
}
