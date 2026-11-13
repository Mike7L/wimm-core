import CryptoKit
import Foundation
import WimmDomain
import WimmInfrastructure

/// Wimm's own audit of bookkeeping; independent of result.checks from the model.
public struct SecretaryBookkeepingReport: Codable, Sendable, Equatable {
    public var requested = 0
    public var stored = 0
    public var storedSources: [String]? = nil
    public var registryUpdated: Int?
    public var referencesAdded: Int?
    public var registryBackup: String?
    public var removedSources: [String]?
    public var remappedSources: [String]?
    public var findings: [String] = []
}

/// The registry remains authoritative for semantic status. Only explicitly reviewed
/// sources with a matching get_note receipt are copied into Wimm. No backlog re-marking.
enum SecretaryBookkeeping {
    /// Sources whose references an applied pass removed from the document go back into the
    /// queue: their mark is cleared and the pass boundary moves back to them if it had passed
    /// them, so the next pass reads them again and restores what was lost (2026-10-31: one
    /// rewrite dropped ten facts that the previous pass had added).
    @discardableResult
    static func requeue(_ references: [String], workspace: SecretaryWorkspace,
                        store: AgentMarkStore = AgentMarkStore()) -> [String] {
        let ids = Set(references.filter { $0.hasPrefix("S") })
        guard !ids.isEmpty,
              let data = try? Data(contentsOf: workspace.document.deletingPathExtension().appendingPathExtension("sources.json")),
              let registry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = registry["sources"] as? [[String: Any]] else { return [] }
        let recordings = workspace.root.appendingPathComponent("recordings")
        var files: [String] = [], earliest = Date.distantFuture
        for row in rows {
            guard let id = row["source_id"] as? String, ids.contains(id), let file = row["note_file"] as? String else { continue }
            files.append(file)
            let media = recordings.appendingPathComponent(file)
            for url in [media, FileStore.metadataURL(forRecordingURL: media)] {
                if let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date {
                    earliest = min(earliest, date)
                }
            }
        }
        guard !files.isEmpty else { return [] }
        do {
            try store.update(Dictionary(files.map { ($0, AgentMarkStore.Mark?.none) }, uniquingKeysWith: { first, _ in first }))
            if let pass = store.pass(), earliest < pass.asOf {
                try store.setPass(.init(asOf: earliest.addingTimeInterval(-1), cursor: nil,
                                        comment: "moved back to requeue sources a pass removed from the document", setAt: Date()))
            }
        } catch { return [] }
        return files.sorted()
    }

