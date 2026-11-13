import Foundation

/// One finished or interrupted run as the secretary window shows it: the run record plus, for a
/// response-format-2 packet pass, what the host made of the reply (`packet-edit-report.json`).
/// Read-only; nothing here writes into a run.
public struct SecretaryRunSummary: Sendable, Identifiable, Equatable {
    public struct Edits: Sendable, Equatable {
        public struct Entry: Sendable, Equatable, Hashable {
            public let source: String
            public let detail: String?
        }
        public let accepted: Bool
        public let rejection: String?
        public let lazyReply: Bool
        public let editCount: Int
        /// used | reviewed | unfinished | unmentioned | rejected → number of sources.
        public let outcomes: [String: Int]
        public let unfinished: [Entry]
        /// Text the accepted edits removed, verbatim, for review.
        public let deleted: [Entry]
        public func count(_ outcome: String) -> Int { outcomes[outcome] ?? 0 }
    }

    public let id: String
    public let directory: URL
    public let record: SecretaryRunRecord?
    public let edits: Edits?

    /// Run ids start with `yyyyMMdd-HHmmss`; anything else in `secretary/runs` is not a run.
    public var startedAt: Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.date(from: String(id.prefix(15)))
    }
}

public enum SecretaryRunHistory {
    /// Newest runs first. Folders without `run.json` (experiments, prepared file sessions) are skipped.
    public static func recent(_ workspace: SecretaryWorkspace, limit: Int = 20) -> [SecretaryRunSummary] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: workspace.runsDirectory.path)) ?? []
        var runs: [SecretaryRunSummary] = []
        for name in names.sorted(by: >) where name.first?.isNumber == true {
            let directory = workspace.runDirectory(name)
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("run.json").path) else { continue }
            runs.append(load(directory))
            if runs.count == limit { break }
        }
        return runs
    }

    public static func load(_ directory: URL) -> SecretaryRunSummary {
        SecretaryRunSummary(id: directory.lastPathComponent, directory: directory,
                            record: SecretaryDispatcher.readRecord(directory), edits: edits(directory))
    }

    static func edits(_ directory: URL) -> SecretaryRunSummary.Edits? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(SecretaryPacket.editsReportName)),
              let report = try? JSONDecoder().decode(SecretaryPacket.EditsReport.self, from: data) else { return nil }
        let outcomes = Dictionary(grouping: report.sources, by: \.outcome).mapValues(\.count)
        return .init(accepted: report.accepted, rejection: report.rejection, lazyReply: report.lazyReply,
                     editCount: report.edits.count, outcomes: outcomes,
                     unfinished: report.sources.filter { $0.outcome == "unfinished" }.map { .init(source: $0.id, detail: $0.reason) },
                     deleted: report.edits.compactMap { edit in
                         guard let deleted = edit.deleted, !deleted.isEmpty else { return nil }
                         return .init(source: edit.sources.joined(separator: ", "), detail: deleted)
                     })
    }
}

/// Which reply shape packet passes ask for. Format 2 is the only supported format (Format 1 has been removed).
public enum SecretaryResponseFormatSetting {
    public static func current(_ workspace: SecretaryWorkspace) -> Int { 2 }

    /// Format 2 is available when its protocol exists in one of the two places.
    public static func isAvailable(_ workspace: SecretaryWorkspace) -> Bool {
        FileManager.default.fileExists(atPath: policy(workspace).path) || FileManager.default.fileExists(atPath: parked(workspace).path)
    }

    public static func set(_ format: Int, in workspace: SecretaryWorkspace) throws {
        guard format == 2 else {
            throw SecretaryPacket.Failure("Only response format 2 is supported; format 1 has been removed.")
        }
        let from = parked(workspace), to = policy(workspace)
        guard FileManager.default.fileExists(atPath: from.path) else { return }
        if FileManager.default.fileExists(atPath: to.path) { try FileManager.default.removeItem(at: to) }
        try FileManager.default.moveItem(at: from, to: to)
    }

    static func policy(_ workspace: SecretaryWorkspace) -> URL { workspace.root.appendingPathComponent(SecretaryPacket.editsPolicyPath) }
    static func parked(_ workspace: SecretaryWorkspace) -> URL { workspace.root.appendingPathComponent(SecretaryPacket.editsPolicyPath + ".off") }
}

/// Reasoning effort for runs started from the app. Empty means automatic: the agent's own
/// default, except format-2 packet passes on Haiku, which run at high (`packetEffort`).
public enum SecretaryEffortSetting {
    public static let defaultsKey = "Secretary.effort"
    public static let options = ["", "low", "medium", "high"]

    public static func preferred(defaults: UserDefaults = .standard) -> String {
        let value = defaults.string(forKey: defaultsKey) ?? ""
        return options.contains(value) ? value : ""
    }

    public static func store(_ value: String, defaults: UserDefaults = .standard) {
        if value.isEmpty || !options.contains(value) { defaults.removeObject(forKey: defaultsKey) }
        else { defaults.set(value, forKey: defaultsKey) }
    }
}
