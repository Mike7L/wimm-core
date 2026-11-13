import ArgumentParser
import Foundation
import WimmSecretary

extension Secretary {
    struct TerraAPI: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "terra-api", abstract: "Run a prepared packet on Terra through the configured OpenRouter API; preview by default")
        @Argument var runID: String
        @Flag(name: .long) var send = false
        @Flag(name: .long) var apply = false
        func run() async throws {
            guard send || !apply else { throw ValidationError("--apply requires --send") }
            let data = try await SecretaryPacketFiles.terraAPI(runID: runID, send: send, commit: apply)
            print(String(decoding: data, as: UTF8.self))
            let report = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let v = report?["validation"] as? [String: Any],
               v["accepted"] as? Bool != true || !(v["findings"] as? [String] ?? []).isEmpty { throw ExitCode(1) }
        }
    }
}
