import Foundation
import WimmDomain
import WimmInfrastructure

extension SecretaryPacket.Plan {
    // Read-only turns do not need provisional semantic decisions or edits.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        sourceDecisions = try c.decodeIfPresent([SecretaryResult.SourceDecision].self, forKey: .sourceDecisions) ?? []
        edits = try c.decodeIfPresent([SecretaryPacket.Edit].self, forKey: .edits) ?? []
        questions = try c.decodeIfPresent([String].self, forKey: .questions) ?? []
        needsContext = try c.decodeIfPresent([String].self, forKey: .needsContext) ?? []
        needsImages = try c.decodeIfPresent([String].self, forKey: .needsImages)
        tasks = try c.decodeIfPresent([SecretaryPacket.WorkTask].self, forKey: .tasks)
        readRequests = try c.decodeIfPresent([SecretaryPacket.ReadRequest].self, forKey: .readRequests)
    }
}

extension SecretaryPacket {

    struct ReadRequest: Codable {
        let id: String
        let operation: String
        let query: String
        let purpose: String
        var offset: Int? = nil
        /// Section only: the heading plus the last blocks that fit, instead of a page from `offset`.
        var tail: Bool? = nil
    }

    struct ReadTurn {
        let packet: SecretaryPacket
        let validationPrompt: String
        let reply: String
        let documentBytes: Int
    }

