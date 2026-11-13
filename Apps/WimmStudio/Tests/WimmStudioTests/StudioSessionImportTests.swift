import Foundation
import SQLite3
import XCTest
@testable import WimmStudio

final class StudioSessionImportTests: XCTestCase {
    func testImportsIdleSessionsOnceAndRecognizesPreviousCLIImports() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: home) }

        let codex = home.appendingPathComponent(".codex/sessions")
        let claude = home.appendingPathComponent(".claude/projects/example")
        let recordings = home.appendingPathComponent("Recordings")
        for directory in [codex, claude, recordings] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let legacyID = UUID()
        let newID = UUID()
        let claudeID = UUID()
        let oldLog = codex.appendingPathComponent("rollout-\(legacyID).jsonl")
        let newLog = codex.appendingPathComponent("rollout-\(newID).jsonl")
        let claudeLog = claude.appendingPathComponent("\(claudeID).jsonl")
        let now = Date()
        let codexDialogue = """
        {"type":"session_meta","payload":{"timestamp":"2026-11-05T10:00:00Z","source":"vscode"}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Codex prompt"}]}}
        {"type":"response_item","payload":{"type":"function_call_output","output":"Internal tool result"}}
        """
        for url in [oldLog, newLog] {
            try Data(codexDialogue.utf8).write(to: url)
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-7200)], ofItemAtPath: url.path)
        }
        try Data("""
        {"type":"user","timestamp":"2026-11-05T10:00:00.000Z","message":{"role":"user","content":"Claude prompt"}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Claude reply"}]}}
        """.utf8).write(to: claudeLog)
        try fm.setAttributes([.modificationDate: now], ofItemAtPath: claudeLog.path)
        let secretaryCodex = codex.appendingPathComponent("rollout-\(UUID()).jsonl")
        let secretaryClaude = claude.appendingPathComponent("\(UUID()).jsonl")
        let secretaryPath = "/work/_ME/secretary/runs/example/packet-1"
        let codexRun = codexDialogue.replacingOccurrences(of: "\"source\":\"vscode\"", with: "\"source\":\"vscode\",\"cwd\":\"\(secretaryPath)\"")
        let claudeRun = """
        {"type":"user","cwd":"\(secretaryPath)","timestamp":"2026-11-05T10:00:00Z","message":{"role":"user","content":"Secretary packet"}}
        """
        for (url, body) in [(secretaryCodex, codexRun), (secretaryClaude, claudeRun)] {
            try Data(body.utf8).write(to: url)
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-7200)], ofItemAtPath: url.path)
        }
        try Data("# Codex — Previous import\n\nСессия Codex \(legacyID)\n".utf8)
            .write(to: recordings.appendingPathComponent("previous.txt"))

        let importer = StudioSessionImport(home: home, recordings: recordings)
        let firstPass = await importer.run(now: now)
        XCTAssertEqual(firstPass.count, 1)
        let firstBody = try String(contentsOf: XCTUnwrap(firstPass.first), encoding: .utf8)
        XCTAssertTrue(firstBody.contains("Codex prompt"))
        XCTAssertFalse(firstBody.contains("Internal tool result"))

        let later = now.addingTimeInterval(7200)
        let secondPass = await importer.run(now: later)
        XCTAssertEqual(secondPass.count, 1)
        let secondBody = try String(contentsOf: XCTUnwrap(secondPass.first), encoding: .utf8)
        XCTAssertTrue(secondBody.contains("Claude reply"))

        let freshImporter = StudioSessionImport(home: home, recordings: recordings)
        let afterRestart = await freshImporter.run(now: later)
        XCTAssertTrue(afterRestart.isEmpty)

        // The Claude chat goes on: the same note gets the new text once the chat is idle again.
        let note = try XCTUnwrap(secondPass.first)
        let handle = try FileHandle(forWritingTo: claudeLog)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"Claude follow-up\"}}\n".utf8))
        try handle.close()
        let resumed = later.addingTimeInterval(7200)
        try fm.setAttributes([.modificationDate: later], ofItemAtPath: note.path)
        try fm.setAttributes([.modificationDate: resumed], ofItemAtPath: claudeLog.path)
        let whileActive = await freshImporter.run(now: resumed.addingTimeInterval(60))
        XCTAssertTrue(whileActive.isEmpty)
        let afterIdle = await freshImporter.run(now: resumed.addingTimeInterval(7200))
        XCTAssertEqual(afterIdle.map(\.lastPathComponent), [note.lastPathComponent])
        let updated = try String(contentsOf: note, encoding: .utf8)
        XCTAssertTrue(updated.contains("Claude reply"))
        XCTAssertTrue(updated.contains("Claude follow-up"))
        let unchanged = await freshImporter.run(now: resumed.addingTimeInterval(9000))
        XCTAssertTrue(unchanged.isEmpty)

        // A log that lost text never shrinks the note.
        try Data("{\"type\":\"user\",\"timestamp\":\"2026-11-05T10:00:00.000Z\",\"message\":{\"role\":\"user\",\"content\":\"Cut\"}}".utf8).write(to: claudeLog)
        let cutAt = Date().addingTimeInterval(3600)
        try fm.setAttributes([.modificationDate: cutAt], ofItemAtPath: claudeLog.path)
        let afterCut = await freshImporter.run(now: cutAt.addingTimeInterval(7200))
        XCTAssertTrue(afterCut.isEmpty)
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), updated)
    }

    func testImportsCursorAndAntigravityChats() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: home) }
        let recordings = home.appendingPathComponent("Recordings")
        let cursorID = UUID()
        let cursorDir = home.appendingPathComponent(".cursor/projects/p/agent-transcripts/\(cursorID)")
        let conversations = home.appendingPathComponent(".gemini/antigravity/conversations")
        for d in [cursorDir, conversations, recordings] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }

        let cursorLog = cursorDir.appendingPathComponent("\(cursorID).jsonl")
        try Data("""
        {"role":"user","message":{"content":[{"type":"text","text":"<timestamp>Friday, Nov 6, 2026, 1:02 AM (UTC+1)</timestamp>\\n<user_query>\\nCursor question\\n</user_query>"}]}}
        {"role":"assistant","message":{"content":[{"type":"text","text":"Cursor answer"},{"type":"tool_use","name":"Shell","input":{"command":"secret tool call"}}]}}
        """.utf8).write(to: cursorLog)

        func field(_ number: Int, bytes: [UInt8]) -> [UInt8] {
            let key = number << 3 | 2   // keys of fields >= 16 need two varint bytes
            let head: [UInt8] = key < 128 ? [UInt8(key)] : [UInt8(key & 0x7F | 0x80), UInt8(key >> 7)]
            return head + [UInt8(bytes.count)] + bytes
        }
        let user = field(19, bytes: field(2, bytes: Array("Anti question".utf8)))
        let time = field(5, bytes: field(1, bytes: [0x08, 0x80, 0xE2, 0xCF, 0xD0, 0x06]))
        let model = field(20, bytes: field(1, bytes: Array("Anti answer".utf8)))
        let agID = UUID()
        let dbURL = conversations.appendingPathComponent("\(agID).db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        sqlite3_exec(db, "CREATE TABLE steps (idx integer PRIMARY KEY, step_type integer, step_payload blob)", nil, nil, nil)
        for (idx, type, payload) in [(0, 14, time + user), (1, 15, time + model)] {
            var st: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO steps VALUES (?,?,?)", -1, &st, nil)
            sqlite3_bind_int(st, 1, Int32(idx)); sqlite3_bind_int(st, 2, Int32(type))
            payload.withUnsafeBytes { _ = sqlite3_bind_blob(st, 3, $0.baseAddress, Int32(payload.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            sqlite3_step(st); sqlite3_finalize(st)
        }
        sqlite3_close(db)

        let old = Date().addingTimeInterval(-7200)
        for url in [cursorLog, dbURL] { try fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path) }
        let files = await StudioSessionImport(home: home, recordings: recordings).run()
        XCTAssertEqual(files.count, 2)
        let bodies = try files.map { try String(contentsOf: $0, encoding: .utf8) }
        let cursor = try XCTUnwrap(bodies.first { $0.contains("Cursor question") })
        XCTAssertTrue(cursor.contains("Cursor answer"))
        XCTAssertFalse(cursor.contains("secret tool call"))
        XCTAssertFalse(cursor.contains("user_query"))
        let anti = try XCTUnwrap(bodies.first { $0.contains("Anti question") })
        XCTAssertTrue(anti.contains("Anti answer"))
    }
}
