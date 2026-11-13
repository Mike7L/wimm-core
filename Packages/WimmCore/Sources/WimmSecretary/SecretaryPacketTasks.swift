import Foundation
import WimmInfrastructure

extension SecretaryPacket {
    struct WorkTask: Codable {
        let id: String
        let state: String
        let sources: [String]
        let dependsOn: [String]
        let readBlocks: [String]
        let edits: [Edit]
        let questions: [String]
        let needsContext: [String]
        let reason: String
        enum CodingKeys: String, CodingKey {
            case id, state, sources, edits, questions, reason
            case dependsOn = "depends_on", readBlocks = "read_blocks", needsContext = "needs_context"
        }

        init(id: String, state: String, sources: [String], dependsOn: [String], readBlocks: [String],
             edits: [Edit], questions: [String], needsContext: [String], reason: String) {
            self.id = id; self.state = state; self.sources = sources; self.dependsOn = dependsOn
            self.readBlocks = readBlocks; self.edits = edits; self.questions = questions
            self.needsContext = needsContext; self.reason = reason
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            state = try c.decodeIfPresent(String.self, forKey: .state) ?? "ready"
            sources = try c.decode([String].self, forKey: .sources)
            dependsOn = try c.decodeIfPresent([String].self, forKey: .dependsOn) ?? []
            edits = try c.decodeIfPresent([Edit].self, forKey: .edits) ?? []
            readBlocks = try c.decodeIfPresent([String].self, forKey: .readBlocks) ?? Array(Set(edits.map(\.block))).sorted()
            questions = try c.decodeIfPresent([String].self, forKey: .questions) ?? []
            needsContext = try c.decodeIfPresent([String].self, forKey: .needsContext) ?? []
            reason = try c.decode(String.self, forKey: .reason)
        }
    }

    struct TaskReport: Codable {
        struct Source: Codable {
            let id: String
            let file: String
            let sha256: String
            let text: String
            let analysis: String
        }
        let id: String
        var state: String
        var reason: String
        let sources: [Source]
        let dependsOn: [String]
        let needsContext: [String]
        /// Exact stale versions to re-read; nil for legacy reports and other validation failures.
        var staleSources: [String]? = nil
        /// References its edits removed from the document (logged, not blocking); nil when none.
        var droppedReferences: [String]? = nil
    }

    struct TaskResolution {
        let packet: SecretaryPacket
        let plan: Plan
        var reports: [TaskReport]
        /// Listed-but-unadmitted (blocked/held) sources whose decisions were dropped.
        var ignoredSources: [String] = []
        var readyCount: Int { reports.filter { $0.state == "ready" }.count }
    }

    /// Sources the input names in blocked_sources/held_sources but never admits. A decision about
    /// one cannot be acknowledged, so it is dropped instead of failing the whole response; any
    /// other unknown source still fails validation. A task left with no admitted source may not
    /// carry edits or questions, since those would rest on text that was never supplied.
    func withoutUnadmittedDecisions(_ plan: Plan) throws -> (plan: Plan, ignored: [String]) {
        let listed = ["blocked_sources", "held_sources", "no_text_sources", "viewing_sources", "skipped_sources", "unfinished_sources"].flatMap { (payload[$0] as? [[String: String]] ?? []).compactMap { $0["source"] } }
        let unadmitted = Set(listed).subtracting(selected)
        let ignored = Set(plan.sourceDecisions.map(\.source) + (plan.tasks ?? []).flatMap(\.sources)).intersection(unadmitted)
        guard !ignored.isEmpty else { return (plan, []) }
        var tasks: [WorkTask]?
        if let work = plan.tasks {
            tasks = try work.compactMap { item in
                let kept = item.sources.filter { !unadmitted.contains($0) }
                if !kept.isEmpty {
                    return WorkTask(id: item.id, state: item.state, sources: kept, dependsOn: item.dependsOn, readBlocks: item.readBlocks,
                                    edits: item.edits, questions: item.questions, needsContext: item.needsContext, reason: item.reason)
                }
                guard item.edits.isEmpty, item.questions.isEmpty else {
                    throw Failure("Task \(item.id) edits or asks about sources that were not supplied: \(item.sources.joined(separator: ", ")).")
                }
                return nil
            }
        }
        var cleaned = Plan(summary: plan.summary, sourceDecisions: plan.sourceDecisions.filter { !unadmitted.contains($0.source) },
                           edits: plan.edits, questions: plan.questions, needsContext: plan.needsContext)
        cleaned.needsImages = plan.needsImages; cleaned.tasks = tasks; cleaned.readRequests = plan.readRequests
        return (cleaned, ignored.sorted())
    }