    func addressedRead(_ requests: [ReadRequest], validationPrompt: String, library: RecallLibrary,
                       marks: AgentMarkStore, sourceLimit: Int, documentLimit: Int,
                       includeExisting: Bool = false, outputLimit: Int = 24_000) throws -> ReadTurn {
        guard !PrivateMode.isEnabled else { throw SecretaryError.privateMode }
        try requireValidatedProjection()
        guard !requests.isEmpty, requests.count <= 5, Set(requests.map(\.id)).count == requests.count,
              requests.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 80 && $0.query.count <= 200
                && !$0.purpose.isEmpty && $0.purpose.count <= 500 && ($0.offset ?? 0) >= 0
                && ($0.tail != true || ($0.operation == "section" && ($0.offset ?? 0) == 0))
                && ($0.operation == "outline" || !$0.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                && ["find", "section", "source", "outline"].contains($0.operation) }) else {
            throw Failure("Invalid addressed read requests.")
        }
        guard var input = try JSONSerialization.jsonObject(with: Data(validationPrompt.utf8)) as? [String: Any],
              var supplied = input["document_blocks"] as? [[String: String]] else { throw Failure("Packet input has no document blocks.") }
        var seen = Set(supplied.compactMap { $0["id"] })
        var delta: [Block] = [], returned: [Block] = [], results: [[String: Any]] = [], bytes = 0
        var current = self
        let headerList = SecretaryDocumentReader.headingIndices(blocks).map {
            ["id": blocks[$0].id, "title": Self.heading(blocks[$0].text)!.line]
        }
        for request in requests {
            var result: [String: Any] = ["id": request.id, "operation": request.operation, "query": request.query]
            let remaining = max(0, min(outputLimit, includeExisting ? outputLimit : documentLimit - bytes))
            let startBytes = bytes
            switch request.operation {
            case "outline":
                let offset = min(request.offset ?? 0, headerList.count), end = min(offset + 40, headerList.count)
                result["status"] = "found"; result["headings"] = Array(headerList[offset..<end])
                result["total"] = headerList.count
                if end < headerList.count { result["next_offset"] = end }
            case "source":
                let admission = try current.admittingSource(request.query, library: library, marks: marks, sourceLimit: sourceLimit)
                current = admission.packet; result.merge(admission.result) { _, new in new }
            case "section":
                let matches = SecretaryDocumentReader.sectionMatches(blocks, query: request.query)
                if matches.count != 1 {
                    result["status"] = matches.isEmpty ? "not_found" : "ambiguous"
                    result["scope"] = "complete_document_headings"
                    result["matches"] = matches.map { ["id": blocks[$0].id, "title": Self.heading(blocks[$0].text)!.line] }
                } else if request.tail == true {
                    // Diary sections grow at the end: the heading plus the last blocks that fit, in
                    // document order. Same per-block budget rules as the forward page below.
                    let section = SecretaryDocumentReader.sectionBlocks(blocks, start: matches[0])
                    var planned = bytes, plannedSupplied = 0, first = section.count
                    func fits(_ block: Block) -> Bool {
                        let size = block.text.utf8.count, cost = seen.contains(block.id) ? 0 : size
                        if planned + cost > documentLimit || planned - startBytes + cost > remaining
                            || (includeExisting && plannedSupplied + size > remaining) { return false }
                        planned += cost; plannedSupplied += size
                        return true
                    }
                    let hasHeading = section.first.map(fits) ?? false
                    if hasHeading { while first > 1, fits(section[first - 1]) { first -= 1 } }
                    var ids: [String] = []
                    for block in (hasHeading ? [section[0]] : []) + section[min(max(first, 1), section.count)...] {
                        if !seen.contains(block.id) { delta.append(block); seen.insert(block.id); bytes += block.text.utf8.count }
                        if includeExisting { returned.append(block) }
                        ids.append(block.id)
                    }
                    let skipped = section.count - ids.count
                    result["status"] = skipped == 0 ? "complete" : "partial"
                    result["block_ids"] = ids; result["total_blocks"] = section.count
                    if skipped > 0 {
                        // Blocks 1..<tail_offset were left out; read them with --offset 1 if needed.
                        result["tail_offset"] = hasHeading ? first : section.count
                        result["skipped_blocks"] = skipped
                        if ids.count <= 1, let last = section.last { result["next_block_bytes"] = last.text.utf8.count }
                    }
                } else {
                    let section = SecretaryDocumentReader.sectionBlocks(blocks, start: matches[0])
                    let offset = min(request.offset ?? 0, section.count)
                    var next = offset, ids: [String] = [], suppliedBytes = 0
                    while next < section.count {
                        let block = section[next], cost = seen.contains(block.id) ? 0 : block.text.utf8.count
                        if bytes + cost > documentLimit || bytes - startBytes + cost > remaining
                            || (includeExisting && suppliedBytes + block.text.utf8.count > remaining) {
                            break
                        }
                        // Actual per-request admission is bounded below as well as by the run cap.
                        if !seen.contains(block.id) { delta.append(block); seen.insert(block.id); bytes += cost }
                        if includeExisting { returned.append(block); suppliedBytes += block.text.utf8.count }
                        ids.append(block.id); next += 1
                        if !includeExisting && bytes >= documentLimit { break }
                    }
                    result["status"] = next == section.count ? "complete" : "partial"
                    result["block_ids"] = ids; result["total_blocks"] = section.count
                    if next < section.count {
                        result["next_offset"] = next
                        result["next_block_bytes"] = section[next].text.utf8.count
                    }
                }
            default:
                let selection = Self.contextSelection(blocks: blocks, requests: [request.query], existing: includeExisting ? [] : seen, limit: remaining)
                for block in selection.blocks {
                    if !seen.contains(block.id) && bytes + block.text.utf8.count > documentLimit {
                        result["admission_budget_exhausted"] = true
                        continue
                    }
                    if includeExisting { returned.append(block) }
                    if !seen.contains(block.id) { delta.append(block); seen.insert(block.id); bytes += block.text.utf8.count }
                }
                result["status"] = selection.reports.first?.status ?? "not_found"
                result["scope"] = "complete_document_text_excluding_definitions"
                result["report"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(selection.reports))
            }
            results.append(result)
        }
        supplied += Self.objects(delta)
        input["document_blocks"] = supplied
        guard var sourceObjects = input["sources"] as? [[String: Any]] else { throw Failure("Packet input has no sources.") }
        let oldSources = Set(selected)
        for id in current.selected where !oldSources.contains(id) {
            sourceObjects.append(["source": id, "full_text": current.fullSourcesByID[id]!])
        }
        input["sources"] = sourceObjects; input["selected_count"] = current.selected.count
        let reply: [String: Any] = ["read_results": results, "document_blocks": Self.objects(includeExisting ? returned : delta),
            "admitted_source_ids": current.selected, "document_sha256": SecretaryBookkeeping.digest(documentData)]
        return ReadTurn(packet: current,
            validationPrompt: String(decoding: try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self),
            reply: String(decoding: try JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self), documentBytes: bytes)
    }

    private func admittingSource(_ id: String, library: RecallLibrary, marks: AgentMarkStore, sourceLimit: Int) throws -> (packet: SecretaryPacket, result: [String: Any]) {
        guard id.range(of: #"^S[0-9]+$"#, options: .regularExpression) != nil else {
            return (self, ["status": "invalid_source_id"])
        }
        if selected.contains(id) { return (self, ["status": "already_supplied", "source": id]) }
        guard let row = try SecretaryRegistry.parse(registryData).byID[id],
              let path = (row["path"] as? String)?.removingPercentEncoding else {
            return (self, ["status": "not_found", "scope": "registry_snapshot"])
        }
        guard !SecretaryBookkeeping.flag(row["removed_from_wimm"]), !SecretaryBookkeeping.flag(row["wimm_unindexed"]) else {
            return (self, ["status": "unavailable", "reason": "Source requires reconciliation."])
        }
        let target = task.workspace.document.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        let owned = task.workspace.root.appendingPathComponent("recordings").resolvingSymlinksInPath()
        guard SecretaryLibraryReconciliation.sameDirectory(target.deletingLastPathComponent(), owned) else {
            return (self, ["status": "outside_owned_library"])
        }
        guard let index = library.indexOfSidecar(matching: target) else {
            return (self, ["status": "unavailable", "reason": "No owned note matches this source."])
        }
        let server = MCPRecallServer(marks: marks, library: { library })
        let read = server.readNote(library[index], full: true, format: .secretaryPacket)
        guard let receipt = read.receipt, receipt.allAvailableTextSupplied else {
            return (self, ["status": "incomplete_coverage", "source": id])
        }
        let cost = read.text.utf8.count
        guard fullSourcesByID.values.reduce(0, { $0 + $1.utf8.count }) + cost <= sourceLimit else {
            return (self, ["status": "source_budget_exceeded", "source": id, "required_bytes": cost])
        }
        var sources = fullSourcesByID; sources[id] = read.text
        let packet = SecretaryPacket(task: task, documentData: documentData, registryData: registryData, queueData: queueData,
            blocks: blocks, selected: selected + [id], receipts: receipts + [receipt], projectedSourceIDs: projectedSourceIDs,
            newSources: newSources, fullSourcesByID: sources, payload: payload, system: system)
        return (packet, ["status": "supplied", "source": id, "full_text": read.text])
    }
}
