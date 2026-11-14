import Foundation
import WimmDomain
import WimmInfrastructure

/// Ephemeral input/output for a tool-free editor. No semantic index or note writes.
struct SecretaryPacket {
    struct Block: Codable {
        let id: String
        let section: String
        let text: String
        let start: Int
        let length: Int
    }
    struct Edit: Codable {
        let block: String
        let text: String
        var operation: String? = nil
        var match: String? = nil
    }
    struct Plan: Codable {
        let summary: String
        let sourceDecisions: [SecretaryResult.SourceDecision]
        let edits: [Edit]
        let questions: [String]
        let needsContext: [String]
        var needsImages: [String]? = nil
        var tasks: [WorkTask]? = nil
        var readRequests: [ReadRequest]? = nil
        enum CodingKeys: String, CodingKey {
            case summary, edits, questions, tasks
            case readRequests = "read_requests"
            case sourceDecisions = "source_decisions", needsContext = "needs_context"
            case needsImages = "needs_images"
        }
    }
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    struct DecisionIssue: Codable {
        let source: String
        let message: String
    }
    struct InvalidDecisions: LocalizedError {
        let issues: [DecisionIssue]
        var errorDescription: String? { issues.map(\.message).joined(separator: "\n") }
    }

    let task: SecretaryTask
    let documentData: Data
    let registryData: Data
    let queueData: Data
    let blocks: [Block]
    let selected: [String]
    let receipts: [SecretaryReadReceipt]
    let projectedSourceIDs: [String]
    let newSources: [[String: Any]]
    let fullSourcesByID: [String: String]
    let payload: [String: Any]
    let system: String
    /// Format-2 heading insertions: blocks the host chose as anchors although the model never saw them.
    var hostAnchors: Set<String> = []
    /// Format-2 triage previews of sources above the solo limit, by source id. Never in `selected`:
    /// their only outcome is "not a note" (noise), never an edit or a read.
    var previewReceipts: [String: SecretaryReadReceipt] = [:]

