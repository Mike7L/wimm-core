import Foundation
import WimmDomain

func makeHUDControllerDependencies(container: AppContainer) -> HUDController.Dependencies {
    HUDController.Dependencies(
        rootPath: container.storageRoot.path,
        storage: container.storage,
        transcriber: container.transcriber,
        queueSupervisor: container.queueSupervisor,
        loadSnapshot: {
            let notes = try await container.listNotes.execute()
            let queue = try await container.queueStatus.execute()
            return HUDSnapshotService.makeSnapshot(notes: notes, queue: queue)
        }
    )
}

func runHUDExternalAction(
    _ action: HUDExternalAction,
    in terminal: inout TerminalRawMode,
    container: AppContainer
) async throws {
    switch action {
    case .processQueue:
        try await runHUDAction(in: &terminal, title: "Process queue (c)") {
            try await WimmTUIRuntime.runQueue(args: ["process"], container: container)
        }
    case .exportNotes:
        try await runHUDAction(in: &terminal, title: "Export notes (e)") {
            try await WimmTUIRuntime.runExport(args: ["--limit", "50"], container: container)
        }
    case .showStats:
        try await runHUDAction(in: &terminal, title: "Statistics (s)") {
            try await WimmTUIRuntime.runStats(args: [], container: container)
        }
    case .listRecent:
        try await runHUDAction(in: &terminal, title: "Recent notes (l)") {
            try await WimmTUIRuntime.runList(args: ["--limit", "10"], container: container)
        }
    }
}

func promptHUDTranscriptEdit(
    in terminal: inout TerminalRawMode,
    context: HUDTranscriptEditContext
) async throws -> String? {
    try await runHUDActionResult(in: &terminal, title: "Edit transcript (m)") { () -> String? in
        print("Note: [\(context.shortID)]")
        print("Current transcript:")
        if context.currentText.isEmpty {
            print("(empty)")
        } else {
            print(context.currentText)
        }
        print("")
        print("Enter new transcript text (single line).")
        print("Leave empty to cancel.")
        print("> ", terminator: "")
        guard let line = readLine() else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : line
    }
}

private func runHUDAction(
    in terminal: inout TerminalRawMode,
    title: String,
    action: () async throws -> Void
) async throws {
    _ = try await runHUDActionResult(in: &terminal, title: title) {
        try await action()
        return ()
    }
}

private func runHUDActionResult<T>(
    in terminal: inout TerminalRawMode,
    title: String,
    action: () async throws -> T
) async throws -> T {
    terminal.disable()
    defer {
        try? terminal.enable()
    }

    print("")
    print("=== \(title) ===")
    let result = try await action()
    print("")
    print("Press Enter to return to HUD...", terminator: "")
    _ = readLine()
    return result
}
