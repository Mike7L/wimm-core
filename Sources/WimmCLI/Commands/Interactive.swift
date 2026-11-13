import ArgumentParser
import WimmTUI
import Foundation

struct Interactive: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Interactive mode")

    func run() async throws {
        print("Entering WIMM Interactive Mode. Type 'exit' to quit.")
        print("Commands: list [limit], view <id-prefix>, search <query>, like <id-prefix>, delete <id-prefix>, help, exit")
        while true {
            print("\n> ", terminator: "")
            guard let line = readLine() else { break }
            let parts = line.split(separator: " ").map(String.init)
            guard let cmd = parts.first else { continue }
            if cmd == "exit" || cmd == "quit" { break }
            switch cmd {
            case "help":
                print("  list [limit]    - List recent notes")
                print("  view <id-prefix> - View note by id prefix")
                print("  search <query>  - Full-text search")
                print("  like <id-prefix>   - Toggle note like flag")
                print("  delete <id-prefix> - Delete note")
                print("  exit            - Exit")
            case "list":
                let limit = parts.count > 1 ? (Int(parts[1]) ?? 10) : 10
                try await WimmTUIRuntime.runOnce(["list", "--limit", "\(limit)"])
            case "search":
                if parts.count > 1 {
                    let q = parts.dropFirst().joined(separator: " ")
                    try await WimmTUIRuntime.runOnce(["search", "--text", q])
                } else {
                    print("Usage: search <query>")
                }
            case "view":
                if parts.count > 1 {
                    try await WimmTUIRuntime.runOnce(["read", parts[1]])
                } else {
                    print("Usage: view <id_prefix>")
                }
            case "like":
                if parts.count > 1 {
                    try await WimmTUIRuntime.runOnce(["notes", "like", parts[1]])
                } else {
                    print("Usage: like <id-prefix>")
                }
            case "delete":
                if parts.count > 1 {
                    try await WimmTUIRuntime.runOnce(["delete", parts[1]])
                } else {
                    print("Usage: delete <id-prefix>")
                }
            case "reset":
                try await WimmTUIRuntime.runOnce(["list", "--limit", "10"])
            default:
                print("Unknown command: \(cmd). Type 'help' for available commands.")
            }
        }
    }
}