    static func finish(task: SecretaryTask, result: SecretaryResult,
                       store: AgentMarkStore = AgentMarkStore(),
                       recordings: (() async -> [URL])? = nil, applyChanges: Bool = true,
                       deferredPendingSources: Set<String> = [], reconcileMediaAliases: Bool = false, timing: SecretaryFileTiming? = nil) async -> SecretaryBookkeepingReport {
        var report = SecretaryBookkeepingReport()
        guard result.reviewedSources != nil || result.sourceDecisions != nil else {
            report.findings = ["result.json must contain reviewed_sources or source_decisions (an empty array is allowed)."]
            return report
        }
        let decisions = result.sourceDecisions ?? []
        let declared = result.reviewedSources ?? []
        guard Set(declared).count == declared.count, Set(decisions.map(\.source)).count == decisions.count else {
            report.findings = ["Duplicate reviewed_sources/source_decisions in result.json."]
            return report
        }
        let decisionByID = Dictionary(uniqueKeysWithValues: decisions.map { ($0.source, $0) })
        var seen = Set<String>()
        let reviewed = (declared + decisions.map(\.source)).filter { seen.insert($0).inserted }
        report.requested = reviewed.count
        let registry = task.workspace.document.deletingPathExtension().appendingPathExtension("sources.json")
        do {
            let registryData = try Data(contentsOf: registry)
            guard let data = try JSONSerialization.jsonObject(with: registryData) as? [String: Any],
                  let sources = data["sources"] as? [[String: Any]] else {
                throw Failure("Registry has no sources array: \(registry.lastPathComponent)")
            }
            var bySource: [String: [String: Any]] = [:]
            var counts: [String: Int] = [:]
            for source in sources {
                guard let id = source["source_id"] as? String, id.range(of: #"^S[0-9]+$"#, options: .regularExpression) != nil,
                      bySource[id] == nil, let status = source["status"] as? String,
                      ["applied", "duplicate", "pending", "noise", "failed"].contains(status),
                      source["path"] is String else { throw Failure("Invalid or duplicate registry source.") }
                bySource[id] = source
                counts[status, default: 0] += 1
            }
            guard data["source_count"] as? Int == sources.count, data["counts"] as? [String: Int] == counts else {
                throw Failure("Registry source_count/counts disagree with sources.")
            }
            guard Set(reviewed).count == reviewed.count else { throw Failure("Duplicate reviewed_sources in result.json.") }
            let directory = task.workspace.runDirectory(task.id)
            let originalRegistry = try SecretaryRegistryRevision.originalRegistry(directory: directory)
            let originals = originalRegistry?.sources
            if task.workspace.hasManagedProtocol, !reviewed.isEmpty, originals == nil { throw Failure("Managed pass has no registry snapshot.") }
            if task.usesSourceDecisions, let originalRegistry {
                try SecretaryRegistryRevision.validate(snapshot: originalRegistry, current: data, sources: bySource, runID: task.id)
            }
            timing?.checkpoint("registry_validation", subtotal: "bookkeeping")
            var updates: [String: [String: Any]] = [:]
            let receiptURL = SecretaryReadReceipt.logURL(runID: task.id, store: store)
            let receiptData = (try? Data(contentsOf: receiptURL)) ?? Data()
            let receipts = try receiptData.split(separator: 10).map { try JSONDecoder().decode(SecretaryReadReceipt.self, from: Data($0)) }
            let files = reviewed.isEmpty && !reconcileMediaAliases ? [] : await (recordings ?? { await FileRepository().recordings() })()
            let allowed = Set(files.map { $0.standardizedFileURL.path })
            var changes: [String: AgentMarkStore.Mark?] = [:]
            let existing = store.marks()
            for id in reviewed {
                do {
                    guard var source = bySource[id] else { throw Failure("\(id): not in registry.") }
                    guard !flag(source["removed_from_wimm"]), !flag(source["wimm_unindexed"]) else {
                        throw Failure("\(id): registry says removed/unindexed; no mark written.")
                    }
                    let sourceURL = try sidecarURL(source, task: task)
                    let matching = receipts.filter { receipt in
                        guard URL(fileURLWithPath: receipt.sidecar).resolvingSymlinksInPath() == sourceURL.resolvingSymlinksInPath() else { return false }
                        guard let file = source["note_file"] as? String else { return true }
                        return URL(fileURLWithPath: receipt.file).lastPathComponent == file
                    }
                    guard let receipt = matching.last else { throw Failure("\(id): no get_note receipt in this run.") }
                    let media = URL(fileURLWithPath: receipt.file).standardizedFileURL
                    guard allowed.contains(media.path), FileStore.metadataURL(forRecordingURL: media).resolvingSymlinksInPath() == sourceURL.resolvingSymlinksInPath(),
                          let loaded = RecallSidecar.load(forRecordingURL: media) else {
                        throw Failure("\(id): receipt does not resolve to a current Wimm note.")
                    }
                    let fingerprint = NoteFingerprint.read(forRecordingURL: media)
                    guard digest(loaded.data) == receipt.sha256, fingerprint.text == receipt.text, fingerprint.analysis == receipt.analysis else {
                        throw Failure("\(id): note changed after get_note; left pending for another pass.")
                    }
                    guard receipt.allAvailableTextSupplied else {
                        throw Failure("\(id): incomplete or unknown text coverage; read get_note with full: true before acknowledging the source.")
                    }
                    if receipt.partialView != nil, decisionByID[id]?.status != "noise" {
                        throw Failure("\(id): only a partial view was shown; it can only be marked noise.")
                    }
                    let file = media.lastPathComponent
                    guard changes[file] == nil, existing[file]?.source == nil || existing[file]?.source == id,
                          !existing.contains(where: { $0.value.source == id && $0.key != file }) else {
                        throw Failure("\(id): conflicting source/file mark; no overwrite.")
                    }
                    if task.usesSourceDecisions, let original = originals?[id], !SecretaryRegistryRevision.equal(original, source),
                       (source["host_review"] as? [String: Any])?["run_id"] as? String != task.id {
                        throw Failure("\(id): existing registry row was edited during the agent run; use source_decisions.")
                    }
                    if let decision = decisionByID[id] {
                        let updated = try SecretaryRegistryRevision.revised(source, decision: decision, receipt: receipt, task: task, known: Set(bySource.keys))
                        if (source["host_review"] as? [String: Any])?["run_id"] as? String == task.id,
                           !SecretaryRegistryRevision.equal(updated, source) {
                            throw Failure("\(id): source changed after this run's finalization.")
                        }
                        if !SecretaryRegistryRevision.equal(updated, source) { updates[id] = updated }
                        source = updated
                    } else if task.usesSourceDecisions, originals?[id] != nil {
                        throw Failure("\(id): existing sources require source_decisions; no registry edits or hashes from the model.")
                    }
                    let raw = source["status"] as! String
                    let status = AgentMarkStore.Mark.Status(rawValue: raw == "duplicate" ? "applied" : raw)!
                    let target = source["duplicate_of"] ?? source["merged_with"]
                    let targetText = (target as? [String])?.joined(separator: ", ") ?? (target as? String)
                    changes[file] = AgentMarkStore.Mark(status: status, source: id,
                        comment: raw == "duplicate" ? "duplicate of \(targetText ?? "see registry")" : nil,
                        markedAt: Date(), noteId: receipt.noteID, sidecarSHA256: receipt.sha256,
                        text: receipt.text, analysis: receipt.analysis, wording: fingerprint.wording)
                } catch { report.findings.append(error.localizedDescription) }
            }
            timing?.checkpoint("receipt_validation", subtotal: "bookkeeping")
            let removals = SecretaryLibraryReconciliation.removals(sources: sources, task: task)
            for (id, source) in removals { updates[id] = source }
            report.removedSources = removals.keys.sorted()
            if reconcileMediaAliases {
                let aliases = SecretaryLibraryReconciliation.mediaAliases(sources: sources, task: task, marks: existing, indexedFiles: files)
                for (id, row) in aliases { updates[id] = row }
                report.remappedSources = aliases.keys.sorted()
            }
            let nextSources = sources.map { updates[$0["source_id"] as! String] ?? $0 }
            let nextRegistry = try SecretaryRegistryRevision.patched(data: registryData, original: data, sources: sources, updates: updates, task: task)
            timing?.checkpoint("registry_update_plan", subtotal: "bookkeeping")
            let documentData = try Data(contentsOf: task.workspace.document)
            let references = try SecretaryCitationDefinitions.repair(document: documentData, sources: nextSources)
            guard try Data(contentsOf: registry) == registryData,
                  try Data(contentsOf: task.workspace.document) == documentData else {
                throw Failure("Registry/document changed during finalization; nothing applied.")
            }
            timing?.checkpoint("citation_repair_plan", subtotal: "bookkeeping")
            if applyChanges && (nextRegistry != registryData || references.data != documentData) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let backup = directory.appendingPathComponent("registry-before-host.json")
                if !FileManager.default.fileExists(atPath: backup.path) {
                    let audit: [String: Any] = ["run_id": task.id, "registry_sha256": digest(registryData),
                        "sources": sources.filter { updates[$0["source_id"] as! String] != nil },
                        "counts": data["counts"] ?? NSNull(), "updated_on": data["updated_on"] ?? NSNull(),
                        "batches_count": (data["batches"] as? [Any])?.count ?? 0,
                        "document_sha256": digest(documentData), "document_bytes": documentData.count,
                        "added_definitions": references.ids]
                    try JSONSerialization.data(withJSONObject: audit, options: [.prettyPrinted, .sortedKeys]).write(to: backup, options: .atomic)
                }
                report.registryBackup = task.workspace.relative(backup)
                if nextRegistry != registryData { try nextRegistry.write(to: registry, options: .atomic) }
                if references.data != documentData { try references.data.write(to: task.workspace.document, options: .atomic) }
            }
            timing?.checkpoint("registry_and_document_write", subtotal: "bookkeeping")
            report.registryUpdated = updates.count
            report.referencesAdded = references.ids.count
            // Keep valid progress even when an unrelated historical source is missing.
            if applyChanges, !changes.isEmpty { try store.update(changes) }
            timing?.checkpoint("mark_write", subtotal: "bookkeeping")
            report.stored = changes.count
            report.storedSources = changes.values.compactMap { $0?.source }.sorted()
            var projectedMarks = existing
            for (file, mark) in changes { projectedMarks[file] = mark }
            report.findings += try checkDocument(task: task, sources: nextSources,
                marks: applyChanges ? store.marks() : projectedMarks,
                documentData: applyChanges ? nil : references.data, deferredPendingSources: deferredPendingSources)
            timing?.checkpoint("final_document_check", subtotal: "bookkeeping")
        } catch { report.findings.append(error.localizedDescription) }
        return report
    }

