import Foundation
import WimmDomain
import WimmInfrastructure

/// Runs one secretary task end to end: refuse in private mode, lock, write
/// the task, back up the document, hand over to the executor, verify, record.
/// The agent edits; this type only prepares and checks (`docs/Secretary_Dispatcher.md`).
public struct SecretaryDispatcher: Sendable {
    public let executor: SecretaryExecutor
    public let wimmCLI: URL
    public var budgetUSD: Double
    public var model: String?
    public var timeout: TimeInterval
    /// Overrides the run kind's turn ceiling (`SecretaryRunKind.maxTurns`).
    public var maxTurns: Int?
    public var effort: String?
    /// nil: workspace opt-in for Claude/ChatGPT full passes; false retains the agent workflow.
    public var packetMode: Bool? = nil
    public var packetSourceKB: Int = SecretaryPacketSettings.preferredKB()
    public var optimizationLevel: SecretaryOptimizationLevel = SecretaryOptimizationLevel.preferred()
    private var packetSourceBytes: Int { SecretaryPacketSettings.normalize(packetSourceKB) * 1000 }
    /// What the CLI lacks for a run of a kind (`SecretaryCLICheck`); tests replace it.
    public var cliCheck: @Sendable (URL, SecretaryRunKind) async -> [String]

    public init(executor: SecretaryExecutor, wimmCLI: URL, budgetUSD: Double = 2,
                model: String? = nil, timeout: TimeInterval = 20 * 60, maxTurns: Int? = nil, effort: String? = nil,
                cliCheck: @escaping @Sendable (URL, SecretaryRunKind) async -> [String] = { cli, kind in
                    await SecretaryCLICheck.missing(cli: cli, kind: kind, environment: kind.mcpEnvironment)
                }) {
        self.executor = executor; self.wimmCLI = wimmCLI
        self.budgetUSD = budgetUSD; self.model = model; self.timeout = timeout
        self.maxTurns = maxTurns; self.effort = effort; self.cliCheck = cliCheck
    }

