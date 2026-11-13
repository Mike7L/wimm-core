import Foundation

extension SecretaryPacket {
    /// Route by primary speech/text and titles, not the incidental words of screen OCR.
    /// This only selects document context; no source evidence is removed.
    static func editorContext(blocks: [Block], sourceIDs: [String], primaryText: String,
                              limit: Int, requested: [String] = []) -> (blocks: [Block], report: [String: Any]) {
        let query = terms(primaryText)
        var chosen = Set<String>(), used = 0
        func admit(_ block: Block) -> Bool {
            if chosen.contains(block.id) { return true }
            guard !isDefinition(block.text), used + block.text.utf8.count <= limit else { return false }
            chosen.insert(block.id); used += block.text.utf8.count; return true
        }
        // Small orientation and required questions/basis must survive topic ranking.
        for block in blocks.prefix(6) { _ = admit(block) }
        if !requested.isEmpty {
            let selection = contextSelection(blocks: blocks, requests: Array(requested.prefix(5)), existing: chosen,
                                             limit: min(limit / 3, max(0, limit - used)))
            for block in selection.blocks { _ = admit(block) }
        }
        for (i, block) in blocks.enumerated() {
            guard let h = heading(block.text), ["вопросы и наблюдения для обсуждения", "основания и обновление документа"].contains(h.title) else { continue }
            _ = admit(block)
            for next in blocks.dropFirst(i + 1).prefix(3) { _ = admit(next) }
        }
        let starts = blocks.indices.filter { heading(blocks[$0].text)?.depth == 3 }
        var ranked: [(start: Int, end: Int, score: Int)] = []
        var groups: [(Int, Int, Set<String>)] = []
        for start in starts {
            var end = start + 1
            while end < blocks.count {
                if let h = heading(blocks[end].text), h.depth <= 3 { break }
                end += 1
            }
            groups.append((start, end, terms(blocks[start..<end].map(\.text).joined(separator: "\n"))))
        }
        var frequency: [String: Int] = [:]
        for (_, _, words) in groups { for word in words { frequency[word, default: 0] += 1 } }
        let specific = query.filter { frequency[$0, default: 0] <= max(2, groups.count / 5) }
        for (start, end, words) in groups {
            let title = terms(heading(blocks[start].text)!.title)
            let overlap = title.intersection(query).count
            let cited = blocks[start..<end].contains { b in sourceIDs.contains { b.text.contains("[\($0)]") } }
            let score = overlap * 100 + min(100, words.intersection(specific).count * 5) + (cited ? 1000 : 0)
            if score > 0 { ranked.append((start, end, score)) }
        }
        ranked.sort { $0.score == $1.score ? $0.start < $1.start : $0.score > $1.score }
        var reports: [[String: Any]] = []
        for section in ranked.prefix(5) {
            let members = Array(blocks[section.start..<section.end].filter { !isDefinition($0.text) })
            _ = admit(members[0])
            if members.count > 1 { _ = admit(members[1]) }
            let cost = members.filter { !chosen.contains($0.id) }.reduce(0) { $0 + $1.text.utf8.count }
            if cost <= limit - used {
                for block in members { _ = admit(block) }
            } else {
                let candidates = select(blocks: members, sourceIDs: sourceIDs, terms: query, limit: limit - used,
                                        excluding: chosen)
                for block in candidates { _ = admit(block) }
            }
            let missing = members.filter { !chosen.contains($0.id) }.map(\.id)
            reports.append(["section": blocks[section.start].id, "title": heading(blocks[section.start].text)!.line,
                            "complete": missing.isEmpty, "omitted_blocks": missing])
        }
        // Fill unused space with existing lexical/citation matching, using the same primary text.
        for block in select(blocks: blocks, sourceIDs: sourceIDs, terms: query, limit: max(0, limit - used), excluding: chosen) {
            _ = admit(block)
        }
        return (blocks.filter { chosen.contains($0.id) }, ["method": "primary_text_and_title_routing", "bytes": used,
            "budget_bytes": limit, "sections": reports, "scope": "selected_document_context; omissions are not evidence of absence"])
    }
}
