import AppKit
import Foundation

/// Starts the Studio web service (Vite dev server in `Apps/WimmStudioWeb`) on
/// demand and opens it in the default browser. If the port already answers,
/// the running server is reused and nothing is started.
@MainActor
final class StudioWebLauncher {
    static let port = 5179
    static let url = URL(string: "http://localhost:\(port)/")!
    /// Overridable with `defaults write <bundle> studioWebDirectory <path>`.
    static let directoryDefaultsKey = "studioWebDirectory"

    private var process: Process?
    private var task: Task<Void, Never>?

    var directory: URL {
        if let path = UserDefaults.standard.string(forKey: Self.directoryDefaultsKey), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Projects/Memario/Apps/WimmStudioWeb")
    }

    /// Opens the web UI, starting the service first when it is not running.
    func open() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil }
            if await !Self.isUp() {
                guard self.startService() else { return }
                guard await self.waitUntilUp() else {
                    self.fail("Веб-сервис не ответил на порту \(Self.port). Проверьте, что npm install выполнен в \(self.directory.path).")
                    return
                }
            }
            NSWorkspace.shared.open(Self.url)
        }
    }

    private func startService() -> Bool {
        let dir = directory
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("package.json").path) else {
            fail("Не найден веб-проект: \(dir.path). Задайте путь: defaults write com.micha.wimm.macos \(Self.directoryDefaultsKey) <путь>.")
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Login + interactive shell so nvm-installed node/npm are on PATH.
        process.arguments = ["-ilc", "exec npm run dev -- --strictPort"]
        process.currentDirectoryURL = dir
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            fail("Не удалось запустить веб-сервис: \(error.localizedDescription)")
            return false
        }
        self.process = process
        return true
    }

    private func waitUntilUp() async -> Bool {
        for _ in 0..<60 {
            if await Self.isUp() { return true }
            if let process, !process.isRunning { return false }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    private static func isUp() async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode < 500
    }

    private func fail(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Веб не открылся"
        alert.informativeText = message
        alert.runModal()
    }
}