    func selectingSources(_ ids: Set<String>, keepingNewSources: Set<String> = []) -> SecretaryPacket {
        let pairs = zip(selected, receipts).filter { ids.contains($0.0) }
        return SecretaryPacket(task: task, documentData: documentData, registryData: registryData, queueData: queueData,
            blocks: blocks, selected: pairs.map(\.0), receipts: pairs.map(\.1),
            projectedSourceIDs: projectedSourceIDs.filter { ids.contains($0) },
            newSources: newSources.filter { ids.contains($0["source_id"] as? String ?? "") || keepingNewSources.contains($0["source_id"] as? String ?? "") },
            fullSourcesByID: fullSourcesByID.filter { ids.contains($0.key) }, payload: payload, system: system, hostAnchors: hostAnchors)
    }

    /// No writes here. Every proposed independent task passes the existing complete validator.
    /// Deferred sources receive no receipt/registry acknowledgement or agent mark.
    func resolveTasks(_ plan: Plan, prompt: String, marks: AgentMarkStore) throws -> TaskResolution {
        var (plan, ignored) = try withoutUnadmittedDecisions(plan)
        // Top-level context requests beside tasks belong to the deferred work: hand them to it
        // instead of rejecting the whole envelope (a real Haiku pass, 2026-10-31).
        if var work = plan.tasks, !plan.needsContext.isEmpty, plan.edits.isEmpty, plan.questions.isEmpty,
           let i = work.firstIndex(where: { $0.state == "deferred" }) {
            let item = work[i]
            work[i] = WorkTask(id: item.id, state: item.state, sources: item.sources, dependsOn: item.dependsOn, readBlocks: item.readBlocks,
                               edits: item.edits, questions: item.questions,
                               needsContext: Array((item.needsContext + plan.needsContext.map { String($0.prefix(200)) }).prefix(5)), reason: item.reason)
            var moved = Plan(summary: plan.summary, sourceDecisions: plan.sourceDecisions, edits: [], questions: [], needsContext: [])
            moved.needsImages = plan.needsImages; moved.tasks = work; moved.readRequests = plan.readRequests
            plan = moved
        }
        // Sources in no task stay unacknowledged and return in the next pass.
        // A deferral that asks for nothing and changes nothing is a pending/noise verdict: recording it
        // lets the queue move on. Unrecorded, the same sources came back eight passes in a row.
        let status = Dictionary(plan.sourceDecisions.map { ($0.source, $0.status) }, uniquingKeysWith: { first, _ in first })
        plan.tasks = plan.tasks?.map { item in
            guard item.state == "deferred", item.needsContext.isEmpty, item.dependsOn.isEmpty, item.edits.isEmpty, item.questions.isEmpty,
                  item.sources.allSatisfy({ ["pending", "failed", "noise"].contains(status[$0] ?? "") }) else { return item }
            return WorkTask(id: item.id, state: "ready", sources: item.sources, dependsOn: [], readBlocks: item.readBlocks,
                            edits: [], questions: [], needsContext: [], reason: "Pending recorded: " + item.reason)
        }
        guard let work = plan.tasks, !work.isEmpty, work.count <= selected.count,
              plan.edits.isEmpty, plan.questions.isEmpty, plan.needsContext.isEmpty,
              (plan.needsImages ?? []).isEmpty else { throw Failure("Invalid or mixed task envelope.") }
        let taskIDs = work.map(\.id), sourceIDs = work.flatMap(\.sources), decisionIDs = plan.sourceDecisions.map(\.source)
        guard Set(taskIDs).count == work.count, taskIDs.allSatisfy({ !$0.isEmpty && $0.count <= 80 }),
              Set(sourceIDs).isSubset(of: Set(selected)), Set(sourceIDs).count == sourceIDs.count,
              Set(decisionIDs).isSubset(of: Set(selected)), Set(decisionIDs).count == decisionIDs.count else {
            throw Failure("Tasks and decisions must name supplied sources at most once each.")
        }
        let allowed = Set((try JSONSerialization.jsonObject(with: Data(prompt.utf8)) as! [String: Any])["document_blocks"]
            .flatMap { $0 as? [[String: Any]] }?.compactMap { $0["id"] as? String } ?? [])
        for item in work {
            guard ["ready", "deferred"].contains(item.state), !item.sources.isEmpty,
                  !item.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, item.reason.count <= 4000,
                  Set(item.dependsOn).count == item.dependsOn.count,
                  item.needsContext.count <= 5, item.needsContext.allSatisfy({ !$0.isEmpty && $0.count <= 200 }),
                  item.state != "deferred" || (item.edits.isEmpty && item.questions.isEmpty) else {
                throw Failure("Invalid task declaration: \(item.id).")
            }
        }
        // Parse the large registry once for preflight; the actual write path always reloads
        // and validates its own rows. Temporary Foundation objects are released per task.
        let registry = try JSONSerialization.jsonObject(with: registryData) as! [String: Any]
        let rows = (registry["sources"] as! [[String: Any]]) + newSources
        let validationRows = Dictionary(uniqueKeysWithValues: rows.map { ($0["source_id"] as! String, $0) })
        let decisions = Dictionary(uniqueKeysWithValues: plan.sourceDecisions.map { ($0.source, $0) })
        let sourceOwner = Dictionary(uniqueKeysWithValues: work.flatMap { item in item.sources.map { ($0, item.id) } })
        let receiptByID = Dictionary(uniqueKeysWithValues: zip(selected, receipts))
        var reports = work.map { item in TaskReport(id: item.id, state: item.state,
            reason: item.reason, sources: item.sources.map { TaskReport.Source(id: $0, file: receiptByID[$0]!.file, sha256: receiptByID[$0]!.sha256, text: receiptByID[$0]!.text, analysis: receiptByID[$0]!.analysis) },
            dependsOn: item.dependsOn, needsContext: item.needsContext) }
        func taskPlan(_ item: WorkTask) -> Plan {
            Plan(summary: String(item.reason.prefix(1800)), sourceDecisions: item.sources.map { decisions[$0]! }, edits: item.edits,
                 questions: item.questions, needsContext: item.needsContext)
        }
        for (i, item) in work.enumerated() where item.state == "ready" {
            do {
                // A source the model forgot to decide cannot be acknowledged; only its task waits
                // (one omission used to fail a whole 45-source packet).
                let undecided = item.sources.filter { decisions[$0] == nil }
                guard undecided.isEmpty else { throw Failure("No source decision for \(undecided.joined(separator: ", ")).") }
                guard Set(item.readBlocks).isSubset(of: allowed), Set(item.readBlocks).count == item.readBlocks.count else {
                    throw Failure("Task relies on unavailable or duplicate document blocks.")
                }
                _ = try autoreleasepool {
                    try selectingSources(Set(item.sources)).apply(taskPlan(item), prompt: prompt, marks: marks, validateOnly: true,
                        validationRows: validationRows, validationBlocks: allowed)
                }
            }
            catch {
                reports[i].state = "deferred"
                reports[i].reason = "Validation blocked: \(error.localizedDescription)"
                reports[i].staleSources = selectingSources(Set(item.sources)).staleSourceIDs()
            }
            if reports[i].state == "ready", let edits = try? materializedEdits(item.edits, allowed: allowed) {
                let dropped = droppedReferences(edits)
                reports[i].droppedReferences = dropped.isEmpty ? nil : dropped
            }
        }
        // Conflicting replacements and undeclared read/write coupling cannot be safely separated.
        for i in work.indices where reports[i].state == "ready" {
            for j in work.indices where j > i && reports[j].state == "ready" {
                let left = Set(work[i].edits.map(\.block)), right = Set(work[j].edits.map(\.block))
                if !left.isDisjoint(with: right) || !left.isDisjoint(with: work[j].readBlocks) || !right.isDisjoint(with: work[i].readBlocks) {
                    reports[i].state = "deferred"; reports[j].state = "deferred"
                    reports[i].reason = "Overlapping task blocks; combine tasks before applying."
                    reports[j].reason = reports[i].reason
                }
            }
        }
        var questionCount = 0
        for i in work.indices where reports[i].state == "ready" {
            if questionCount + work[i].questions.count > 20 {
                reports[i].state = "deferred"; reports[i].reason = "Combined question limit exceeded; task retained for another pass."
            } else { questionCount += work[i].questions.count }
        }
        // Reject dependency cycles; a dependency must eventually reach a task without dependencies.
        var resolved = Set<String>()
        var progress = true
        while progress {
            progress = false
            for (i, item) in work.enumerated() where reports[i].state == "ready" && !resolved.contains(item.id) {
                if Set(item.dependsOn).isSubset(of: resolved) { resolved.insert(item.id); progress = true }
            }
        }
        for i in work.indices where reports[i].state == "ready" && !resolved.contains(work[i].id) {
            reports[i].state = "deferred"; reports[i].reason = "Unresolved or cyclic task dependency."
        }
        // A new citation/merge target owned by deferred work must not leak into a ready task.
        progress = true
        let oldBlocks = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0.text) })
        while progress {
            progress = false
            let ready = Set(reports.filter { $0.state == "ready" }.map(\.id))
            for (i, item) in work.enumerated() where reports[i].state == "ready" {
                var referenced = Set(item.sources.flatMap { decisions[$0]?.mergedWith ?? [] })
                for edit in item.edits { referenced.formUnion(Self.contextIDs(edit.text).subtracting(Self.contextIDs(oldBlocks[edit.block] ?? ""))) }
                let missing = item.dependsOn.contains { !ready.contains($0) } || referenced.contains { sourceOwner[$0].map { !ready.contains($0) } ?? false }
                if missing { reports[i].state = "deferred"; reports[i].reason = "Depends on deferred source/task work."; progress = true }
            }
        }
        let ready = Set(reports.filter { $0.state == "ready" }.map(\.id))
        let admitted = work.filter { ready.contains($0.id) }
        let ids = Set(admitted.flatMap(\.sources))
        // The model's overall summary includes proposed work, including tasks rejected above.
        // Report only admitted work; never repeat claims about an edit that was deferred.
        let summary = "Задач в проверенном результате: \(admitted.count); отложено: \(work.count - admitted.count). "
            + String(admitted.map { String($0.reason.prefix(300)) }.joined(separator: " ").prefix(1600))
        let merged = Plan(summary: summary, sourceDecisions: plan.sourceDecisions.filter { ids.contains($0.source) },
            edits: admitted.flatMap(\.edits), questions: admitted.flatMap(\.questions), needsContext: [])
        let packet = selectingSources(ids)
        _ = try packet.apply(merged, prompt: prompt, marks: marks, validateOnly: true,
            validationRows: validationRows, validationBlocks: allowed)
        return TaskResolution(packet: packet, plan: merged, reports: reports, ignoredSources: ignored)
    }
}

extension SecretaryPacket {

}
