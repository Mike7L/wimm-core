import Foundation
import WimmInfrastructure

/// Lossless transport: byte-identical typed blocks share storage, not meaning.
struct SecretaryEvidencePool {
    private var keys: [Data: String] = [:]
    private(set) var texts: [[String: String]] = []
    private(set) var sources: [[String: Any]] = []
    private(set) var originalBytes = 0
    private(set) var uniqueBytes = 0

    mutating func append(source: String, header: String, blocks: [MCPRecallServer.EvidenceBlock],
                         receipt: SecretaryReadReceipt) throws -> SecretaryReadReceipt {
        guard let rendered = receipt.suppliedText, rendered.count == blocks.count,
              zip(rendered, blocks).allSatisfy({ $0.label == $1.label && $0.transcriptKind == $1.transcriptKind }),
              receipt.allAvailableTextSupplied else { throw SecretaryPacket.Failure("Evidence pool has incomplete rendered coverage.") }
        var references: [[String: Any]] = []
        var coverage: [SecretaryReadReceipt.TextCoverage] = []
        for (index, block) in blocks.enumerated() {
            let bytes = Data(block.text.utf8)
            originalBytes += bytes.count
            let duplicate = keys[bytes] != nil
            let key: String
            if let existing = keys[bytes] { key = existing }
            else {
                key = "e\(texts.count + 1)"; keys[bytes] = key
                texts.append(["id": key, "text": block.text]); uniqueBytes += bytes.count
            }
            var reference: [String: Any] = ["label": block.label, "text_ref": key]
            if let kind = block.transcriptKind { reference["transcript_kind"] = kind }
            if let words = block.words { reference["words"] = words }
            references.append(reference)
            coverage.append(.init(block: index, label: block.label, transcriptKind: block.transcriptKind,
                                  state: duplicate ? "duplicate" : "full"))
        }
        // Headers retain capture date, provenance, all ASR warnings and uncertainty.
        sources.append(["source": source, "metadata": header, "evidence": references])
        var supplied = receipt; supplied.suppliedText = coverage
        return supplied
    }

    var object: [String: Any] {
        ["version": 1, "sources": sources, "texts": texts,
         "original_block_bytes": originalBytes, "unique_block_bytes": uniqueBytes]
    }
}