    static func prepare(task: SecretaryTask, library: RecallLibrary, marks: AgentMarkStore = AgentMarkStore(),
                        sourceByteLimit: Int = SecretaryPacketSettings.defaultKB * 1000, documentByteLimit: Int = SecretaryPacket.documentBudget,
                        optimizationLevel: SecretaryOptimizationLevel = .l0,
                        editorBundle: Bool = false, sampleSourceIDs: Set<String> = [], requireAllSamples: Bool = true, retryUnfinished: Bool = false, maxSources: Int? = nil) throws -> SecretaryPacket {
        guard maxSources == nil || maxSources! > 0 else { throw Failure("Source count limit must be positive.") }
        guard sourceByteLimit > 0 else { throw Failure("Packet source budget must be positive.") }
        guard !PrivateMode.isEnabled else { throw SecretaryError.privateMode }
        guard task.kind == .pass, task.threads.isEmpty else { throw Failure("Packet passes require no open comment threads; use the regular agent workflow for comments.") }
        let root = task.workspace.root
        let policyURL = root.appendingPathComponent(FileManager.default.fileExists(atPath: root.appendingPathComponent(editsPolicyPath).path) ? editsPolicyPath : "secretary/protocol/packet.md")
        let policy = try String(contentsOf: policyURL, encoding: .utf8)
        guard !policy.isEmpty, policy.utf8.count <= 32_000 else { throw Failure("Packet semantic policy is empty or exceeds 32 KB.") }
        let registryURL = task.workspace.document.deletingPathExtension().appendingPathExtension("sources.json")
        let registryData = try Data(contentsOf: registryURL)
        _ = try SecretaryContext.registry(document: task.workspace.document)
        let registry = try JSONSerialization.jsonObject(with: registryData) as! [String: Any]
        let sources = registry["sources"] as! [[String: Any]]
        let sampleRows = sources.filter { ($0["source_id"] as? String).map(sampleSourceIDs.contains) == true }
        let sampleFiles = Set(sampleRows.compactMap { $0["note_file"] as? String })
        guard sampleRows.count == sampleSourceIDs.count, sampleFiles.count == sampleSourceIDs.count else {
            throw Failure("Sample IDs must identify distinct registry notes with a media file.")
        }
        let known = marks.marks(), since = marks.pass()?.asOf ?? .distantPast
        let snapshots = library.fingerprintSnapshotsByPath()
        let changed = NoteRecall.changed(library, since: sampleSourceIDs.isEmpty ? since : nil,
                                         limit: sampleSourceIDs.isEmpty ? Int.max : sampleSourceIDs.count, newestFirst: true) { path in
            if !sampleSourceIDs.isEmpty { return sampleFiles.contains(URL(fileURLWithPath: path).lastPathComponent) }
            guard let mark = known[URL(fileURLWithPath: path).lastPathComponent] else { return true }
            let url = URL(fileURLWithPath: path)
            let current = snapshots[path]?.current(for: url) ?? NoteFingerprint.read(forRecordingURL: url)
            // A settled note whose re-run only moved punctuation stays settled (2026-11-04: a third of a pass).
            if mark.status == .noise || mark.status == .applied, NoteFingerprint.sameWording(mark, current) { return false }
            return (mark.text != current.text || mark.analysis != current.analysis)
                && !Set(NoteChangeKind.kinds(forRecordingURL: url, since: since)).isDisjoint(with: [.transcript, .edited])
        }
        // Registry rows by resolved sidecar path, built once: resolving every
        // row's path per note cost O(notes × registry) file-system calls (~25 s).
        let documentDirectory = task.workspace.document.deletingLastPathComponent()
        var rowsBySidecar: [String: [[String: Any]]] = [:]
        for row in sources {
            guard let path = (row["path"] as? String)?.removingPercentEncoding else { continue }
            let resolved = documentDirectory.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
            rowsBySidecar[resolved.path, default: []].append(row)
        }
        let server = MCPRecallServer(marks: marks, library: { library })
        var noteObjects: [[String: Any]] = [], receipts: [SecretaryReadReceipt] = [], newSources: [[String: Any]] = []
        var fullSourcesByID: [String: String] = [:]
        var selected: [String] = [], projectedSourceIDs: [String] = [], bytes = 0
        var blockedSources: [[String: String]] = []
        var heldSources: [[String: String]] = []
        var noTextSources: [[String: String]] = []
        var viewingSources: [[String: String]] = [], skippedSources: [[String: String]] = []
        let skipped = !retryUnfinished ? skippedSnapshots(root: root) : [:]
        var unfinishedSources: [[String: String]] = []
        var previews: [[String: Any]] = [], previewReceipts: [String: SecretaryReadReceipt] = [:]
        let soloLimit = sourceByteLimit > Int.max / 2 ? Int.max : sourceByteLimit * 2
        let waiting = !retryUnfinished ? waitingSnapshots(root: root,
            document: (try? String(contentsOf: task.workspace.document, encoding: .utf8)) ?? "",
            queue: (try? Data(contentsOf: root.appendingPathComponent("secretary/review_queue.md"))) ?? Data()) : [:]
        // An explicit user hold is a source-selection decision, not a partial read.
        // Match the exact media file as well as its sidecar: image aliases may share one.
        let heldRows = Dictionary(grouping: sources.filter { row in
            guard let hold = row["user_exclusion"] as? [String: Any] else { return false }
            return hold["active"] as? Bool == true && hold["authority"] as? String == "user"
                && hold["scope"] as? String == "source" && hold["resume"] as? String == "explicit_user_release"
                && !(hold["reason"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }, by: { $0["note_file"] as? String ?? "" })
        var pool = SecretaryEvidencePool(), routing: [String] = []
        var number = sources.compactMap { ($0["source_id"] as? String).flatMap { Int($0.dropFirst()) } }.max() ?? 0
        for note in changed.notes {
            if let maxSources, selected.count >= maxSources { break }
            let candidateSidecar = FileStore.metadataURL(forRecordingURL: URL(fileURLWithPath: note.filePath)).resolvingSymlinksInPath()
            if let rows = heldRows[URL(fileURLWithPath: note.filePath).lastPathComponent], rows.count == 1,
               let row = rows.first, let source = row["source_id"] as? String,
               rowsBySidecar[candidateSidecar.path]?.contains(where: { $0["source_id"] as? String == source }) == true,
               let hold = row["user_exclusion"] as? [String: Any] {
                heldSources.append(["source": source, "reason": hold["reason"] as! String,
                                    "scope": "user_excluded; not read or acknowledged in this pass"])
                continue
            }
            if let rows = rowsBySidecar[candidateSidecar.path], rows.count == 1, let row = rows.first,
               SecretaryBookkeeping.flag(row["removed_from_wimm"]) || SecretaryBookkeeping.flag(row["wimm_unindexed"]) {
                blockedSources.append(["source": row["source_id"] as! String,
                    "file": URL(fileURLWithPath: note.filePath).lastPathComponent,
                    "reason": "Registry marks source removed/unindexed; manual reconciliation required. Not admitted or acknowledged."])
                continue
            }
            var evidenceHeader = "", evidenceBlocks: [MCPRecallServer.EvidenceBlock] = []
            let readFormat: MCPRecallServer.NoteReadFormat = optimizationLevel == .l0 ? .secretaryPacket : .secretaryPacketWithMetadata
            let read = server.readNote(note, full: true, format: readFormat,
                evidence: editorBundle ? { header, blocks in evidenceHeader = header; evidenceBlocks = blocks } : nil)
            guard let receipt = read.receipt else { continue } // Cannot attest cached fallback or missing typed text.
            let sidecar = URL(fileURLWithPath: receipt.sidecar).resolvingSymlinksInPath()
            // A note with no text at all (failed or pending transcription) gives the editor nothing to
            // read; admitting it only made every packet defer it again (2026-10-31: eight passes in a row).
            // `prepare --admit-images` (2026-11-14, user decision): an editor that can look at the image
            // itself gets low-text images admitted unchanged instead of parking them as "waits for viewing".
            if (receipt.suppliedText?.isEmpty == true && !Self.admitsVerifiedSilence(sidecar: receipt.sidecar))
                || (!Self.admitImagesForViewing && waitsForViewing(kind: note.kind, text: read.text)) {
                var entry = ["file": URL(fileURLWithPath: receipt.file).lastPathComponent,
                             "reason": "No transcript or text yet; waits for (re)transcription. Not admitted or acknowledged."]
                if let row = rowsBySidecar[sidecar.path]?.first, let id = row["source_id"] as? String { entry["source"] = id }
                if note.kind == "image" {
                    entry["reason"] = "Image with almost no readable text; waits for viewing. Not admitted or acknowledged."
                    viewingSources.append(entry)
                } else { noTextSources.append(entry) }
                continue
            }
            var entry = ["file": URL(fileURLWithPath: receipt.file).lastPathComponent]
            if let row = rowsBySidecar[sidecar.path]?.first, let id = row["source_id"] as? String { entry["source"] = id }
            let key = snapshotKey(file: receipt.file, sha256: receipt.sha256, text: receipt.text, analysis: receipt.analysis)
            if let earlier = waiting[key] {
                entry["reason"] = "Unfinished: \(earlier.reason ?? "obstacle not stated"); returns when its text, \(earlier.section ?? "the document section") or the review queue changes."
                unfinishedSources.append(entry)
                continue
            }
            if let passes = skipped[key], passes >= skipAfterPasses {
                entry["reason"] = "Not used or reviewed in \(passes) passes; skipped until its text changes. Not acknowledged."
                skippedSources.append(entry)
                continue
            }
            if read.text.utf8.count > soloLimit {
                // Too large even alone: report it and read the rest, or one stray log file
                // (a 4.5 MB app log, 2026-11-03) stops every pass. Never truncated or acknowledged.
                // Checked before the packet fills, so the report names it on every pass.
                let file = URL(fileURLWithPath: receipt.file).lastPathComponent
                var entry = ["file": file,
                             "reason": "Complete source is \(read.text.utf8.count) bytes, above the solo packet limit; not truncated, admitted or acknowledged. Needs the regular agent workflow or a user hold."]
                let matching = rowsBySidecar[sidecar.path] ?? []
                if let id = matching.first?["source_id"] as? String { entry["source"] = id }
                let owned = root.appendingPathComponent("recordings").resolvingSymlinksInPath()
                if matching.count <= 1,
                   SecretaryLibraryReconciliation.sameDirectory(sidecar.deletingLastPathComponent(), owned) {
                    let id: String
                    if let existing = entry["source"] { id = existing } else {
                        guard number < Int.max - 1 else { throw Failure("Registry source numbers are exhausted.") }
                        number += 1; id = "S\(number)"
                        newSources.append(["source_id": id, "path": "../recordings/" + sidecar.lastPathComponent,
                            "note_file": file, "status": "pending", "reason": "Above the solo packet limit; partial preview only",
                            "primary_text_read": false, "audio_listened": false, "original_image_viewed": false,
                            "recorded_at_local": SecretaryClock.stamp(note.date), "timestamp_basis": "Wimm captured date; not event date"])
                    }
                    let view = Self.partialView(read.text)
                    var shown = receipt
                    shown.partialView = .init(totalBytes: read.text.utf8.count, headBytes: view.head.utf8.count, tailBytes: view.tail.utf8.count)
                    previewReceipts[id] = shown
                    previews.append(["source": id, "file": file, "kind": note.kind, "total_bytes": read.text.utf8.count,
                        "label": "PARTIAL VIEW, not the full source: only its beginning and end are shown.",
                        "head": view.head, "tail": view.tail,
                        "allowed_outcome": "not_a_note only, or leave it out; never an edit, done_no_additions or unfinished"])
                    entry["source"] = id
                    entry["reason"]! += " Offered as a partial preview (not_a_note only)."
                    bytes += view.head.utf8.count + view.tail.utf8.count
                }
                blockedSources.append(entry)
                continue
            }
            if bytes + read.text.utf8.count > sourceByteLimit {
                // A long first source must not permanently block the queue.
                // Give it a bounded solo packet; never truncate its variants or
                // also fill the packet with more notes above the normal limit.
                if !selected.isEmpty { break }
            }
            let media = URL(fileURLWithPath: receipt.file)
            let owned = root.appendingPathComponent("recordings").resolvingSymlinksInPath()
            guard SecretaryLibraryReconciliation.sameDirectory(sidecar.deletingLastPathComponent(), owned) else {
                throw Failure("Packet library does not match the workspace recordings directory.")
            }
            let candidates = rowsBySidecar[sidecar.path] ?? []
            let matching = candidates.count > 1 ? candidates.filter { $0["note_file"] as? String == media.lastPathComponent } : candidates
            guard matching.count <= 1, candidates.count <= 1 || matching.count == 1 else {
                throw Failure("Several registry sources name one packet note without a unique media-file match.")
            }
            let id: String
            if let row = matching.first {
                id = row["source_id"] as! String
                guard !SecretaryBookkeeping.flag(row["removed_from_wimm"]), !SecretaryBookkeeping.flag(row["wimm_unindexed"]) else {
                    throw Failure("\(id): source marked removed/unindexed needs manual reconciliation.")
                }
            } else {
                guard number < Int.max - 1 else { throw Failure("Registry source numbers are exhausted.") }
                number += 1; id = "S\(number)"
                newSources.append(["source_id": id, "path": "../recordings/" + sidecar.lastPathComponent,
                    "note_file": media.lastPathComponent, "status": "pending", "reason": "Awaiting version-checked packet decision",
                    "primary_text_read": false, "audio_listened": false, "original_image_viewed": false,
                    "recorded_at_local": SecretaryClock.stamp(note.date), "timestamp_basis": "Wimm captured date; not event date"])
            }
            let row = matching.first ?? [:]
            var previous: [String: Any] = [:]
            for key in ["status", "reason", "read_scope", "primary_text_read", "audio_listened", "original_image_viewed", "reviewed_on", "duplicate_of", "merged_with"] {
                if let value = row[key] { previous[key] = value }
            }
            let suppliedText = SecretaryOptimization.filter(read.text, level: optimizationLevel)
            var renderedReceipt = receipt
            if editorBundle {
                guard optimizationLevel == .l0 else { throw Failure("Editor bundles require full L0 evidence.") }
                renderedReceipt = try pool.append(source: id, header: evidenceHeader, blocks: evidenceBlocks, receipt: receipt)
                let speech = evidenceBlocks.filter(\.isTranscript).map(\.text).joined(separator: "\n")
                let placementContext = evidenceBlocks
                    .filter { $0.label.hasPrefix("conversation context") }
                    .map(\.text)
                    .joined(separator: "\n")
                // Generated titles and conversation context help routing only, never become factual source evidence.
                routing.append(speech.isEmpty && note.kind == "text" ? note.text : speech)
                if !placementContext.isEmpty { routing.append(placementContext) }
                routing.append(note.title ?? "")
            }
            if !suppliedText.utf8.elementsEqual(read.text.utf8) {
                // The original receipt covers read.text, not this later projection.
                // Until the projection has block-level coverage, scope is unknown.
                renderedReceipt.suppliedText = nil
                projectedSourceIDs.append(id)
            }
            noteObjects.append(["source": id, "previous": previous, "full_text": suppliedText])
            fullSourcesByID[id] = suppliedText
            receipts.append(renderedReceipt); selected.append(id); bytes += suppliedText.utf8.count
        }
        guard !selected.isEmpty || !previews.isEmpty else {
            if !viewingSources.isEmpty || !skippedSources.isEmpty || !unfinishedSources.isEmpty, heldSources.isEmpty, blockedSources.isEmpty {
                throw Failure("Only notes waiting for text (\(noTextSources.count)), for viewing (\(viewingSources.count)), unfinished (\(unfinishedSources.count)) or skipped (\(skippedSources.count)) remain. Nothing read or acknowledged.")
            }
            if !noTextSources.isEmpty && heldSources.isEmpty && blockedSources.isEmpty {
                throw Failure("Only notes without text remain (\(noTextSources.count)); retranscribe them first. Nothing read or acknowledged.")
            }
            if !heldSources.isEmpty && blockedSources.isEmpty {
                throw Failure("Candidate sources are explicitly held by the user: \(heldSources.compactMap { $0["source"] }.joined(separator: ", ")). Nothing read or acknowledged.")
            }
            if !blockedSources.isEmpty {
                let named = Set(blockedSources.map { "\($0["source"] ?? $0["file"] ?? "?"): \($0["reason"] ?? "")" }).sorted()
                throw Failure("No admissible sources; blocked: \(named.joined(separator: "; ")) Nothing acknowledged.")
            }
            throw SecretaryError.nothingToDo
        }
        let missingSample = sampleSourceIDs.subtracting(selected)
        guard !requireAllSamples || missingSample.isEmpty else {
            throw Failure("Sample sources unavailable or over budget: \(missingSample.sorted().joined(separator: ", ")).")
        }
        let documentData = try Data(contentsOf: task.workspace.document)
        let blocks = Self.blocks(String(decoding: documentData, as: UTF8.self))
        let text = editorBundle ? routing.joined(separator: "\n") : noteObjects.map { $0["full_text"] as! String }.joined(separator: "\n")
        let ownTerms = editorBundle ? [] : noteObjects.map { evidenceTerms($0["full_text"] as! String) }
        let supplied = select(blocks: blocks, sourceIDs: selected, terms: terms(text), limit: documentByteLimit,
                              excluding: [], sourceTerms: ownTerms).sorted { $0.start < $1.start }
        let queueURL = root.appendingPathComponent("secretary/review_queue.md")
        let queue = (try? Data(contentsOf: queueURL)) ?? Data()
        let openQueue = Self.openQuestions(String(decoding: queue, as: UTF8.self))
        guard openQueue.utf8.count <= 24_000 else { throw Failure("Open questions exceed packet limit; use regular workflow.") }
        let outlineEntries: [[String: String]] = blocks.compactMap { b in heading(b.text).map { ["id": b.id, "title": String($0.line.prefix(160))] } }
        var payload: [String: Any] = ["run": task.id, "as_of": SecretaryClock.stamp(task.createdAt), "document": task.workspace.doc,
            "sources": noteObjects, "selected_count": selected.count, "remaining": changed.total - selected.count,
            "document_blocks": objects(supplied), "outline": outlineEntries, "outline_truncated": false,
            "review_queue": openQueue, "source_text_truncated": !projectedSourceIDs.isEmpty, "solo_large_source": bytes > sourceByteLimit,
            "response_format": 2, "blocked_sources": blockedSources, "held_sources": heldSources, "no_text_sources": noTextSources,
            "viewing_sources": viewingSources, "skipped_sources": skippedSources, "unfinished_sources": unfinishedSources,
            "oversize_previews": previews]
        let voiceCards = Self.voiceCards(in: selected.compactMap { fullSourcesByID[$0] }, document: task.workspace.document)
        if !voiceCards.isEmpty { payload["voice_cards"] = voiceCards }
        if editorBundle {
            payload["editor_evidence"] = pool.object
            let context = editorContext(blocks: blocks, sourceIDs: selected, primaryText: text,
                                        limit: documentByteLimit, requested: [])
            payload["document_blocks"] = objects(context.blocks)
            payload["context_coverage"] = context.report
            payload["outline"] = blocks.compactMap { b in heading(b.text).map { ["id": b.id, "title": $0.line] } }
            payload["outline_truncated"] = false
        }
        return SecretaryPacket(task: task, documentData: documentData, registryData: registryData, queueData: queue,
            blocks: blocks, selected: selected, receipts: receipts, projectedSourceIDs: projectedSourceIDs, newSources: newSources, fullSourcesByID: fullSourcesByID, payload: payload,
            system: editsContract + "\n" + policy, previewReceipts: previewReceipts)
    }

    /// Names for the card ids Wimm's own `voices:` header lines carry, from the people card file
    /// beside the document (`me.md` → `me.people.json`). Only ids of this packet; an id without
    /// a card is left out and stays a bare id.
    static func voiceCards(in sources: [String], document: URL) -> [String: String] {
        var ids = Set<String>()
        for source in sources {
            for line in source.components(separatedBy: "\n").prefix(40) where line.hasPrefix("voices: ") {
                for part in line.components(separatedBy: "[").dropFirst() {
                    let id = String(part.prefix { $0 != "]" })
                    if PersonVoiceProfiles.isCardID(id) { ids.insert(id) }
                }
            }
        }
        guard !ids.isEmpty else { return [:] }
        let file = document.deletingPathExtension().appendingPathExtension("people.json")
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cards = root["cards"] as? [[String: Any]] else { return [:] }
        var result: [String: String] = [:]
        for card in cards {
            guard let id = card["id"] as? String, ids.contains(id), let name = card["canonical"] as? String else { continue }
            let relation = (card["relation"] as? String).map { " — \($0)" } ?? ""
            result[id] = String((name + relation).prefix(160))
        }
        return result
    }

    /// About `limit` bytes of the beginning and of the end of the complete text, cut at line ends where possible.
    static func partialView(_ text: String, limit: Int = 2_000) -> (head: String, tail: String) {
        let bytes = Array(text.utf8)
        guard bytes.count > 2 * limit else { return (text, "") }
        var head = limit
        if let line = bytes[limit / 2..<limit].lastIndex(of: 10) { head = line + 1 }
        else { while head > 0, bytes[head] & 0xC0 == 0x80 { head -= 1 } }
        var tail = bytes.count - limit
        if let line = bytes[tail..<(bytes.count - limit / 2)].firstIndex(of: 10) { tail = line + 1 }
        else { while tail < bytes.count, bytes[tail] & 0xC0 == 0x80 { tail += 1 } }
        return (String(decoding: bytes[..<head], as: UTF8.self), String(decoding: bytes[tail...], as: UTF8.self))
    }

    var hostQueues: SecretaryHostQueues {
        SecretaryHostQueues(waitingForText: (payload["no_text_sources"] as? [Any])?.count ?? 0,
                            waitingForViewing: (payload["viewing_sources"] as? [Any])?.count ?? 0,
                            skipped: (payload["skipped_sources"] as? [Any])?.count ?? 0,
                            unfinished: (payload["unfinished_sources"] as? [Any])?.count ?? 0)
    }

    static func blocks(_ text: String) -> [Block] {
        let regex = try! NSRegularExpression(pattern: #"(?s).+?(?:\n[ \t]*\n|\z)"#)
        let ns = text as NSString
        var section = ""
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).enumerated().map { index, match in
            let value = ns.substring(with: match.range)
            if let heading = Self.heading(value) { section = String(heading.line.prefix(200)) }
            return Block(id: "b\(index)", section: section, text: value, start: match.range.location, length: match.range.length)
        }
    }
    static func openQuestions(_ queue: String) -> String {
        let regex = try! NSRegularExpression(pattern: #"^## Открытые вопросы[^\n]*\n.*?(?=^## |\z)"#, options: [.anchorsMatchLines, .dotMatchesLineSeparators])
        let ns = queue as NSString
        return regex.firstMatch(in: queue, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) } ?? queue
    }
    static func terms(_ text: String) -> Set<String> {
        let stop: Set<String> = ["только", "потом", "который", "которые", "потому", "сейчас", "запись", "заметка", "transcript", "source", "document", "refined", "current", "fallback"]
        return Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 4 && !stop.contains($0) })
    }
    /// Russian inflects; the first five letters match "Марина/Марину", "балет/балета".
    static func stem(_ word: String) -> String { String(word.prefix(5)) }
    /// Default document context for a packet (user decision 2026-10-31: 50 KB). 24 KB left most
    /// voice notes without their topic once the start (≈11 KB) and required sections were in.
    static let documentBudget = 50_000
    /// Frequent function words that match many blocks without naming a topic.
    static let functionStems: Set<String> = Set("""
        будет если есть него можно свою более пока когда меня один себе возможно должен другие много после сказал \
        также этого этот этой этом очень нужно надо тоже чтобы даже было были была своей своих между через здесь \
        теперь всегда никогда снова сразу сама может могу хочу хочет весь всех всем того тому какой какая какие \
        такой такая такие просто вообще тогда where with that this from have what when there their about would \
        could should into than then they them were
        """.split(whereSeparator: { $0.isWhitespace || $0 == "\\" }).map { stem(String($0)) })
    /// A source's own words for block selection: evidence text only, without the header and
    /// block-label lines (`speech: failed`, `--- transcript ---`) every source shares.
    static func evidenceTerms(_ fullText: String) -> Set<String> {
        let header = try! NSRegularExpression(pattern: #"^(--- .* ---.*|[a-z_]+(\[[^\]]*\])?: .*|\(no text\))$"#)
        let lines = fullText.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let s = String(line)
            return header.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) == nil
        }
        return terms(lines.joined(separator: "\n"))
    }

    /// Order: cited/start/required blocks, then each source's own best blocks, then the pooled
    /// lexical ranking. `sourceTerms` (one set per source) keeps a large source — screenshot OCR
    /// — from crowding out a short voice note's only matching topic.
    static func select(blocks: [Block], sourceIDs: [String], terms: Set<String>, limit: Int, phrases: [String] = [],
                       excluding: Set<String> = [], sourceTerms: [Set<String>] = []) -> [Block] {
        if !phrases.isEmpty {
            return contextSelection(blocks: blocks, requests: phrases, existing: excluding, limit: limit).blocks
        }
        var frequency: [String: Int] = [:]
        let tokens = blocks.map { Set(Self.terms($0.text).map(stem)) }
        for words in tokens { for word in words { frequency[word, default: 0] += 1 } }
        // Repeated boilerplate is a poor retrieval signal. This is a local
        // document-frequency count, rebuilt per packet, never a stored index.
        func uncommon(_ words: Set<String>) -> Set<String> {
            Set(words.map(stem)).filter { !functionStems.contains($0) && frequency[$0, default: 0] <= max(3, blocks.count / 10) }
        }
        // Rarer words say more about the topic than words found in dozens of blocks.
        func idf(_ word: String) -> Double { log(Double(blocks.count) / Double(1 + frequency[word, default: 0])) }
        let candidates = blocks.indices.filter { !excluding.contains(blocks[$0].id) && !isDefinition(blocks[$0].text) }
        // Hits per length: a long block should not win merely by containing more words.
        func density(_ index: Int, _ words: Set<String>) -> Double {
            Double(tokens[index].intersection(words).count) / log2(2 + Double(tokens[index].count))
        }
        let pooled = uncommon(terms)
        var ranked: [(Int, Int)] = []
        for index in candidates {
            let block = blocks[index], text = block.text.lowercased()
            let cites = sourceIDs.contains { text.contains("[\($0.lowercased())]") }
            let startScore = index < 8 ? 200 : 0
            let section = block.section.lowercased()
            let required = ["вопросы и наблюдения", "основания", "последняя известная картина"].contains { section.contains($0) }
            let requiredScore = required ? 190 : 0
            let citationScore = cites ? 600 : 0
            let score = startScore + requiredScore + citationScore + min(50, Int((density(index, pooled) * 10).rounded()))
            if score > 0 { ranked.append((index, score)) }
        }
        ranked.sort { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        // Up to two blocks per source whose shared rare words weigh about two distinctive words
        // (≈ 8 on a 560-block document), taken round by round so every source gets its best first.
        let minimumWeight = 1.6 * log(max(2, Double(blocks.count) / 4))
        let perSource = sourceTerms.map { words -> [Int] in
            let own = uncommon(words)
            let scored = candidates.compactMap { index -> (Int, Double)? in
                let weight = tokens[index].intersection(own).reduce(0) { $0 + idf($1) }
                return weight >= minimumWeight ? (index, weight / log2(2 + Double(tokens[index].count))) : nil
            }
            return scored.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }.prefix(2).map(\.0)
        }
        // Order: blocks citing a source, the document start (its summary), each source's best
        // block, the required sections (their history alone can exceed 10 KB), second-best
        // blocks, then the pooled ranking.
        // Within a round, shorter blocks first: one 3 KB block must not cost several sources their topic.
        let round = { (r: Int) in perSource.compactMap { $0.count > r ? $0[r] : nil }.sorted { blocks[$0].length < blocks[$1].length } }
        let tier = { (range: Range<Int>) in ranked.filter { range.contains($0.1) }.map(\.0) }
        let start = ranked.filter { $0.1 >= 200 && $0.1 < 600 && $0.0 < 8 }.map(\.0)
        let order = tier(600..<Int.max) + start + round(0)
            + ranked.filter { $0.1 >= 190 && $0.1 < 600 && $0.0 >= 8 }.map(\.0) + round(1) + tier(0..<190)
        var chosen = Set<Int>(), bytes = 0
        for index in order {
            // Do not spend the last bytes on a neighbour before the match.
            let neighbours = [index, index - 1, index + 1]
            for i in neighbours where blocks.indices.contains(i) && !chosen.contains(i) && !excluding.contains(blocks[i].id) && !isDefinition(blocks[i].text) {
                let cost = blocks[i].text.utf8.count
                if bytes + cost <= limit { chosen.insert(i); bytes += cost }
            }
        }
        return chosen.sorted().map { blocks[$0] }
    }
    static func heading(_ text: String) -> (line: String, title: String, depth: Int)? {
        // Personal Markdown may put an HTML anchor immediately before an ATX heading.
        let regex = try! NSRegularExpression(pattern: #"\A(?:[ \t]*<a\b[^\n]*</a>[ \t]*\n)*[ \t]*(#{1,6})[ \t]+([^\n]+)"#)
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let hashes = ns.substring(with: match.range(at: 1))
        let title = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
        return (hashes + " " + title, title.lowercased(), hashes.count)
    }

    static func isDefinition(_ text: String) -> Bool {
        text.range(of: #"(?m)^\[[SUW][0-9]+\]:"#, options: .regularExpression) != nil
    }

    static func contextIDs(_ text: String) -> Set<String> {
        let regex = try! NSRegularExpression(pattern: #"\b[SUW][0-9]+\b"#)
        let ns = text as NSString
        return Set(regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) })
    }

    struct ContextClause: Codable {
        let query: String
        let status: String
        let exactMatches: [String]
        let suppliedExactMatches: [String]
    }
    struct ContextMatch: Codable {
        let request: String
        let status: String
        let matchedBlocks: [String]
        let suppliedBlocks: [String]
        let omittedForBudget: [String]
        let referencedSources: [String]
        let unmatchedTerms: [String]
        var clauses: [ContextClause]? = nil
    }
    struct ContextSelection {
        let blocks: [Block]
        let reports: [ContextMatch]
    }

    /// Local document retrieval only. Round-robin across clauses prevents one large topic
    /// from consuming every byte; a heading and its first body block are admitted together.
    static func contextSelection(blocks: [Block], requests: [String], existing: Set<String>, limit: Int) -> ContextSelection {
        let headings = blocks.map { heading($0.text) }
        let words = blocks.map { terms($0.text) }
        let citations = blocks.map { contextIDs($0.text) }
        var frequency: [String: Int] = [:]
        for (i, tokens) in words.enumerated() where !isDefinition(blocks[i].text) {
            for word in tokens { frequency[word, default: 0] += 1 }
        }
        struct Lane { let candidates: [Int] }
        var lanes: [Lane] = []
        var matched = Array(repeating: Set<Int>(), count: requests.count)
        for (requestIndex, request) in requests.enumerated() {
            for clause in request.split(separator: ";").map(String.init) {
                let lower = clause.lowercased()
                let ids = contextIDs(clause)
                let query = terms(clause).filter { frequency[$0, default: 0] <= max(3, blocks.count / 10) }
                let prefix = clause.split(separator: ":", maxSplits: 1).first.map(String.init) ?? clause
                let prefixWords = terms(prefix).filter { $0.contains(where: \.isLetter) }
                var sections = Set<Int>()
                for (i, h) in headings.enumerated() {
                    guard let h else { continue }
                    let titleWords = terms(h.title).filter { $0.contains(where: \.isLetter) }
                    let overlap = titleWords.intersection(query).count
                    let prefixMatch = clause.contains(":") && !prefixWords.isEmpty && prefixWords.isSubset(of: titleWords)
                    guard lower.contains(h.title) || prefixMatch || (overlap >= 2 && overlap * 2 >= titleWords.count) else { continue }
                    sections.insert(i)
                    for j in (i + 1)..<blocks.count {
                        if let next = headings[j], next.depth <= h.depth { break }
                        sections.insert(j)
                    }
                }
                var ranked: [(Int, Int)] = []
                for (i, block) in blocks.enumerated() where !isDefinition(block.text) {
                    let citation = !citations[i].isDisjoint(with: ids)
                    let hits = words[i].intersection(query).count
                    let exact = block.text.lowercased().contains(lower.trimmingCharacters(in: .whitespacesAndNewlines))
                    let score = (citation ? 1200 : 0) + (sections.contains(i) ? 800 : 0) + (exact ? 1000 : 0) + min(100, hits * 10)
                    if score > 0 { ranked.append((i, score)); matched[requestIndex].insert(i) }
                }
                ranked.sort { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
                lanes.append(Lane(candidates: ranked.map(\.0)))
            }
        }
        var chosen = Set<Int>(), bytes = 0
        var positions = Array(repeating: 0, count: lanes.count)
        var progress = true
        while progress {
            progress = false
            for (laneIndex, lane) in lanes.enumerated() {
                guard positions[laneIndex] < lane.candidates.count else { continue }
                let index = lane.candidates[positions[laneIndex]]
                positions[laneIndex] += 1; progress = true
                var unit = Set([index])
                if let heading = headings[index] {
                    for next in (index + 1)..<blocks.count {
                        if isDefinition(blocks[next].text) { break }
                        if let child = headings[next] {
                            if child.depth <= heading.depth { break }
                            unit.insert(next)
                        } else { unit.insert(next); break }
                    }
                } else if let parent = (0..<index).reversed().first(where: { headings[$0] != nil }) {
                    unit.insert(parent)
                }
                let fresh = unit.filter { !existing.contains(blocks[$0].id) && !chosen.contains($0) }
                let cost = fresh.reduce(0) { $0 + blocks[$1].text.utf8.count }
                if bytes + cost <= limit { chosen.formUnion(fresh); bytes += cost }
            }
        }
        let reports = requests.enumerated().map { index, request -> ContextMatch in
            let all = matched[index].sorted()
            let supplied = all.filter { chosen.contains($0) || existing.contains(blocks[$0].id) }
            let omitted = all.filter { !chosen.contains($0) && !existing.contains(blocks[$0].id) }
            return ContextMatch(request: request, status: all.isEmpty ? "not_found" : (omitted.isEmpty ? "matched" : "partial"),
                matchedBlocks: all.map { blocks[$0].id }, suppliedBlocks: supplied.map { blocks[$0].id },
                omittedForBudget: omitted.map { blocks[$0].id }, referencedSources: contextIDs(request).sorted(),
                unmatchedTerms: terms(request).filter { $0.contains(where: \.isLetter) && frequency[$0, default: 0] == 0 }.sorted(),
                clauses: request.split(separator: ";").map { clause in
                    let query = String(clause).trimmingCharacters(in: .whitespacesAndNewlines)
                    let exact = blocks.indices.filter { !isDefinition(blocks[$0].text) && blocks[$0].text.range(of: query, options: .caseInsensitive) != nil }
                    return ContextClause(query: query, status: exact.isEmpty ? "no_exact_document_mention" : "exact_document_mention",
                        exactMatches: exact.map { blocks[$0].id },
                        suppliedExactMatches: exact.filter { chosen.contains($0) || existing.contains(blocks[$0].id) }.map { blocks[$0].id })
                })
        }
        return ContextSelection(blocks: chosen.sorted().map { blocks[$0] }, reports: reports)
    }

    /// `section` is given only when it changes from the previous block in this list and the block
    /// is not that heading itself; consecutive blocks of one section would otherwise repeat it.
    static func objects(_ blocks: [Block]) -> [[String: String]] {
        var previous: String?
        return blocks.map { block in
            defer { previous = block.section }
            let isOwnHeading = block.text.split(separator: "\n").contains { $0 == Substring(block.section) }
            guard block.section != previous, !isOwnHeading else { return ["id": block.id, "text": block.text] }
            return ["id": block.id, "section": block.section, "text": block.text]
        }
    }
    func prompt(extra: [String] = []) throws -> String {
        var input = payload
        if !extra.isEmpty {
            guard extra.count <= 5, extra.allSatisfy({ !$0.isEmpty && $0.count <= 200 }) else { throw Failure("Invalid packet context request.") }
            var requestedSources = Set<String>()
            for request in extra {
                let explicit = request.hasPrefix("full:")
                let id = explicit ? String(request.dropFirst(5)) : request
                if explicit || (selected.contains(id) && id.range(of: #"^S[0-9]+$"#, options: .regularExpression) != nil) {
                    guard selected.contains(id), fullSourcesByID[id] != nil else {
                        throw Failure("Requested source \(id) is outside this packet; use the regular workflow for additional sources.")
                    }
                    requestedSources.insert(id)
                } else if explicit { throw Failure("Invalid full-source request: \(request)") }
            }
            var current = payload["document_blocks"] as! [[String: String]]
            let ids = Set(current.compactMap { $0["id"] })
            let selection = Self.contextSelection(blocks: blocks, requests: extra, existing: ids, limit: 48_000)
            current += Self.objects(selection.blocks)
            input["context_report"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(selection.reports))
            input["context_document_sha256"] = SecretaryBookkeeping.digest(documentData)
            input["context_searched_blocks"] = blocks.filter { !Self.isDefinition($0.text) }.count
            input["context_report_scope"] = "Search covers the complete versioned document, excluding citation definitions. Clause exactMatches distinguish missing literal text from existing text omitted for budget. No exact match does not rule out paraphrases or an event. Lexical document matches only, not proof of semantic sufficiency. Omitted blocks did not fit the expansion budget. Referenced source IDs locate document mentions; no additional raw sources were read. Use full:S… only for sources already in this packet."
            if !requestedSources.isEmpty, var sources = input["sources"] as? [[String: Any]] {
                for i in sources.indices {
                    if let id = sources[i]["source"] as? String, requestedSources.contains(id) {
                        guard let expanded = fullSourcesByID[id], expanded == sources[i]["full_text"] as? String else {
                            throw Failure("Full source \(id) is not the admitted complete snapshot; nothing expanded.")
                        }
                        sources[i]["full_text"] = expanded
                    }
                }
                input["sources"] = sources
            }
            input["document_blocks"] = current; input["context_expansion"] = extra
        }
        // Unadmitted sources are host bookkeeping (manifest/report); listing them invited decisions.
        for key in ["blocked_sources", "held_sources", "no_text_sources", "viewing_sources", "skipped_sources", "unfinished_sources"] { input.removeValue(forKey: key) }
        return String(decoding: try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    static func decode(_ text: String) throws -> Plan {
        var json = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Observed with tool-free Claude: an empty or dummy pseudo-call
        // (<invoke name="none"></invoke> or <invoke name="bash">true</invoke>)
        // and/or brief prose ("Here is the JSON result.") precedes an otherwise valid plan.
        let harmlessInvoke = try NSRegularExpression(
            pattern: #"\A\s*(?:<invoke name="none">\s*</invoke>|<invoke name="(?i:bash)">\s*<parameter name="command">\s*true\s*</parameter>\s*</invoke>)\s*(?:Here is the JSON result\.?\s*)?"#
        )
        if let match = harmlessInvoke.firstMatch(in: json, range: NSRange(json.startIndex..., in: json)),
           let range = Range(match.range, in: json) {
            json.removeSubrange(range)
        }
        if json.hasPrefix("```"), let first = json.firstIndex(of: "\n"), let end = json.range(of: "```", options: .backwards), first < end.lowerBound {
            json = String(json[json.index(after: first)..<end.lowerBound])
        }
        return try JSONDecoder().decode(Plan.self, from: Data(json.utf8))
    }

    func requireValidatedProjection() throws {
        guard projectedSourceIDs.isEmpty else {
            throw Failure("Experimental source projection has no validated text-coverage receipts (\(projectedSourceIDs.joined(separator: ", "))). Preview/offline benchmarks only; use L0 for a regular pass.")
        }
    }

    func apply(_ plan: Plan, prompt: String, marks: AgentMarkStore = AgentMarkStore(), validateOnly: Bool = false,
               validationRows: [String: [String: Any]]? = nil, validationBlocks: Set<String>? = nil) throws -> SecretaryResult {
        guard !PrivateMode.isEnabled else { throw SecretaryError.privateMode }
        let plan = try withoutUnadmittedDecisions(plan).plan
        guard (plan.readRequests ?? []).isEmpty else { throw Failure("Unresolved addressed reads; nothing applied.") }
        guard plan.tasks == nil else { throw Failure("Task envelope must be resolved before application.") }
        guard validateOnly || (validationRows == nil && validationBlocks == nil) else { throw Failure("Cached validation cannot authorize writes.") }
        try requireValidatedProjection()
        guard plan.needsContext.isEmpty else { throw Failure("Packet still needs context; nothing applied.") }
        guard (plan.needsImages ?? []).isEmpty else { throw Failure("Original images are disabled for secretary passes (\((plan.needsImages ?? []).joined(separator:", "))). Nothing applied; a separate explicit user instruction is required.") }
        guard receipts.allSatisfy(\.allAvailableTextSupplied) else {
            throw Failure("Packet has incomplete text coverage; nothing applied.")
        }
        let ids = plan.sourceDecisions.map(\.source)
        guard Set(ids) == Set(selected), ids.count == selected.count else { throw Failure("Packet decisions must cover exactly the supplied sources.") }
        let allowed = try (validationBlocks ?? Set(((JSONSerialization.jsonObject(with: Data(prompt.utf8)) as! [String: Any])["document_blocks"] as! [[String: Any]]).compactMap { $0["id"] as? String })).union(hostAnchors)
        let edits = try materializedEdits(plan.edits, allowed: allowed)
        guard plan.questions.count <= 20,
              plan.questions.allSatisfy({ !$0.isEmpty && $0.count <= 2000 }), plan.summary.count <= 2000 else { throw Failure("Invalid packet edits/questions.") }
        let byID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        let doc = NSMutableString(string: String(decoding: documentData, as: UTF8.self))
        let definition = try NSRegularExpression(pattern: #"^\[[SUW][0-9]+\]:"#, options: .anchorsMatchLines)
        for edit in edits.sorted(by: { byID[$0.block]!.start > byID[$1.block]!.start }) {
            let block = byID[edit.block]!
            guard definition.firstMatch(in: block.text, range: NSRange(block.text.startIndex..., in: block.text)) == nil,
                  definition.firstMatch(in: edit.text, range: NSRange(edit.text.startIndex..., in: edit.text)) == nil,
                  !edit.text.contains("\u{0000}") else { throw Failure("Citation definitions cannot be edited by packet output.") }
            doc.replaceCharacters(in: NSRange(location: block.start, length: block.length), with: edit.text)
        }
        for (sourceID, receipt) in zip(selected, receipts) {
            let media = URL(fileURLWithPath: receipt.file)
            guard let current = RecallSidecar.load(forRecordingURL: media), SecretaryBookkeeping.digest(current.data) == receipt.sha256,
                  NoteFingerprint.read(forRecordingURL: media).text == receipt.text,
                  NoteFingerprint.read(forRecordingURL: media).analysis == receipt.analysis else { throw Failure("Packet source changed while model was working (\(sourceID)); nothing applied.") }
        }
        let queueURL = task.workspace.root.appendingPathComponent("secretary/review_queue.md")
        let registryURL = task.workspace.document.deletingPathExtension().appendingPathExtension("sources.json")
        guard try Data(contentsOf: task.workspace.document) == documentData, try Data(contentsOf: registryURL) == registryData,
              ((try? Data(contentsOf: queueURL)) ?? Data()) == queueData else { throw Failure("Packet workspace changed while model was working; nothing applied.") }
        // Validate statuses/duplicate targets before any workspace mutation.
        let rowByID: [String: [String: Any]]
        if let validationRows { rowByID = validationRows }
        else {
            let original = try JSONSerialization.jsonObject(with: registryData) as! [String: Any]
            let rows = (original["sources"] as! [[String: Any]]) + newSources
            rowByID = Dictionary(uniqueKeysWithValues: rows.map { ($0["source_id"] as! String, $0) })
        }
        let citation = try NSRegularExpression(pattern: #"\[(S[0-9]+)\]"#)
        for edit in edits {
            let text = edit.text as NSString
            for match in citation.matches(in: edit.text, range: NSRange(location: 0, length: text.length)) {
                guard rowByID[text.substring(with: match.range(at: 1))] != nil else { throw Failure("Packet edit invented an unknown S citation.") }
            }
        }
        var issues: [DecisionIssue] = []
        for (id, receipt) in zip(selected, receipts) {
            do {
                _ = try SecretaryRegistryRevision.revised(rowByID[id]!, decision: plan.sourceDecisions.first { $0.source == id }!, receipt: receipt, task: task, known: Set(rowByID.keys))
            } catch {
                issues.append(DecisionIssue(source: id, message: error.localizedDescription))
            }
        }
        if !issues.isEmpty { throw InvalidDecisions(issues: issues) }
        if validateOnly {
            return SecretaryResult(summary: plan.summary, reviewedSources: [], sourceDecisions: plan.sourceDecisions, changedFiles: [], questions: plan.questions)
        }
        let directory = task.workspace.runDirectory(task.id)
        for receipt in receipts { try receipt.append(to: SecretaryReadReceipt.logURL(runID: task.id, store: marks)) }
        if !FileManager.default.fileExists(atPath: directory.appendingPathComponent(SecretaryRegistryRevision.snapshotName).path) {
            try SecretaryRegistryRevision.snapshot(registryData, directory: directory)
        }
        try queueData.write(to: directory.appendingPathComponent("packet-queue-before.md"), options: .atomic)
        if !newSources.isEmpty {
            try Self.addingSources(newSources, data: registryData).write(to: registryURL, options: .atomic)
        }
        if doc as String != String(decoding: documentData, as: UTF8.self) {
            try Data((doc as String).utf8).write(to: task.workspace.document, options: .atomic)
        }
        if !plan.questions.isEmpty {
            let queue = String(decoding: queueData, as: UTF8.self)
            let regex = try NSRegularExpression(pattern: #"\bQ([0-9]+)\b"#)
            let ns = queue as NSString
            var number = regex.matches(in: queue, range: NSRange(location: 0, length: ns.length)).compactMap { Int(ns.substring(with: $0.range(at: 1))) }.max() ?? 0
            let questions = plan.questions.map { question -> String in number += 1; return "- Q\(number). \(question.replacingOccurrences(of: "\n", with: " "))" }.joined(separator: "\n")
            let marker = "## Открытые вопросы"
            let revised: String
            if let range = queue.range(of: marker) {
                let suffix = String(queue[range.upperBound...])
                let end = suffix.range(of: "\n## ")?.lowerBound ?? suffix.endIndex
                let body = String(suffix[..<end])
                let existing = body.trimmingCharacters(in: .whitespacesAndNewlines) == "Нет." ? "\n\n" : body
                revised = String(queue[..<range.upperBound]) + "\n\n" + questions + "\n" + existing + String(suffix[end...])
            }
            else { revised = queue + "\n\n" + marker + "\n\n" + questions + "\n" }
            try Data(revised.utf8).write(to: queueURL, options: .atomic)
        }
        let logURL = task.workspace.root.appendingPathComponent("secretary/change_log.md")
        let log = (try? Data(contentsOf: logURL)) ?? Data()
        let line = "\n\(SecretaryClock.stamp(task.createdAt)) · \(task.id) · packet · \(selected.joined(separator: ", ")) · \(plan.summary.replacingOccurrences(of: "\n", with: " "))\n"
        try (log + Data(line.utf8)).write(to: logURL, options: .atomic)
        return SecretaryResult(summary: plan.summary, reviewedSources: [], sourceDecisions: plan.sourceDecisions,
            changedFiles: [task.workspace.doc, "secretary/change_log.md"] + (plan.questions.isEmpty ? [] : ["secretary/review_queue.md"]), questions: plan.questions)
    }

    static func addingSources(_ added: [[String: Any]], data: Data) throws -> Data {
        let patch = try SecretaryJSONPatch(data), members = try patch.members(0..<data.count)
        let range = members.first { $0.key == "sources" }!.value
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let rows = root["sources"] as! [[String: Any]]
        var counts = root["counts"] as! [String: Int]; counts["pending", default: 0] += added.count
        let addition = try added.map { String(decoding: try SecretaryJSONPatch.encode($0, indent: 4), as: UTF8.self) }.joined(separator: ",\n")
        var edits: [(Range<Int>, Data)] = [(range.upperBound - 1..<range.upperBound - 1, Data(((rows.isEmpty ? "" : ",") + "\n" + addition + "\n").utf8))]
        for (key, value) in [("source_count", rows.count + added.count as Any), ("counts", counts as Any)] {
            edits.append((members.first { $0.key == key }!.value, try SecretaryJSONPatch.encode(value)))
        }
        return try patch.applying(edits)
    }
}
