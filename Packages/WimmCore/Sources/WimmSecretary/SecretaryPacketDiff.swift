import Foundation

extension SecretaryPacket {
    /// The document text the accepted edits produce, for a dry-run diff; the same splice as `apply`.
    func renderedDocument(_ edits: [Edit], allowed: Set<String>) throws -> String {
        let byID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        let doc = NSMutableString(string: String(decoding: documentData, as: UTF8.self))
        for edit in try materializedEdits(edits, allowed: allowed.union(hostAnchors)).sorted(by: { byID[$0.block]!.start > byID[$1.block]!.start }) {
            doc.replaceCharacters(in: NSRange(location: byID[edit.block]!.start, length: byID[edit.block]!.length), with: edit.text)
        }
        return doc as String
    }

    /// Unified line diff with three lines of context, for the user's review only.
    static func unifiedDiff(_ before: String, _ after: String, name: String) -> String {
        func lines(_ s: String) -> [String] { s.components(separatedBy: "\n") }
        let a = lines(before), b = lines(after)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in b.difference(from: a) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        guard !removed.isEmpty || !inserted.isEmpty else { return "" }
        // (kind, old index, new index) for every line of the merged script.
        var script: [(Character, Int, Int)] = [], i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) { script.append(("-", i, j)); i += 1 }
            else if j < b.count, inserted.contains(j) { script.append(("+", i, j)); j += 1 }
            else if i < a.count, j < b.count { script.append((" ", i, j)); i += 1; j += 1 }
            else { break }
        }
        let changed = script.indices.filter { script[$0].0 != " " }
        var out = "--- a/\(name)\n+++ b/\(name)\n", k = 0
        while k < changed.count {
            let lower = max(0, changed[k] - 3)
            var upper = min(script.count - 1, changed[k] + 3)
            while k + 1 < changed.count, changed[k + 1] - 3 <= upper + 1 { k += 1; upper = min(script.count - 1, changed[k] + 3) }
            let hunk = script[lower...upper]
            let oldCount = hunk.filter { $0.0 != "+" }.count, newCount = hunk.filter { $0.0 != "-" }.count
            out += "@@ -\(hunk.first!.1 + (oldCount > 0 ? 1 : 0)),\(oldCount) +\(hunk.first!.2 + (newCount > 0 ? 1 : 0)),\(newCount) @@\n"
            for (kind, oi, nj) in hunk { out += String(kind) + (kind == "+" ? b[nj] : a[oi]) + "\n" }
            k += 1
        }
        return out
    }
}

extension SecretaryPacket.EditsReply {
    init(summary: String, edits: [SecretaryPacket.EditOperation], done: [SecretaryPacket.DoneEntry],
         unfinished: [SecretaryPacket.UnfinishedEntry], questions: [String], readSections: [String],
         notANote: [SecretaryPacket.DoneEntry] = []) {
        self.summary = summary; self.edits = edits; self.done = done; self.unfinished = unfinished
        self.notANote = notANote
        self.questions = questions; self.readSections = readSections
        self.statusUpdates = []
    }
}
