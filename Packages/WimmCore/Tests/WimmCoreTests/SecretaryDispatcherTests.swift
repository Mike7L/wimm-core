import XCTest
@testable import WimmInfrastructure
@testable import WimmSecretary

final class SecretaryDispatcherTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("secretary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("secretary"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try "# Я\n\nЯ очень люблю горы и море.\n".write(to: document, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private var document: URL { root.appendingPathComponent("docs/me.md") }

    func testModelResolutionUsesExplicitThenSavedThenAgentDefault() throws {
        let suite = "wimm-secretary-model-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(SecretaryAgent.claude.resolvedModel(override: nil, defaults: defaults), "sonnet")
        XCTAssertNil(SecretaryAgent.codex.resolvedModel(override: nil, defaults: defaults))
        XCTAssertEqual(SecretaryAgent.gemini.resolvedModel(override: nil, defaults: defaults), "gemini-flash-latest")
        defaults.set(" opus ", forKey: SecretaryAgent.claude.modelDefaultsKey)
        XCTAssertEqual(SecretaryAgent.claude.resolvedModel(override: nil, defaults: defaults), "opus")
        XCTAssertEqual(SecretaryAgent.claude.resolvedModel(override: "  ", defaults: defaults), "opus")
        XCTAssertEqual(SecretaryAgent.claude.resolvedModel(override: " haiku ", defaults: defaults), "haiku")
        defaults.set(" ", forKey: SecretaryAgent.claude.modelDefaultsKey)
        XCTAssertEqual(SecretaryAgent.claude.resolvedModel(override: nil, defaults: defaults), "sonnet")
        defaults.set(" gemini-pro-latest ", forKey: SecretaryAgent.gemini.modelDefaultsKey)
        XCTAssertEqual(SecretaryAgent.gemini.resolvedModel(override: nil, defaults: defaults), "gemini-pro-latest")
        XCTAssertEqual(SecretaryAgent.gemini.resolvedModel(override: " gemini-flash-latest ", defaults: defaults), "gemini-flash-latest")
    }

    private func addComment(_ text: String) async throws -> DocumentCommentStore {
        let store = DocumentCommentStore(document: document)
        try await store.append(store.newRoot(kind: .comment, selector: TextQuoteSelector(quote: "горы", prefix: "люблю ", suffix: " и"),
                                             section: nil, heading: "Я", text: text))
        return store
    }

    func testWorkspaceNeedsASecretaryFolder() throws {
        let workspace = try XCTUnwrap(SecretaryWorkspace(document: document))
        XCTAssertEqual(workspace.root.path, root.standardizedFileURL.path)
        XCTAssertEqual(workspace.doc, "docs/me.md")
        XCTAssertEqual(workspace.relative(workspace.runDirectory("x")), "secretary/runs/x")

        let loose = FileManager.default.temporaryDirectory.appendingPathComponent("loose-\(UUID().uuidString).md")
        try "x".write(to: loose, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: loose) }
        XCTAssertNil(SecretaryWorkspace(document: loose))
    }

    func testLockIsExclusiveAndTakesOverADeadHolder() throws {
        let runs = root.appendingPathComponent("secretary/runs")
        let lock = try SecretaryRunLock.acquire(in: runs, runID: "a")
        XCTAssertThrowsError(try SecretaryRunLock.acquire(in: runs, runID: "b")) { error in
            XCTAssertEqual(error as? SecretaryError, .busy("a"))
        }
        lock.release()
        // A lock left by a process that no longer exists is stale.
        try Data("{\"pid\":999999,\"run\":\"dead\"}".utf8).write(to: runs.appendingPathComponent(".lock"))
        let taken = try SecretaryRunLock.acquire(in: runs, runID: "c")
        XCTAssertEqual(SecretaryRunLock.holder(of: taken.url).run, "c")
        taken.release()
    }

    func testRunVerifiesRepliesBackUpAndReleasesTheLock() async throws {
        let store = try await addComment("Какие именно?")
        let document = document
        let agent = FakeExecutor { request in
            let thread = try await store.load().threads[0]
            try await store.append(store.newReply(to: thread.id, text: "Альпы и Кавказ", author: "secretary", status: .applied))
            try "# Я\n\nЯ очень люблю горы (Альпы, Кавказ) и море.\n".write(to: document, atomically: true, encoding: .utf8)
            let context = try JSONDecoder().decode(SecretaryCompletion.ReviewContext.self, from: Data(request.mcpEnvironment[SecretaryCompletion.reviewEnvironmentKey]!.utf8))
            _ = try SecretaryCompletion.review(context, page: 0)
            let result = #"{"summary":"Уточнил горы","threads":[{"id":"\#(thread.id)","action":"applied"}],"checks":[{"name":"check","ok":true}]}"#
            try result.write(to: request.runDirectory.appendingPathComponent("result.json"), atomically: true, encoding: .utf8)
        }
        let dispatcher = SecretaryDispatcher(executor: agent, wimmCLI: URL(fileURLWithPath: "/usr/bin/true"),
                                             cliCheck: { _, _ in [] })
        let task = try await dispatcher.prepareComments(document: document)
        XCTAssertEqual(task.threads.count, 1)
        XCTAssertTrue(task.markdown().contains(task.threads[0].id))
        XCTAssertTrue(task.markdown().contains("/usr/bin/true comments list"))

        let record = try await dispatcher.run(task)
        XCTAssertEqual(record.outcome, .succeeded)
        XCTAssertEqual(record.findings, [])
        XCTAssertEqual(record.result?.summary, "Уточнил горы")
        XCTAssertEqual(record.costUSD, 0.12)
        let backup = try XCTUnwrap(record.backup)
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent(backup), encoding: .utf8).contains("люблю горы и море"))
        let directory = task.workspace.runDirectory(task.id)
        XCTAssertEqual(SecretaryDispatcher.readRecord(directory), record)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("task.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: task.workspace.runsDirectory.appendingPathComponent(".lock").path))
        let thread = try await store.load().threads[0]
        XCTAssertEqual(thread.status, .applied)
    }

    func testRunReportsWhatTheAgentLeftUndone() async throws {
        _ = try await addComment("Какие именно?")
        let dispatcher = SecretaryDispatcher(executor: FakeExecutor { _ in }, wimmCLI: URL(fileURLWithPath: "/usr/bin/true"),
                                             cliCheck: { _, _ in [] })
        let task = try await dispatcher.prepareComments(document: document)
        let record = try await dispatcher.run(task)
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(record.findings.count, 2)
        XCTAssertTrue(record.findings[0].contains("result.json"))
        XCTAssertTrue(record.findings[1].contains(task.threads[0].id))
    }

    func testSelfReportedCheckCannotReplaceFinalReviewEvidence() async throws {
        let document = document
        let agent = FakeExecutor { request in
            try "# Changed without review".write(to: document, atomically: true, encoding: .utf8)
            try #"{"summary":"Done","threads":[],"checks":[{"name":"перечитал изменённые абзацы","ok":true}]}"#
                .write(to: request.runDirectory.appendingPathComponent("result.json"), atomically: true, encoding: .utf8)
        }
        let dispatcher = SecretaryDispatcher(executor: agent, wimmCLI: URL(fileURLWithPath: "/usr/bin/true"), cliCheck: { _, _ in [] })
        let task = SecretaryTask(id: UUID().uuidString, kind: .comments, workspace: try XCTUnwrap(SecretaryWorkspace(document: document)),
                                 threads: [], wimmCLI: "/usr/bin/true", createdAt: Date())
        let record = try await dispatcher.run(task)
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(record.exitStatus, 0)
        XCTAssertTrue(record.findings.contains { $0.contains("Final document edits lack complete") })
    }

    func testFullPassWithoutQueueEvidenceDoesNotMarkOrAdvanceBoundary() async throws {
        let before = AgentMarkStore().pass()
        let agent = FakeExecutor { request in
            try #"{"summary":"Done","threads":[],"reviewed_sources":[],"source_decisions":[]}"#
                .write(to: request.runDirectory.appendingPathComponent("result.json"), atomically: true, encoding: .utf8)
        }
        let dispatcher = SecretaryDispatcher(executor: agent, wimmCLI: URL(fileURLWithPath: "/usr/bin/true"), cliCheck: { _, _ in [] })
        let task = SecretaryTask(id: UUID().uuidString, kind: .pass, workspace: try XCTUnwrap(SecretaryWorkspace(document: document)),
                                 threads: [], wimmCLI: "/usr/bin/true", createdAt: Date())
        let record = try await dispatcher.run(task)
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertNil(record.bookkeeping)
        XCTAssertNil(record.remainingNotes, "missing scan is unknown, not an empty queue")
        XCTAssertEqual(AgentMarkStore().pass(), before)
        XCTAssertTrue(record.findings.contains { $0.contains("queue coverage is unknown") })
    }

    func testPassSkipsTheAgentWhenNothingIsPending() async throws {
        let dispatcher = SecretaryDispatcher(executor: FakeExecutor { _ in }, wimmCLI: URL(fileURLWithPath: "/usr/bin/true"),
                                             cliCheck: { _, _ in [] })
        let idle = SecretaryPassScan(boundary: Date(), pending: 0, oldestPending: nil)
        do { _ = try await dispatcher.preparePass(document: document, scan: { idle }); XCTFail("should skip") }
        catch SecretaryError.nothingToDo {}
        _ = try await dispatcher.preparePass(document: document, force: true, scan: { idle })
        _ = try await dispatcher.preparePass(document: document, scan: { SecretaryPassScan(boundary: Date(), pending: 3, oldestPending: Date()) })
        _ = try await addComment("Какие именно?")
        _ = try await dispatcher.preparePass(document: document, scan: { idle })
    }

    func testPassRunsWithoutThreadsAndListsThemWhenOpen() async throws {
        let dispatcher = SecretaryDispatcher(executor: FakeExecutor { _ in }, wimmCLI: URL(fileURLWithPath: "/usr/bin/true"),
                                             cliCheck: { _, _ in [] })
        // Other app tests may already have advanced the isolated process's
        // pass boundary. Exercise the intended unknown-scan case explicitly.
        let empty = try await dispatcher.preparePass(document: document, scan: { nil })
        XCTAssertEqual(empty.kind, .pass)
        XCTAssertEqual(empty.threads, [])
        XCTAssertTrue(empty.markdown().contains("секретарский проход"))
        XCTAssertTrue(empty.markdown().contains("set_pass_boundary"))
        XCTAssertTrue(empty.markdown().contains("me_registry.py check"))
        XCTAssertTrue(empty.markdown().contains("\(empty.runDirectory)/"), "working files stay inside the run folder")

        _ = try await addComment("Какие именно?")
        let withThread = try await dispatcher.preparePass(document: document)
        XCTAssertEqual(withThread.threads.count, 1)
        XCTAssertTrue(withThread.markdown().contains(withThread.threads[0].id))
        XCTAssertEqual(dispatcher.timeout(for: .pass), 60 * 60)
        XCTAssertEqual(dispatcher.timeout(for: .comments), 20 * 60)

        let record = try await dispatcher.run(empty)
        XCTAssertEqual(record.kind, .pass)
        XCTAssertEqual(record.findings.count, 2, "missing result and unverified queue are reported")
        XCTAssertTrue(record.findings[0].contains("result.json"))
    }

    func testPassGetsReadToolsAndWimmOwnsBookkeeping() {
        XCTAssertEqual(SecretaryRunKind.comments.wimmTools, ["search_notes", "get_note", "recent_notes", "secretary_review_document"])
        XCTAssertFalse(SecretaryRunKind.pass.wimmTools.contains("mark_notes"))
        XCTAssertFalse(SecretaryRunKind.pass.wimmTools.contains("set_pass_boundary"))
        XCTAssertFalse(SecretaryRunKind.pass.wimmTools.contains("request_retranscription"))

        let claude = ClaudeCodeExecutor(binary: URL(fileURLWithPath: "/bin/claude"))
        let pass = SecretaryExecutionRequest(workspaceRoot: root, runDirectory: root, prompt: "P", kind: .pass,
                                             wimmCLI: "/x/WimmCLI", budgetUSD: 1, model: nil, timeout: 60)
        XCTAssertTrue(claude.arguments(for: pass, mcpConfig: URL(fileURLWithPath: "/m.json")).contains("mcp__wimm__changed_notes"))
        let codex = CodexExecutor(binary: URL(fileURLWithPath: "/bin/codex"))
        XCTAssertTrue(codex.arguments(for: pass, lastMessage: URL(fileURLWithPath: "/l.txt")).contains {
            $0.hasPrefix("mcp_servers.wimm.enabled_tools=") && $0.contains("\"changed_notes\"") && !$0.contains("mark_notes")
        })
    }

    func testNothingToDoWithoutOpenThreads() async throws {
        let dispatcher = SecretaryDispatcher(executor: FakeExecutor { _ in }, wimmCLI: URL(fileURLWithPath: "/usr/bin/true"),
                                             cliCheck: { _, _ in [] })
        do {
            _ = try await dispatcher.prepareComments(document: document)
            XCTFail("expected nothingToDo")
        } catch { XCTAssertEqual(error as? SecretaryError, .nothingToDo) }
    }

    func testVerificationFlagsARewrittenThreadsFileAndHonoursSkipped() throws {
        let workspace = try XCTUnwrap(SecretaryWorkspace(document: document))
        let root = DocumentCommentRecord(id: "c-1", kind: .comment, doc: "docs/me.md", author: "owner", at: "t", text: "?", quote: "горы")
        let thread = DocumentCommentThread(root: root, replies: [], status: .open)
        let task = SecretaryTask(id: "r", kind: .comments, workspace: workspace, threads: [thread], wimmCLI: "/w", createdAt: Date())
        let original = Data("{\"id\":\"c-1\"}\n".utf8)

        let rewritten = SecretaryVerification.findings(
            task: task, before: .init(threads: original, dirty: nil), after: .init(threads: Data("{}\n".utf8), dirty: nil),
            result: nil, resultError: nil)
        XCTAssertEqual(rewritten, ["secretary/threads.jsonl was rewritten, not appended to."])

        let skipped = SecretaryResult(threads: [.init(id: "c-1", action: "skipped", note: "нужно аудио")])
        XCTAssertEqual(SecretaryVerification.findings(
            task: task, before: .init(threads: original, dirty: nil), after: .init(threads: original, dirty: nil),
            result: skipped, resultError: nil), [])

        let old = ["docs/me.md": Date(timeIntervalSince1970: 1)]
        let new = ["docs/me.md": Date(timeIntervalSince1970: 2), "wiki/x.md": Date(), "secretary/runs/r/run.json": Date()]
        let outside = SecretaryVerification.findings(
            task: task, before: .init(threads: original, dirty: old), after: .init(threads: original, dirty: new),
            result: skipped, resultError: nil)
        XCTAssertEqual(outside, ["Changed outside docs/ and secretary/: wiki/x.md."])
    }

    func testClaudeStreamParsing() {
        var execution = SecretaryExecution(exitStatus: 0)
        var events: [SecretaryEvent] = []
        let lines = [
            #"{"type":"system","subtype":"init","model":"claude-opus-5-5","session_id":"s1"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Читаю треды"},{"type":"tool_use","name":"Bash","input":{"command":"/w comments list /d --pending"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","is_error":true,"content":"Permission denied"}]}}"#,
            "not json",
            #"{"type":"result","subtype":"success","is_error":false,"result":"Готово","total_cost_usd":0.42,"num_turns":7,"session_id":"s1","usage":{"input_tokens":10,"cache_read_input_tokens":90,"output_tokens":5},"permission_denials":[{"tool_name":"Write"}]}"#,
        ]
        for line in lines { ClaudeCodeExecutor.parse(line: line, into: &execution) { events.append($0) } }
        XCTAssertEqual(execution.model, "claude-opus-5-5")
        XCTAssertEqual(execution.finalText, "Готово")
        XCTAssertEqual(execution.costUSD, 0.42)
        XCTAssertEqual(execution.turns, 7)
        XCTAssertEqual(execution.tokensIn, 100)
        XCTAssertEqual(execution.tokensOut, 5)
        XCTAssertFalse(execution.isError)
        XCTAssertEqual(events.map(\.kind), [.info, .text, .tool, .error, .error])
        XCTAssertEqual(events[2].message, "Bash: /w comments list /d --pending")
        XCTAssertEqual(events[4].message, "denied: Write")

        var failed = SecretaryExecution(exitStatus: 0)
        ClaudeCodeExecutor.parse(line: #"{"type":"result","subtype":"error_max_budget_usd","is_error":true}"#, into: &failed) { _ in }
        XCTAssertTrue(failed.isError)
        XCTAssertEqual(failed.error, "error_max_budget_usd")
    }

    func testClaudeArgumentsKeepThePromptOutAndTheAllowListLast() {
        let executor = ClaudeCodeExecutor(binary: URL(fileURLWithPath: "/bin/claude"))
        let request = SecretaryExecutionRequest(workspaceRoot: root, runDirectory: root, prompt: "PROMPT", kind: .comments,
                                                wimmCLI: "/x/WimmCLI", budgetUSD: 1.5, model: "opus", timeout: 60)
        let arguments = executor.arguments(for: request, mcpConfig: URL(fileURLWithPath: "/m.json"))
        XCTAssertFalse(arguments.contains("PROMPT"))
        XCTAssertEqual(arguments.first, "-p")
        XCTAssertTrue(arguments.contains("dontAsk"))
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--max-budget-usd")! + 1], "1.50")
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--model")! + 1], "opus")
        let allowed = arguments.suffix(from: arguments.firstIndex(of: "--allowedTools")! + 1)
        XCTAssertFalse(allowed.contains { $0.hasPrefix("--") })
        XCTAssertTrue(allowed.contains("Bash"))
        XCTAssertTrue(arguments.contains("Bash(curl *)"))
        // A `cd` in Bash moves the relative Edit rules; the absolute ones must stay.
        XCTAssertTrue(allowed.contains("Edit(/\(root.path)/secretary/**)"))
        XCTAssertFalse(allowed.contains("mcp__wimm__mark_notes"))
        // Only the built-ins a run uses, so the other tools' schemas stay out of every turn.
        // No Skill: it lists every installed skill and plugin in every turn.
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--tools")! + 1], "Read,Edit,Write,Grep,Glob,Bash")
        XCTAssertFalse(allowed.contains("Skill"))
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--max-turns")! + 1], "100")
        XCTAssertFalse(arguments.contains("--effort"))
        let config = String(decoding: ClaudeCodeExecutor.mcpConfig(wimmCLI: "/x/WimmCLI"), as: UTF8.self)
        XCTAssertTrue(config.contains("\"command\" : \"/x/WimmCLI\""))
        XCTAssertFalse(config.contains("env"))
        let capped = String(decoding: ClaudeCodeExecutor.mcpConfig(wimmCLI: "/x/WimmCLI", environment: SecretaryRunKind.pass.mcpEnvironment), as: UTF8.self)
        XCTAssertTrue(capped.contains("\"WIMM_MCP_PAGE_LIMIT\" : \"20\""))

        let tuned = SecretaryExecutionRequest(workspaceRoot: root, runDirectory: root, prompt: "P", kind: .pass, wimmCLI: "/x/WimmCLI",
                                              budgetUSD: 1, model: nil, timeout: 60, maxTurns: 30, effort: "medium")
        let tunedArguments = executor.arguments(for: tuned, mcpConfig: URL(fileURLWithPath: "/m.json"))
        XCTAssertEqual(tunedArguments[tunedArguments.firstIndex(of: "--max-turns")! + 1], "30")
        XCTAssertEqual(tunedArguments[tunedArguments.firstIndex(of: "--effort")! + 1], "medium")
        let codex = CodexExecutor(binary: URL(fileURLWithPath: "/bin/codex")).arguments(for: tuned, lastMessage: URL(fileURLWithPath: "/l.txt"))
        XCTAssertTrue(codex.contains { $0.contains("mcp_servers.wimm.env={") && $0.contains("WIMM_MCP_PAGE_LIMIT=\"20\"") && $0.contains("WIMM_SECRETARY_READ_LOG=") })
        XCTAssertTrue(codex.contains("model_reasoning_effort=\"medium\""))
    }

    func testCLICheckNamesWhatAnOldCopyLacks() {
        func tool(_ name: String, _ properties: [String], limitMaximum: Int? = nil) -> [String: Any] {
            var props: [String: Any] = Dictionary(uniqueKeysWithValues: properties.map { ($0, ["type": "string"] as [String: Any]) })
            if properties.contains("limit") { props["limit"] = limitMaximum.map { ["type": "integer", "maximum": $0] } ?? ["type": "integer"] }
            return ["name": name, "inputSchema": ["type": "object", "properties": props]]
        }
        let read = [tool("search_notes", ["query", "limit"], limitMaximum: 20), tool("get_note", ["id"]),
                    tool("recent_notes", ["since", "limit"], limitMaximum: 20), tool("secretary_review_document", ["page"])]
        XCTAssertEqual(SecretaryCLICheck.missing(tools: read, kind: .comments, pageLimit: 20), ["get_note.full", "get_note.read_receipts", "get_note.text_coverage", "get_note.image_evidence", "get_note.document_layout"])
        // The copy of 25.10: changed_notes without marked_changes/order, no page cap, no marked_notes.
        let old = read + [tool("changed_notes", ["since", "cursor", "skip_unchanged_marked", "limit"]),
                          tool("mark_notes", ["marks"]), tool("set_pass_boundary", ["as_of"])]
        XCTAssertEqual(SecretaryCLICheck.missing(tools: old, kind: .pass, pageLimit: 20),
                       ["changed_notes.marked_changes", "changed_notes.order", "changed_notes.limit ≤ 20", "get_note.full", "marked_notes", "get_note.read_receipts", "get_note.text_coverage", "changed_notes.queue_receipts", "get_note.image_evidence", "get_note.document_layout"])
        // The real server advertises everything a pass needs, under the run's cap.
        XCTAssertEqual(SecretaryCLICheck.missing(tools: MCPRecallServer.tools(pageLimit: 20), kind: .pass, pageLimit: 20), [])
        XCTAssertEqual(SecretaryCLICheck.missing(tools: MCPRecallServer.tools(pageLimit: nil), kind: .pass, pageLimit: 20).count, 4)
    }

    func testCLICheckBoundsUnresponsiveCommands() async throws {
        let cli = root.appendingPathComponent("stuck-cli")
        // No child process holding stdout open; the CLI itself ignores SIGTERM.
        try "#!/bin/sh\ntrap '' TERM\nwhile :; do :; done\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let start = Date()
        let missing = await SecretaryCLICheck.missing(cli: cli, kind: .comments, environment: [:], timeout: 0.1)
        XCTAssertEqual(missing.count, 3)
        XCTAssertEqual(missing.first, "comments reply")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testStaleCLIRefusesBeforeTheAgentStarts() async throws {
        _ = try await addComment("Какие именно?")
        let started = LockedFlag()
        let dispatcher = SecretaryDispatcher(executor: FakeExecutor { _ in started.set() }, wimmCLI: URL(fileURLWithPath: "/usr/bin/true"),
                                             cliCheck: { _, _ in ["changed_notes.marked_changes"] })
        let task = try await dispatcher.prepareComments(document: document)
        do {
            _ = try await dispatcher.run(task)
            XCTFail("expected wimmCLIStale")
        } catch {
            XCTAssertEqual(error as? SecretaryError, .wimmCLIStale("/usr/bin/true", ["changed_notes.marked_changes"]))
        }
        XCTAssertFalse(started.value)
        XCTAssertFalse(FileManager.default.fileExists(atPath: task.workspace.runsDirectory.appendingPathComponent(".lock").path))
    }

    func testTaskNamesOnlyTheProtocolPartsItNeeds() async throws {
        _ = try await addComment("Какие именно?")
        let dispatcher = SecretaryDispatcher(executor: FakeExecutor { _ in }, wimmCLI: URL(fileURLWithPath: "/usr/bin/true"),
                                             cliCheck: { _, _ in [] })
        let whole = try await dispatcher.prepareComments(document: document).markdown()
        XCTAssertFalse(whole.contains("secretary/protocol/"), "a workspace with one protocol file gets no part list")
        XCTAssertTrue(whole.contains("`.claude/skills/secretary-pass/SKILL.md`"), "the skill is read as a file: no Skill tool")

        let parts = root.appendingPathComponent("secretary/protocol")
        try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)
        try "# x\n".write(to: parts.appendingPathComponent("comments.md"), atomically: true, encoding: .utf8)
        let comments = try await dispatcher.prepareComments(document: document).markdown()
        XCTAssertTrue(comments.contains("`secretary/protocol/comments.md` и `secretary/protocol/document.md`"))
        XCTAssertFalse(comments.contains("registry.md"))
        let pass = try await dispatcher.preparePass(document: document, force: true).markdown()
        XCTAssertTrue(pass.contains("`registry.md`"))
        XCTAssertTrue(pass.contains("limit: 20"))
    }

    func testManagedEnvironmentIsScopedToTheManagedPass() throws {
        let folder = root.appendingPathComponent("secretary/protocol")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "# rules".write(to: folder.appendingPathComponent("managed.md"), atomically: true, encoding: .utf8)
        let pass = SecretaryExecutionRequest(workspaceRoot: root, runDirectory: root, prompt: "P", kind: .pass,
                                            wimmCLI: "/cli", budgetUSD: 1, model: nil, timeout: 60)
        XCTAssertEqual(SecretaryProcessRunner.managedEnvironment([:], request: pass)[SecretaryProcessRunner.managedEnvironmentKey], "1")
        let comments = SecretaryExecutionRequest(workspaceRoot: root, runDirectory: root, prompt: "P", kind: .comments,
                                                wimmCLI: "/cli", budgetUSD: 1, model: nil, timeout: 60)
        XCTAssertNil(SecretaryProcessRunner.managedEnvironment([:], request: comments)[SecretaryProcessRunner.managedEnvironmentKey])
    }

    func testChildDropsTheHostSessionOnlyWhenNested() {
        let nested = ClaudeCodeExecutor.environment(["CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "s", "ANTHROPIC_BASE_URL": "http://proxy",
                                                     "HOME": "/h", "PATH": "/usr/bin"])
        XCTAssertNil(nested["CLAUDECODE"]); XCTAssertNil(nested["CLAUDE_CODE_SESSION_ID"]); XCTAssertNil(nested["ANTHROPIC_BASE_URL"])
        XCTAssertEqual(nested["HOME"], "/h")
        // Set after the host's CLAUDE* variables are dropped, so they survive.
        XCTAssertEqual(nested["FORCE_PROMPT_CACHING_5M"], "1")
        XCTAssertEqual(nested["CLAUDE_CODE_DISABLE_AUTO_MEMORY"], "1")
        XCTAssertTrue(nested["PATH"]!.hasPrefix("/usr/bin:/opt/homebrew/bin"))
        // A user's own proxy setting outside a host session stays.
        XCTAssertEqual(ClaudeCodeExecutor.environment(["ANTHROPIC_BASE_URL": "http://mine"])["ANTHROPIC_BASE_URL"], "http://mine")
    }

    func testCodexEventParsing() {
        var execution = SecretaryExecution(exitStatus: 0)
        var events: [SecretaryEvent] = []
        let lines = [
            #"{"type":"thread.started","thread_id":"t1"}"#,
            #"{"type":"item.completed","item":{"id":"i0","type":"agent_message","text":"Читаю треды"}}"#,
            #"{"type":"item.started","item":{"id":"i1","type":"command_execution","command":"/bin/zsh -lc 'cat a.txt'","status":"in_progress"}}"#,
            #"{"type":"item.completed","item":{"id":"i1","type":"command_execution","command":"/bin/zsh -lc 'cat a.txt'","aggregated_output":"no such file","exit_code":1,"status":"failed"}}"#,
            #"{"type":"item.started","item":{"id":"i2","type":"mcp_tool_call","server":"wimm","tool":"recent_notes","status":"in_progress"}}"#,
            #"{"type":"item.completed","item":{"id":"i2","type":"mcp_tool_call","server":"wimm","tool":"recent_notes","error":{"message":"requires approval"},"status":"failed"}}"#,
            #"{"type":"error","message":"Reconnecting 1/5"}"#,
            "not json",
            #"{"type":"item.completed","item":{"id":"i3","type":"agent_message","text":"Готово"}}"#,
            #"{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":5,"reasoning_output_tokens":3}}"#,
        ]
        for line in lines { CodexExecutor.parse(line: line, into: &execution) { events.append($0) } }
        XCTAssertEqual(execution.sessionID, "t1")
        XCTAssertEqual(execution.finalText, "Готово")
        XCTAssertEqual(execution.tokensIn, 100)
        XCTAssertEqual(execution.tokensOut, 8)
        XCTAssertEqual(execution.turns, 1)
        XCTAssertFalse(execution.isError, "a reconnect notice is not a failure")
        XCTAssertEqual(events.map(\.kind), [.text, .tool, .error, .tool, .error, .error, .text])
        XCTAssertEqual(events[1].message, "Bash: cat a.txt")
        XCTAssertEqual(events[2].message, "exit 1: cat a.txt — no such file")
        XCTAssertEqual(events[3].message, "wimm: recent_notes")

        var failed = SecretaryExecution(exitStatus: 0)
        CodexExecutor.parse(line: #"{"type":"turn.failed","error":{"message":"usage limit"}}"#, into: &failed) { _ in }
        XCTAssertTrue(failed.isError)
        XCTAssertEqual(failed.error, "usage limit")
    }

    func testCodexArgumentsSandboxTheWorkspaceAndLimitTheMCPServer() {
        let executor = CodexExecutor(binary: URL(fileURLWithPath: "/bin/codex"))
        let request = SecretaryExecutionRequest(workspaceRoot: root, runDirectory: root, prompt: "PROMPT", kind: .comments,
                                                wimmCLI: "/x y/WimmCLI", budgetUSD: 1, model: "gpt-x", timeout: 60)
        let arguments = executor.arguments(for: request, lastMessage: URL(fileURLWithPath: "/last.txt"))
        XCTAssertEqual(Array(arguments.prefix(1)), ["exec"])
        XCTAssertEqual(arguments.last, "-", "the prompt goes through stdin")
        XCTAssertFalse(arguments.contains("PROMPT"))
        XCTAssertTrue(arguments.contains("--ignore-user-config"))
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-s")! + 1], "workspace-write")
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-C")! + 1], root.path)
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-m")! + 1], "gpt-x")
        XCTAssertFalse(arguments.contains("--dangerously-bypass-approvals-and-sandbox"))
        XCTAssertTrue(arguments.contains("mcp_servers.wimm.command=\"/x y/WimmCLI\""))
        XCTAssertTrue(arguments.contains("mcp_servers.wimm.enabled_tools=[\"search_notes\",\"get_note\",\"recent_notes\",\"secretary_review_document\"]"))
        XCTAssertFalse(arguments.joined().contains("mark_notes"))
        XCTAssertEqual(CodexExecutor.toml("a\"b\\c"), "\"a\\\"b\\\\c\"")
        XCTAssertEqual(CodexExecutor.shellCommand("/bin/zsh -lc 'git status'"), "git status")
        XCTAssertEqual(CodexExecutor.shellCommand("ls"), "ls")
    }

    func testCodexIsFoundInTheChatGPTAppAndNamedByTheAgentEnum() throws {
        let app = root.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex-cli/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let binary = app.appendingPathComponent("codex")
        try Data().write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let defaults = UserDefaults(suiteName: "secretary-test-\(UUID().uuidString)")!
        XCTAssertEqual(CodexExecutor.locate(environment: ["PATH": app.path], defaults: defaults, home: root)?.path, binary.path)
        XCTAssertEqual(CodexExecutor.locate(environment: ["WIMM_CODEX_PATH": binary.path], defaults: defaults, home: root)?.path, binary.path)
        XCTAssertEqual(SecretaryAgent.allCases.map(\.rawValue), ["codex", "claude", "gemini"])
        XCTAssertEqual(SecretaryAgent.codex.displayName, "ChatGPT (Codex)")
        XCTAssertEqual(try SecretaryAgent.codex.executor(environment: ["WIMM_CODEX_PATH": binary.path]).name, "codex")
        XCTAssertEqual(SecretaryAgent.gemini.displayName, "Gemini")
        XCTAssertEqual(try SecretaryAgent.gemini.executor().name, "gemini")
        XCTAssertEqual(SecretaryAgent.gemini.defaultModel, "gemini-flash-latest")
        XCTAssertTrue(SecretaryAgent.gemini.modelOptions.contains(where: { $0.id == "gemini-flash-latest" }))
    }

    func testWimmCLINeverResolvesToTheCopyInsideTheApp() throws {
        let dir = root.appendingPathComponent("Wimm.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let inside = dir.appendingPathComponent("WimmCLI")
        try Data().write(to: inside)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: inside.path)
        XCTAssertNil(SecretaryDispatcher.locateWimmCLI(environment: [:], appBundle: nil, runningExecutable: inside, home: root))

        let sibling = root.appendingPathComponent("WimmCLI.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data().write(to: sibling.appendingPathComponent("WimmCLI"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sibling.appendingPathComponent("WimmCLI").path)
        XCTAssertEqual(SecretaryDispatcher.locateWimmCLI(environment: [:], appBundle: root.appendingPathComponent("Wimm.app"),
                                                         runningExecutable: inside, home: root)?.path,
                       sibling.appendingPathComponent("WimmCLI").standardizedFileURL.path)
    }
}

private struct FakeExecutor: SecretaryExecutor {
    let name = "fake"
    let work: @Sendable (SecretaryExecutionRequest) async throws -> Void

    init(_ work: @escaping @Sendable (SecretaryExecutionRequest) async throws -> Void) { self.work = work }

    func run(_ request: SecretaryExecutionRequest,
             onEvent: @escaping @Sendable (SecretaryEvent) -> Void) async throws -> SecretaryExecution {
        try await work(request)
        return SecretaryExecution(exitStatus: 0, finalText: "ok", costUSD: 0.12)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
