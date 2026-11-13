import Foundation
import WimmInfrastructure

public extension SecretaryCompletion {
    /// Packet edits are host-applied from validated replacements, so a packet run has nothing to score here.
    static func findings(task: SecretaryTask, backup: URL, store: AgentMarkStore = AgentMarkStore()) -> [String] {
        guard !task.packetMode else { return [] }
        let log = SecretaryReadReceipt.logURL(runID: task.id, store: store)
        var findings: [String] = []
        do {
            let sourceReads = try read(SecretaryReadReceipt.self, at: log)
            var latest: [String: SecretaryReadReceipt] = [:]
            for receipt in sourceReads { latest[receipt.sidecar] = receipt }
            for receipt in latest.values.sorted(by: { $0.file < $1.file }) where !receipt.allAvailableTextSupplied {
                findings.append("\(URL(fileURLWithPath: receipt.file).lastPathComponent): incomplete source coverage; use get_note with full: true.")
            }
            if task.kind == .pass {
                let receipts = try read(QueueReceipt.self, at: log.appendingPathExtension("queue"))
                if !receipts.contains(where: { $0.initial && $0.policy }) {
                    findings.append("Full pass did not check changed_notes with the required queue policy; queue coverage is unknown.")
                }
            }
            let before = try Data(contentsOf: backup), after = try Data(contentsOf: task.workspace.document)
            if before != after {
                let count = pages(before: before, after: after).count
                let receipts = try read(ReviewReceipt.self, at: log.appendingPathExtension("review"))
                let oldHash = digest(before), newHash = digest(after)
                let supplied = Set(receipts.filter { $0.before == oldHash && $0.after == newHash && $0.count == count }.map(\.page))
                if !Set(0..<count).isSubset(of: supplied) {
                    findings.append("Final document edits lack complete secretary_review_document coverage; reread every page after the last edit. Agent checks are self-reported.")
                }
            }
        } catch { findings.append("Cannot verify secretary completion: \(error.localizedDescription)") }
        return findings
    }
}