    private static func sidecarURL(_ source: [String: Any], task: SecretaryTask) throws -> URL {
        guard let path = (source["path"] as? String)?.removingPercentEncoding,
              path.hasPrefix("../recordings/"), path.hasSuffix(".meta.json"),
              !path.dropFirst("../recordings/".count).contains("/"), !path.contains("\\") else {
            throw Failure("Invalid registry recording path.")
        }
        return task.workspace.document.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
    }

    private static func checkDocument(task: SecretaryTask, sources: [[String: Any]], marks: [String: AgentMarkStore.Mark], documentData: Data? = nil,
                                      deferredPendingSources: Set<String> = []) throws -> [String] {
        var findings: [String] = []
        let document = try documentData.map { String(decoding: $0, as: UTF8.self) } ?? String(contentsOf: task.workspace.document, encoding: .utf8)
        let definitions = try NSRegularExpression(pattern: #"^\[([SUW][0-9]+)\]:\s*(\S+)"#, options: .anchorsMatchLines)
        let range = NSRange(document.startIndex..., in: document)
        var refs: [String: String] = [:]
        for match in definitions.matches(in: document, range: range) {
            let id = String(document[Range(match.range(at: 1), in: document)!])
            let target = String(document[Range(match.range(at: 2), in: document)!])
            if refs[id] != nil { findings.append("Duplicate reference definition [\(id)].") }
            refs[id] = target
        }
        let used = try NSRegularExpression(pattern: #"\[([SUW][0-9]+)\](?!:)"#)
        for match in used.matches(in: document, range: range) {
            let id = String(document[Range(match.range(at: 1), in: document)!])
            if refs[id] == nil { findings.append("Reference [\(id)] has no definition.") }
        }
        let ids = Set(sources.compactMap { $0["source_id"] as? String })
        let removed = Set(sources.filter { flag($0["removed_from_wimm"]) }.compactMap { $0["source_id"] as? String })
        let sourcePaths = Dictionary(uniqueKeysWithValues: sources.map { ($0["source_id"] as! String, $0["path"] as! String) })
        for (id, target) in refs {
            if id.hasPrefix("S"), !ids.contains(id) { findings.append("[\(id)] is not in registry.") }
            if target.hasPrefix("http://") || target.hasPrefix("https://") || removed.contains(id) { continue }
            let path = String(target.split(separator: "#", maxSplits: 1).first ?? "").removingPercentEncoding ?? target
            if let expected = sourcePaths[id]?.removingPercentEncoding,
               task.workspace.document.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL !=
                task.workspace.document.deletingLastPathComponent().appendingPathComponent(expected).standardizedFileURL {
                findings.append("[\(id)] points to a different registry target.")
            }
            if !FileManager.default.fileExists(atPath: task.workspace.document.deletingLastPathComponent().appendingPathComponent(path).path) {
                findings.append("[\(id)] references a missing file.")
            }
        }
        // A host-scoped deferred pending source is deliberately unacknowledged. Its absent
        // mark is queue state, not a finalization error; all other registry checks still run.
        // Explicit host-resolved deferrals may have changed since their receipt. They
        // remain pending without a mark; this never authorizes acknowledging them.
        var deferred = deferredPendingSources
        let taskReportURL = task.workspace.runDirectory(task.id).appendingPathComponent("packet-task-report.json")
        if task.packetMode, let data = try? Data(contentsOf: taskReportURL), data.count <= 1_000_000,
           let reports = try? JSONDecoder().decode([SecretaryPacket.TaskReport].self, from: data) {
            for report in reports where report.state == "deferred" {
                for source in report.sources {
                    let media = URL(fileURLWithPath: source.file)
                    guard let path = sourcePaths[source.id]?.removingPercentEncoding,
                          task.workspace.document.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
                            == FileStore.metadataURL(forRecordingURL: media).standardizedFileURL.resolvingSymlinksInPath(),
                          let sidecar = RecallSidecar.load(forRecordingURL: media), digest(sidecar.data) == source.sha256 else { continue }
                    let fingerprint = NoteFingerprint.read(forRecordingURL: media)
                    guard fingerprint.text == source.text, fingerprint.analysis == source.analysis else { continue }
                    deferred.insert(source.id)
                }
            }
        }
        let marksBySource = Dictionary(grouping: marks.compactMap { file, mark in mark.source.map { ($0, file, mark) } }, by: { $0.0 })
        for source in sources {
            let id = source["source_id"] as! String
            if flag(source["removed_from_wimm"]) { continue }
            let sidecar = try sidecarURL(source, task: task)
            if !FileManager.default.fileExists(atPath: sidecar.path) { findings.append("\(id): registry source file is missing.") }
            if flag(source["wimm_unindexed"]) { continue }
            let want = source["status"] as! String
            let matches = marksBySource[id] ?? []
            let awaitingTask = want == "pending" && matches.isEmpty && deferred.contains(id)
            if !awaitingTask && (matches.count != 1 || matches.first?.2.status.rawValue != (want == "duplicate" ? "applied" : want)) {
                findings.append("\(id): Wimm mark does not match registry status.")
            }
            if let file = matches.first?.1,
               FileStore.metadataURL(forRecordingURL: URL(fileURLWithPath: file)).lastPathComponent != sidecar.lastPathComponent {
                findings.append("\(id): Wimm mark points to a different recording.")
            }
        }
        // A mark without a source reference was set outside the registry (for example an
        // explicit user decision through MCP); it is not secretary bookkeeping to verify.
        for mark in marks.values where mark.source.map({ !ids.contains($0) }) ?? false {
            findings.append("Wimm mark has no matching registry source.")
        }
        return Array(Set(findings)).sorted()
    }

    static func flag(_ value: Any?) -> Bool { value is NSNull || value == nil ? false : (value as? Bool ?? true) }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