    /// The Wimm CLI an agent may run: `WIMM_CLI_PATH`, `WimmCLI.app` beside
    /// the app, the running CLI itself, then the MCP install. Never the copy
    /// inside `Wimm.app` — its iCloud entitlements get it killed outside the app.
    public static func locateWimmCLI(environment: [String: String] = ProcessInfo.processInfo.environment,
                                     appBundle: URL? = Bundle.main.bundleURL,
                                     runningExecutable: URL? = Bundle.main.executableURL,
                                     home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> URL? {
        var candidates: [URL] = []
        if let explicit = environment["WIMM_CLI_PATH"], !explicit.isEmpty { candidates.append(URL(fileURLWithPath: explicit)) }
        if let appBundle, appBundle.pathExtension == "app" {
            candidates.append(appBundle.deletingLastPathComponent().appendingPathComponent("WimmCLI.app/Contents/MacOS/WimmCLI"))
        }
        if let runningExecutable, runningExecutable.lastPathComponent == "WimmCLI",
           !runningExecutable.path.contains("/Wimm.app/") {
            candidates.append(runningExecutable)
        }
        candidates.append(home.appendingPathComponent(".local/share/wimm/WimmCLI"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }?.standardizedFileURL
    }

    /// The pending comment threads of a document, ready to run (writes nothing).
    public func prepareComments(document: URL, now: Date = Date()) async throws -> SecretaryTask {
        guard let workspace = SecretaryWorkspace(document: document) else { throw SecretaryError.notAWorkspace(document.path) }
        if executor.name == "gemini" {
            throw SecretaryPacket.Failure("Gemini supports pass packets only. To answer comments, use Claude or ChatGPT (Codex).")
        }
        let snapshot = try await DocumentCommentStore(document: workspace.document).load()
        let pending = snapshot.threads.filter { $0.status == .open }
        guard !pending.isEmpty else { throw SecretaryError.nothingToDo }
        return SecretaryTask(id: SecretaryClock.runID(now), kind: .comments, workspace: workspace,
                             threads: pending, wimmCLI: wimmCLI.path, createdAt: now)
    }

    /// A full pass started by hand: open threads first, then new and changed
    /// notes. With no open thread and no pending note (`SecretaryPassPlanner`)
    /// it throws `nothingToDo` instead of paying a model to find that out;
    /// `force` runs it anyway.
    public func preparePass(document: URL, now: Date = Date(), force: Bool = false,
                            scan: @Sendable () async -> SecretaryPassScan? = { await SecretaryPassPlanner.scan() }) async throws -> SecretaryTask {
        guard let workspace = SecretaryWorkspace(document: document) else { throw SecretaryError.notAWorkspace(document.path) }
        let snapshot = try await DocumentCommentStore(document: workspace.document).load()
        if !force, !snapshot.threads.contains(where: { $0.status == .open }) {
            let found = await scan()
            if let found, found.pending == 0 { throw SecretaryError.nothingToDo }
        }
        let open = snapshot.threads.filter { $0.status == .open }
        if !open.isEmpty, executor.name == "gemini" {
            throw SecretaryPacket.Failure("Open comment threads exist. Gemini supports pass packets only; answer comments with Claude or Codex first.")
        }
        let packet = packetMode ?? (["claude-code", "codex", "gemini"].contains(executor.name) && open.isEmpty && FileManager.default.fileExists(atPath: workspace.root.appendingPathComponent("secretary/protocol/packet.md").path))
        if packet, !["claude-code", "codex", "gemini"].contains(executor.name) { throw SecretaryPacket.Failure("Packet workflow requires Claude, ChatGPT (Codex), or Gemini.") }
        return SecretaryTask(id: SecretaryClock.runID(now), kind: .pass, workspace: workspace,
                             threads: open, wimmCLI: wimmCLI.path, createdAt: now, packetMode: packet)
    }

    /// A pass reads many notes; it gets an hour however short the comments limit is.
    public func timeout(for kind: SecretaryRunKind) -> TimeInterval {
        kind == .pass ? max(timeout, 60 * 60) : timeout
    }

    /// Read-only local estimate; no prompt, receipt, mark or model call is written.
    public func packetPreview(_ task: SecretaryTask) async throws -> String {
        let library = await LibraryRecallSource(buildMode: .subprocess(executable: wimmCLI, arguments: ["mcp-build"]), includeFingerprints: true).load()
        let packet = try SecretaryPacket.prepare(task: task, library: library, sourceByteLimit: packetSourceBytes, optimizationLevel: optimizationLevel)
        let prompt = try packet.prompt()
        let solo = packet.payload["solo_large_source"] as? Bool == true ? " Solo packet for a complete long source." : ""
        let scope = packet.projectedSourceIDs.isEmpty ? "complete sources" : "experimental projected sources (coverage unvalidated; preview only)"
        return "Packet: \(packet.selected.count) \(scope) (\(packet.selected.joined(separator: ", "))); \(prompt.utf8.count) input bytes + \(packet.system.utf8.count) policy bytes; \(packet.payload["remaining"] ?? "?") left.\(solo) No model call or workspace changes."
    }

    /// Runs a prepared task. Throws only before the agent starts (private
    /// mode, busy, I/O); everything after is reported in the record.
    public func run(_ task: SecretaryTask,
                    onEvent: @escaping @Sendable (SecretaryEvent) -> Void = { _ in }) async throws -> SecretaryRunRecord {
        guard !PrivateMode.isEnabled else { throw SecretaryError.privateMode }
        let missing = await cliCheck(wimmCLI, task.kind)
        guard missing.isEmpty else { throw SecretaryError.wimmCLIStale(wimmCLI.path, missing) }
        let workspace = task.workspace
        let lock = try SecretaryRunLock.acquire(in: workspace.runsDirectory, runID: task.id)
        defer { lock.release() }

        let directory = workspace.runDirectory(task.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if workspace.hasManagedProtocol || task.packetMode { try SecretaryContext.write(task: task, directory: directory) }
        try task.markdown().write(to: directory.appendingPathComponent("task.md"), atomically: true, encoding: .utf8)
        let backup = try Self.backUp(workspace.document, at: task.createdAt)

        var record = SecretaryRunRecord(id: task.id, kind: task.kind, doc: workspace.doc, executor: executor.name,
                                        model: model, threadIDs: task.threads.map(\.id),
                                        startedAt: SecretaryClock.stamp(Date()), backup: workspace.relative(backup))
        record.workflow = task.packetMode ? "packet" : "agent"
        try Self.write(record, to: directory)
        let before = SecretarySnapshot.take(workspace)
        onEvent(.init(.info, "run \(task.id): \(task.threads.count) thread(s), backup \(workspace.relative(backup))"))

        var request = SecretaryExecutionRequest(workspaceRoot: workspace.root, runDirectory: directory, prompt: task.prompt,
                                                kind: task.kind, wimmCLI: wimmCLI.path, budgetUSD: budgetUSD,
                                                model: model, timeout: timeout(for: task.kind), maxTurns: maxTurns, effort: effort)
        request.reviewBackup = backup
        request.reviewDocument = workspace.doc
        do {
            if !task.packetMode {
                let receipts = SecretaryReadReceipt.logURL(runID: task.id)
                for url in [receipts, receipts.appendingPathExtension("queue"), receipts.appendingPathExtension("review")] {
                    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                }
            }
            let execution: SecretaryExecution
            if task.packetMode {
                execution = try await runPacket(task: task, onEvent: onEvent)
            } else {
                execution = try await executor.run(request, onEvent: onEvent)
            }
            record.exitStatus = execution.exitStatus
            record.model = execution.model ?? model
            record.costUSD = execution.costUSD
            record.tokensIn = execution.tokensIn
            record.tokensOut = execution.tokensOut
            record.turns = execution.turns
            record.sessionID = execution.sessionID
            record.finalText = execution.finalText
            record.error = execution.error
            record.outcome = execution.isError || execution.exitStatus != 0 ? .failed : .succeeded
        } catch is CancellationError {
            record.outcome = .cancelled
            record.error = "Cancelled"
        } catch {
            record.outcome = .failed
            record.error = error.localizedDescription
        }

        let (result, resultError) = Self.readResult(directory.appendingPathComponent("result.json"))
        record.result = result
        record.findings = SecretaryVerification.findings(task: task, before: before, after: .take(workspace),
                                                         result: result, resultError: resultError)
        record.findings += SecretaryCompletion.findings(task: task, backup: backup)
        if task.kind == .pass, record.outcome == .succeeded, record.findings.isEmpty, let result {
            let report = await SecretaryBookkeeping.finish(task: task, result: result)
            record.bookkeeping = report
            record.findings += report.findings
            onEvent(.init(.info, "Wimm bookkeeping: \(report.stored)/\(report.requested) reviewed sources marked; registry \(report.registryUpdated ?? 0), references \(report.referencesAdded ?? 0)"))
        }
        if Task.isCancelled {
            record.outcome = .cancelled
            record.error = "Cancelled"
        }
        if task.kind == .pass, record.outcome == .succeeded, record.findings.isEmpty,
           let data = try? Data(contentsOf: directory.appendingPathComponent("packet-task-report.json")),
           let reports = try? JSONDecoder().decode([SecretaryPacket.TaskReport].self, from: data) {
            let dropped = reports.filter { $0.state == "applied" }.flatMap { $0.droppedReferences ?? [] }
            let requeued = SecretaryBookkeeping.requeue(dropped, workspace: workspace)
            if !requeued.isEmpty {
                record.requeuedNotes = requeued
                onEvent(.init(.info, "requeued \(requeued.count) notes whose references this pass removed"))
            }
        }
        if let data = try? Data(contentsOf: directory.appendingPathComponent(SecretaryHostQueues.fileName)) {
            record.hostQueues = try? JSONDecoder().decode(SecretaryHostQueues.self, from: data)
        }
        if task.kind == .pass, record.outcome == .succeeded, record.findings.isEmpty {
            record.remainingNotes = await Self.advanceBoundary(startedAt: task.createdAt)
            if record.remainingNotes == nil {
                record.findings.append("Cannot determine remaining queue coverage after the pass.")
            } else if let remaining = record.remainingNotes, remaining > 0 {
                record.outcome = .incomplete
                onEvent(.init(.info, "Pass applied a batch; \(remaining) notes remain pending."))
            }
        }
        if record.outcome == .succeeded, !record.findings.isEmpty { record.outcome = .failed }
        record.finishedAt = SecretaryClock.stamp(Date())
        try? Self.write(record, to: directory)
        Self.log(record)
        for finding in record.findings { onEvent(.init(.error, finding)) }
        onEvent(.init(.info, "\(record.outcome?.rawValue ?? "?")\(record.costUSD.map { String(format: " · $%.2f", $0) } ?? "")"))
        return record
    }

    func runPacket(task: SecretaryTask, library: RecallLibrary? = nil, marks: AgentMarkStore = AgentMarkStore(),
                   onEvent: @escaping @Sendable (SecretaryEvent) -> Void) async throws -> SecretaryExecution {
        let loaded: RecallLibrary
        if let library { loaded = library }
        else { loaded = await LibraryRecallSource(buildMode: .subprocess(executable: wimmCLI, arguments: ["mcp-build"]), includeFingerprints: true).load() }
        var packet = try SecretaryPacket.prepare(task: task, library: loaded, marks: marks, sourceByteLimit: packetSourceBytes, optimizationLevel: optimizationLevel)
        try packet.requireValidatedProjection() // Refuse before spending on an unacknowledgeable projection.
        var prompt = try packet.prompt(), aggregate = SecretaryExecution(exitStatus: 0, costUSD: 0)
        let queues = packet.hostQueues, runDirectory = task.workspace.runDirectory(task.id)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(queues).write(to: runDirectory.appendingPathComponent(SecretaryHostQueues.fileName), options: .atomic)
        onEvent(.init(.info, "kept out of the packet: \(queues.waitingForText) waiting for text, \(queues.waitingForViewing) waiting for viewing, \(queues.skipped) skipped"))
        let maxRounds = 2
        var validationPrompt = prompt
        let directory = task.workspace.runDirectory(task.id)
        for round in 1...maxRounds {
            guard !Task.isCancelled else { throw CancellationError() }
            guard !PrivateMode.isEnabled else {
                aggregate.isError = true; aggregate.error = SecretaryError.privateMode.localizedDescription
                return aggregate
            }
            // Codex uses the ChatGPT plan and reports tokens, not a dollar cost.
            // Keep unknown cost unknown; metered executors still fail closed.
            let spent = aggregate.costUSD ?? 0
            guard aggregate.costUSD != nil || executor.name == "codex" else {
                aggregate.isError = true; aggregate.error = "Packet cost is unknown; refusing an additional paid request."
                return aggregate
            }
            guard executor.name == "codex" || budgetUSD - spent >= 0.01 else {
                aggregate.isError = true; aggregate.error = "Packet budget exhausted before context expansion."
                return aggregate
            }
            let roundDirectory = directory.appendingPathComponent("packet-\(round)")
            try FileManager.default.createDirectory(at: roundDirectory, withIntermediateDirectories: true)
            try Data(prompt.utf8).write(to: roundDirectory.appendingPathComponent("input.json"), options: .atomic)
            onEvent(.init(.info, "packet \(round): \(packet.selected.count) sources, \(prompt.utf8.count) input bytes"))
            var request = SecretaryExecutionRequest(workspaceRoot: roundDirectory, runDirectory: roundDirectory, prompt: prompt,
                kind: .pass, wimmCLI: wimmCLI.path, budgetUSD: budgetUSD - spent, model: model,
                timeout: timeout(for: .pass), maxTurns: 1, effort: packetEffort())
            request.systemPrompt = packet.system
            request.packetSession = false
            request.resumeSessionID = nil
            try packetAudit(directory, stage: "packet_request",
                detail: "round=\(round); input_bytes=\(prompt.utf8.count)")
            let execution = try await executor.run(request, onEvent: onEvent)
            try JSONEncoder().encode(execution).write(to: roundDirectory.appendingPathComponent("execution.json"), options: .atomic)
            aggregate.exitStatus = execution.exitStatus; aggregate.isError = execution.isError
            aggregate.finalText = execution.finalText; aggregate.error = execution.error; aggregate.model = execution.model
            aggregate.sessionID = execution.sessionID
            aggregate.costUSD = aggregate.costUSD.flatMap { total in execution.costUSD.map { total + $0 } }
            aggregate.tokensIn = round == 1 ? execution.tokensIn : aggregate.tokensIn.flatMap { total in execution.tokensIn.map { total + $0 } }
            aggregate.tokensOut = round == 1 ? execution.tokensOut : aggregate.tokensOut.flatMap { total in execution.tokensOut.map { total + $0 } }
            aggregate.turns = round == 1 ? execution.turns : aggregate.turns.flatMap { total in execution.turns.map { total + $0 } }
            // Persist each paid round before decoding/applying; failures must retain their cost.
            try JSONEncoder().encode(aggregate).write(to: directory.appendingPathComponent("packet-execution.json"), options: .atomic)
            if aggregate.isError || execution.exitStatus != 0 { return aggregate }
            do {
                let reply = try SecretaryPacket.decodeEdits(execution.finalText ?? "")
                // One simple read round: the requested sections, then a complete answer.
                if !reply.readSections.isEmpty, round == 1 {
                    prompt = try packet.prompt(sections: reply.readSections, validationPrompt: validationPrompt)
                    validationPrompt = prompt
                    try packetAudit(directory, stage: "sections_read", detail: reply.readSections.joined(separator: ", "))
                    onEvent(.init(.info, "secretary read sections \(reply.readSections.joined(separator: ", "))"))
                    continue
                }
                // An edit next to an unsupplied section is an implicit read request: supply it once
                // and ask again, rather than rejecting the whole reply with its good edits.
                let missing = round == 1 ? packet.missingSections(reply, prompt: validationPrompt) : []
                if !missing.isEmpty, let expanded = try? packet.prompt(sections: missing, validationPrompt: validationPrompt,
                    note: "Some edits targeted sections that were not supplied (\(missing.joined(separator: ", "))). They are included now. Return your complete answer again; no further reads.") {
                    prompt = expanded; validationPrompt = expanded
                    try packetAudit(directory, stage: "sections_read", detail: "implicit: " + missing.joined(separator: ", "))
                    onEvent(.init(.info, "edits targeted unsupplied sections \(missing.joined(separator: ", ")); reading them once"))
                    continue
                }
                var resolution = try packet.resolveEdits(reply, prompt: validationPrompt, marks: marks)
                // The edits stand. One more short request (no sources, its own contract) rewrites the
                // status lines of the topics they touched; whatever goes wrong there, the edits still apply.
                let spentNow = aggregate.costUSD ?? 0
                if resolution.report.rejection == nil, reply.statusUpdates.isEmpty, let needed = resolution.report.statusNeeded, !needed.isEmpty,
                   !PrivateMode.isEnabled, !Task.isCancelled,
                   executor.name == "codex" || (aggregate.costUSD != nil && budgetUSD - spentNow >= 0.01) {
                    do {
                        let accepted = resolution.report.edits.compactMap { outcome -> (target: String, text: String)? in
                            guard reply.edits.indices.contains(outcome.index) else { return nil }
                            return (outcome.target, reply.edits[outcome.index].text)
                        }
                        let statusPrompt = try packet.statusPrompt(needed: needed, survivors: accepted)
                        let statusDirectory = directory.appendingPathComponent("packet-status")
                        try FileManager.default.createDirectory(at: statusDirectory, withIntermediateDirectories: true)
                        try Data(statusPrompt.utf8).write(to: statusDirectory.appendingPathComponent("input.json"), options: .atomic)
                        var request = SecretaryExecutionRequest(workspaceRoot: statusDirectory, runDirectory: statusDirectory, prompt: statusPrompt,
                            kind: .pass, wimmCLI: wimmCLI.path, budgetUSD: budgetUSD - spentNow, model: model,
                            timeout: timeout(for: .pass), maxTurns: 1, effort: packetEffort())
                        request.systemPrompt = SecretaryPacket.statusContract
                        request.packetSession = false
                        request.resumeSessionID = nil
                        try packetAudit(directory, stage: "status_request", detail: "lines=\(needed.joined(separator: ", ")); input_bytes=\(statusPrompt.utf8.count)")
                        onEvent(.init(.info, "status lines \(needed.joined(separator: ", ")): \(statusPrompt.utf8.count) input bytes"))
                        let execution = try await executor.run(request, onEvent: onEvent)
                        try JSONEncoder().encode(execution).write(to: statusDirectory.appendingPathComponent("execution.json"), options: .atomic)
                        // The main reply's text and status stay the run's; only the usage adds up.
                        aggregate.costUSD = aggregate.costUSD.flatMap { total in execution.costUSD.map { total + $0 } }
                        aggregate.tokensIn = aggregate.tokensIn.flatMap { total in execution.tokensIn.map { total + $0 } }
                        aggregate.tokensOut = aggregate.tokensOut.flatMap { total in execution.tokensOut.map { total + $0 } }
                        aggregate.turns = aggregate.turns.flatMap { total in execution.turns.map { total + $0 } }
                        try JSONEncoder().encode(aggregate).write(to: directory.appendingPathComponent("packet-execution.json"), options: .atomic)
                        guard !execution.isError, execution.exitStatus == 0 else { throw SecretaryPacket.Failure(execution.error ?? "status request failed") }
                        var merged = reply
                        merged.statusUpdates = try SecretaryPacket.decodeEdits(execution.finalText ?? "").statusUpdates
                        let second = try packet.resolveEdits(merged, prompt: validationPrompt, marks: marks)
                        if second.report.rejection == nil { resolution = second }
                        for outcome in second.report.statusUpdates ?? [] where !outcome.accepted {
                            onEvent(.init(.info, "status line \(outcome.block) kept as it was: \(outcome.reason ?? "")"))
                        }
                    } catch {
                        try packetAudit(directory, stage: "status_skipped", detail: error.localizedDescription)
                        onEvent(.init(.info, "status lines not refreshed: \(error.localizedDescription)"))
                    }
                }
                let data = try JSONEncoder().encode(resolution.report)
                try data.write(to: directory.appendingPathComponent(SecretaryPacket.editsReportName), options: .atomic)
                try packetAudit(directory, stage: "edits_validated", detail: String(decoding: data, as: UTF8.self))
                if let rejection = resolution.report.rejection {
                    try packetAudit(directory, stage: "blocked", detail: rejection)
                    onEvent(.init(.error, "packet reply rejected as a whole: \(rejection)"))
                    aggregate.isError = true; aggregate.error = rejection
                    try JSONEncoder().encode(aggregate).write(to: directory.appendingPathComponent("packet-execution.json"), options: .atomic)
                    return aggregate
                }
                onEvent(.init(.info, resolution.plan.summary.prefix(300) + (resolution.report.lazyReply ? " (lists without edits not trusted)" : "")))
                for rejected in resolution.report.rejectedEdits ?? [] {
                    onEvent(.init(.info, "edit dropped with its sources: \(rejected.reason)"))
                }
                guard !Task.isCancelled else { throw CancellationError() }
                let result: SecretaryResult
                if resolution.plan.sourceDecisions.isEmpty, resolution.plan.edits.isEmpty, resolution.plan.questions.isEmpty {
                    result = SecretaryResult(summary: resolution.plan.summary, reviewedSources: [], sourceDecisions: [], changedFiles: [], questions: [])
                } else {
                    result = try resolution.packet.apply(resolution.plan, prompt: validationPrompt, marks: marks)
                }
                try packetAudit(directory, stage: "applied", detail: resolution.plan.summary)
                try JSONEncoder().encode(result).write(to: directory.appendingPathComponent("result.json"), options: .atomic)
                return aggregate
            } catch {
                try packetAudit(directory, stage: "blocked", detail: error.localizedDescription)
                onEvent(.init(.error, "packet blocked: \(error.localizedDescription)"))
                aggregate.isError = true; aggregate.error = error.localizedDescription
                try JSONEncoder().encode(aggregate).write(to: directory.appendingPathComponent("packet-execution.json"), options: .atomic)
                return aggregate
            }
        }
        return aggregate
    }

    /// Format-2 packet passes on Haiku think only when asked: at the default effort 4 of 6 replies
    /// had no reasoning and returned an empty shortcut; at `high` all six reasoned (2026-10-31,
    /// `docs/Secretary_Format2_Haiku_AB_2026-10-31.md`). An explicit effort always wins.
    func packetEffort() -> String? {
        if let effort { return effort }
        return (model ?? "").lowercased().contains("haiku") ? "high" : nil
    }

    /// An append-only local audit, also surfaced through the live run event stream.
    private func packetAudit(_ directory: URL, stage: String, detail: String) throws {
        let url = directory.appendingPathComponent("packet-validation.jsonl")
        var data = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : Data()
        data.append(try JSONSerialization.data(withJSONObject: ["at": ISO8601DateFormatter().string(from: Date()),
                                                               "stage": stage, "detail": detail], options: [.sortedKeys]))
        data.append(10)
        try data.write(to: url, options: .atomic)
    }

    /// Local deterministic maintenance: no editor, no review/mark inference, no boundary advance.
    public static func reconcile(document: URL, apply: Bool = false) async throws -> SecretaryBookkeepingReport {
        guard !PrivateMode.isEnabled else { throw SecretaryError.privateMode }
        guard let workspace = SecretaryWorkspace(document: document) else { throw SecretaryError.notAWorkspace(document.path) }
        let id = SecretaryClock.runID(Date()) + "-reconcile"
        let lock: SecretaryRunLock?
        if apply { lock = try SecretaryRunLock.acquire(in: workspace.runsDirectory, runID: id) } else { lock = nil }
        defer { lock?.release() }
        let task = SecretaryTask(id: id, kind: .pass, workspace: workspace, threads: [], wimmCLI: "", createdAt: Date())
        return await SecretaryBookkeeping.finish(task: task, result: SecretaryResult(reviewedSources: []), applyChanges: apply, reconcileMediaAliases: true)
    }

    /// After a clean pass the boundary moves up to where the pass started, but
    /// never past a note that is still pending (the agent may have left some).
    @discardableResult
    static func advanceBoundary(startedAt: Date, marks: AgentMarkStore = AgentMarkStore()) async -> Int? {
        guard let scan = await SecretaryPassPlanner.scan(marks: marks, initialBoundary: .distantPast) else { return nil }
        if let next = SecretaryPassPlanner.advancedBoundary(after: scan, started: startedAt) {
            do { try marks.setPass(.init(asOf: next, cursor: nil, comment: "advanced by Wimm after a verified secretary batch", setAt: Date())) }
            catch { return nil }
        }
        return scan.pending
    }

    /// `docs/.backups/<name>.<stamp>-before-secretary.md`, the `_ME` habit.
    static func backUp(_ document: URL, at date: Date) throws -> URL {
        let directory = document.deletingLastPathComponent().appendingPathComponent(".backups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let name = "\(document.deletingPathExtension().lastPathComponent).\(formatter.string(from: date))-before-secretary.\(document.pathExtension)"
        let target = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.copyItem(at: document, to: target)
        return target
    }

    static func readResult(_ url: URL) -> (SecretaryResult?, String?) {
        guard let data = try? Data(contentsOf: url) else { return (nil, "The agent wrote no result.json.") }
        do { return (try JSONDecoder().decode(SecretaryResult.self, from: data), nil) }
        catch { return (nil, "result.json is not valid: \(error.localizedDescription)") }
    }

    public static func readRecord(_ directory: URL) -> SecretaryRunRecord? {
        (try? Data(contentsOf: directory.appendingPathComponent("run.json")))
            .flatMap { try? JSONDecoder().decode(SecretaryRunRecord.self, from: $0) }
    }

    static func write(_ record: SecretaryRunRecord, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(record).write(to: directory.appendingPathComponent("run.json"), options: .atomic)
    }

    /// The token counters use the event log's `tokens_*` keys, which survive redaction.
    static func log(_ record: SecretaryRunRecord) {
        var attributes = ["run": record.id, "run_kind": record.kind.rawValue, "executor": record.executor,
                          "outcome": record.outcome?.rawValue ?? "unknown", "threads": String(record.threadIDs.count),
                          "findings": String(record.findings.count)]
        if let model = record.model { attributes["model"] = model }
        if let cost = record.costUSD { attributes["cost_usd"] = String(format: "%.4f", cost) }
        if let tokens = record.tokensIn { attributes["tokens_in"] = String(tokens) }
        if let tokens = record.tokensOut { attributes["tokens_out"] = String(tokens) }
        UnifiedEventLogger.shared.logAppEvent(kind: "secretary", phase: record.outcome?.rawValue, origin: record.doc,
                                              message: record.result?.summary ?? record.finalText,
                                              attributes: attributes, error: record.error, source: "SecretaryDispatcher")
    }
}
