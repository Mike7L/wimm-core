import AppKit
import Foundation

/// Starts the Studio web service (the built app in `Apps/WimmStudioWeb/dist`
/// served by `server/start.ts`) on demand and opens it in the default browser.
/// If the port already answers, the running server is reused and nothing is
/// started. No shell is involved: `node` is found by path and run directly.
@MainActor
final class StudioWebLauncher {
    static let port = 5179
    /// The server listens on 127.0.0.1; `localhost` keeps the browser origin
    /// (and its saved settings) the Vite dev server used.
    static let url = URL(string: "http://localhost:\(port)/")!
    /// Overridable with `defaults write <bundle> studioWebDirectory <path>`.
    nonisolated static let directoryDefaultsKey = "studioWebDirectory"
    /// Overridable with `defaults write <bundle> studioWebNodePath <path to node>`.
    static let nodeDefaultsKey = "studioWebNodePath"
    static let serverArguments = [
        "--experimental-strip-types",
        "--disable-warning=ExperimentalWarning",
        "server/start.ts",
    ]
    nonisolated static let setupCommand = "npm ci && npm run build"

    private var process: Process?
    private var task: Task<Void, Never>?

    var directory: URL {
        if let path = UserDefaults.standard.string(forKey: Self.directoryDefaultsKey), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Projects/Memario/Apps/WimmStudioWeb")
    }

    private var logURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("wimm-studio-web.log")
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
                    var message = "Веб-сервис не ответил на порту \(Self.port)."
                    if let tail = self.logTail() {
                        message += "\n\n\(tail)"
                    }
                    message += "\n\nЖурнал: \(self.logURL.path)"
                    self.fail(message)
                    return
                }
            }
            NSWorkspace.shared.open(Self.url)
        }
    }

    // MARK: - Pure parts (tested)

    /// Where `node` may be, in order: the defaults override, Homebrew and the
    /// classic installer, then nvm/Volta installs under the home folder. No
    /// shell profile is read.
    nonisolated static func nodeCandidates(
        override: String?,
        home: URL,
        fileManager: FileManager = .default
    ) -> [String] {
        var result: [String] = []
        if let override, !override.isEmpty {
            result.append((override as NSString).expandingTildeInPath)
        }
        result += ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        let nvmDir = home.appendingPathComponent(".nvm/versions/node")
        let versions = (try? fileManager.contentsOfDirectory(atPath: nvmDir.path)) ?? []
        for version in versions.sorted(by: { compareNodeVersions($0, $1) > 0 }) {
            result.append(nvmDir.appendingPathComponent(version).appendingPathComponent("bin/node").path)
        }
        result.append(home.appendingPathComponent(".volta/bin/node").path)
        return result
    }

    nonisolated static func findNode(
        override: String?,
        home: URL,
        fileManager: FileManager = .default
    ) -> String? {
        nodeCandidates(override: override, home: home, fileManager: fileManager)
            .first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// Compares `v22.13.0`-style names numerically; positive when `a` is newer.
    nonisolated static func compareNodeVersions(_ a: String, _ b: String) -> Int {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                .split(separator: ".")
                .map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    /// Why the web project cannot be started, or nil when it can.
    nonisolated static func setupProblem(directory: URL, fileManager: FileManager = .default) -> String? {
        guard fileManager.fileExists(atPath: directory.appendingPathComponent("package.json").path) else {
            return "Не найден веб-проект: \(directory.path). Задайте путь: defaults write com.micha.wimm.macos \(directoryDefaultsKey) <путь>."
        }
        guard fileManager.fileExists(atPath: directory.appendingPathComponent("server/start.ts").path) else {
            return "В веб-проекте нет server/start.ts: \(directory.path). Обновите проект."
        }
        guard fileManager.fileExists(atPath: directory.appendingPathComponent("dist/index.html").path) else {
            return "Веб-приложение не собрано. Выполните в Терминале:\n\ncd \(directory.path)\n\(setupCommand)"
        }
        return nil
    }

    /// The child's environment: Studio's own plus the folders tools the server calls live in.
    nonisolated static func serverEnvironment(nodePath: String, base: [String: String]) -> [String: String] {
        var env = base
        let extra = [(nodePath as NSString).deletingLastPathComponent, "/opt/homebrew/bin", "/usr/local/bin"]
        let current = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        env["PATH"] = (extra.filter { !current.contains($0) } + current).joined(separator: ":")
        return env
    }

    // MARK: - Process

    private func startService() -> Bool {
        let dir = directory
        if let problem = Self.setupProblem(directory: dir) {
            fail(problem)
            return false
        }
        let override = UserDefaults.standard.string(forKey: Self.nodeDefaultsKey)
        guard let node = Self.findNode(override: override, home: FileManager.default.homeDirectoryForCurrentUser) else {
            fail("Не найден node (нужна версия 22.6 или новее). Установите Node.js или задайте путь: defaults write com.micha.wimm.macos \(Self.nodeDefaultsKey) <путь к node>.")
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = Self.serverArguments
        process.currentDirectoryURL = dir
        process.environment = Self.serverEnvironment(nodePath: node, base: ProcessInfo.processInfo.environment)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = (try? FileHandle(forWritingTo: logURL)) ?? FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            fail("Не удалось запустить веб-сервис (\(node)): \(error.localizedDescription)")
            return false
        }
        self.process = process
        return true
    }

    private func logTail() -> String? {
        guard let data = try? Data(contentsOf: logURL), !data.isEmpty,
              let text = String(data: data.suffix(1500), encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
