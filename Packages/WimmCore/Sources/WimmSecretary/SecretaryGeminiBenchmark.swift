import Foundation
import WimmDomain
import WimmInfrastructure

/// Offline comparison of captured text. Fixtures are derived text files in a new directory;
/// their receipts never enter AgentState. This API has no path to a live apply.
public enum SecretaryGeminiBenchmark {
    public static func run(promptFile: URL, inputFile: URL, documentSnapshot: URL, registry: URL,
                           output: URL, model: String, responseFile: URL? = nil, send: Bool = false) async throws -> Data {
        guard !PrivateMode.isEnabled else { throw SecretaryError.privateMode }
        guard !(send && responseFile != nil), !FileManager.default.fileExists(atPath: output.path) else {
            throw SecretaryPacket.Failure("Choose send or saved response, and a new output directory.")
        }
        let fm = FileManager.default
        let data = try Data(contentsOf: inputFile)
        guard var input = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sources = input["sources"] as? [[String: Any]], !sources.isEmpty,
              let supplied = input["document_blocks"] as? [[String: Any]] else { throw SecretaryPacket.Failure("Invalid captured packet.") }
        let documentData = try Data(contentsOf: documentSnapshot)
        let blocks = SecretaryPacket.blocks(String(decoding: documentData, as: UTF8.self))
        let byBlock = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0.text) })
        guard supplied.allSatisfy({ ($0["id"] as? String).flatMap { byBlock[$0] } == $0["text"] as? String }) else {
            throw SecretaryPacket.Failure("Document snapshot does not match captured blocks.")
        }
        try fm.createDirectory(at: output, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let root = output.appendingPathComponent("fixture")
        for p in ["docs", "recordings", "secretary/protocol"] { try fm.createDirectory(at: root.appendingPathComponent(p), withIntermediateDirectories: true) }
        let document = root.appendingPathComponent("docs/me.md")
        try documentData.write(to: document, options: .atomic)
        try "Offline captured-text validation.".write(to: root.appendingPathComponent("secretary/protocol/packet.md"), atomically: true, encoding: .utf8)
        try "Offline captured-text validation.".write(to: root.appendingPathComponent(SecretaryPacket.editsPolicyPath), atomically: true, encoding: .utf8)
        let queue = Data((input["review_queue"] as? String ?? "").utf8)
        try queue.write(to: root.appendingPathComponent("secretary/review_queue.md"), options: .atomic)
        var reg = try JSONSerialization.jsonObject(with: Data(contentsOf: registry)) as! [String: Any]
        var rows = reg["sources"] as! [[String: Any]]
        var notes: [RecallNote] = [], ids: [String] = []
        for source in sources {
            guard let id = source["source"] as? String, id.range(of: #"^S[0-9]+$"#, options: .regularExpression) != nil,
                  let text = source["full_text"] as? String, let index = rows.firstIndex(where: { $0["source_id"] as? String == id }) else {
                throw SecretaryPacket.Failure("Missing captured source or registry ID.")
            }
            let file = root.appendingPathComponent("recordings/\(id).txt")
            try text.write(to: file, atomically: true, encoding: .utf8)
            try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: file)) { $0["recordingId"] = "fixture-\(id)"; return true }
            rows[index]["path"] = "../recordings/\(id).meta.json"; rows[index]["note_file"] = "\(id).txt"
            rows[index].removeValue(forKey: "removed_from_wimm"); rows[index].removeValue(forKey: "wimm_unindexed"); rows[index].removeValue(forKey: "user_exclusion")
            notes.append(RecallNote(id: "fixture-\(id)", date: Date(), kind: "text", title: nil, summary: nil, text: text, filePath: file.path, updated: Date()))
            ids.append(id)
        }
        reg["sources"] = rows
        let registryData = try JSONSerialization.data(withJSONObject: reg)
        try registryData.write(to: document.deletingPathExtension().appendingPathExtension("sources.json"), options: .atomic)
        let marks = AgentMarkStore(directory: output.appendingPathComponent("unused-marks"))
        let task = SecretaryTask(id: "captured-benchmark", kind: .pass, workspace: SecretaryWorkspace(document: document)!, threads: [], wimmCLI: "", createdAt: Date(), packetMode: true)
        let prepared = try SecretaryPacket.prepare(task: task, library: RecallLibrary(notes), marks: marks,
            sourceByteLimit: 10_000_000, sampleSourceIDs: Set(ids))
        let receiptByID = Dictionary(uniqueKeysWithValues: zip(prepared.selected, prepared.receipts))
        input["response_format"] = 2
        let packet = SecretaryPacket(task: task, documentData: documentData, registryData: registryData, queueData: queue,
            blocks: blocks, selected: ids, receipts: try ids.map { guard let r = receiptByID[$0] else { throw SecretaryPacket.Failure("Incomplete fixture read.") }; return r },
            projectedSourceIDs: [], newSources: [], fullSourcesByID: Dictionary(uniqueKeysWithValues: sources.map { ($0["source"] as! String, $0["full_text"] as! String) }),
            payload: input, system: "")
        let prompt = try String(contentsOf: promptFile, encoding: .utf8)
        var report: [String: Any] = ["committed": false, "sent": send, "model": model,
            "source_count": ids.count, "prompt_bytes": prompt.utf8.count, "fixture": root.path]
        let response: String
        if let responseFile { response = try String(contentsOf: responseFile, encoding: .utf8) }
        else if send {
            let directory = output.appendingPathComponent("attempt")
            try fm.createDirectory(at: directory, withIntermediateDirectories: false)
            var request = SecretaryExecutionRequest(workspaceRoot: root, runDirectory: directory, prompt: prompt,
                kind: .pass, wimmCLI: "", budgetUSD: 0, model: model, timeout: 600)
            request.systemPrompt = ""
            let started = Date()
            let execution: SecretaryExecution
            do { execution = try await GeminiPacketExecutor(temperature: 0, maxOutputTokens: nil).run(request) { _ in } }
            catch {
                try JSONEncoder().encode(SecretaryExecution(exitStatus: -1, isError: true, model: model, error: error.localizedDescription)).write(to: directory.appendingPathComponent("execution.json"), options: .atomic)
                throw error
            }
            report["seconds"] = Date().timeIntervalSince(started)
            try JSONEncoder().encode(execution).write(to: directory.appendingPathComponent("execution.json"), options: .atomic)
            guard !execution.isError, execution.exitStatus == 0, let text = execution.finalText else { throw SecretaryPacket.Failure("Benchmark model failed; see execution.json.") }
            response = text
            try Data(text.utf8).write(to: output.appendingPathComponent("response.json"), options: .atomic)
        } else { return try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) }
        let reply: SecretaryPacket.EditsReply
        do { reply = try SecretaryPacket.decodeEdits(response) }
        catch {
            report["validation"] = ["accepted": false, "rejection": error.localizedDescription,
                "edits": [], "rejectedEdits": [], "sources": ids.map { ["id": $0, "outcome": "rejected"] },
                "native_decoder_rejection": true] as [String: Any]
            let encoded = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try encoded.write(to: output.appendingPathComponent("report.json"), options: .atomic)
            return encoded
        }
        let validation = try packet.resolveEdits(reply, prompt: String(decoding: JSONSerialization.data(withJSONObject: input), as: UTF8.self), marks: marks, checkLazyReply: false)
        report["validation"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(validation.report))
        let encoded = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try encoded.write(to: output.appendingPathComponent("report.json"), options: .atomic)
        return encoded
    }
}
