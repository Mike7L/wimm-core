import Foundation

/// Local inspection of what a private-mode analysis would send. Contains real
/// values (the legend), so it is for on-device display only: never log it,
/// never sync it.
public struct PrivateEgressPreview: Sendable {
    public struct LegendRow: Sendable, Identifiable, Equatable {
        /// Token id without brackets, e.g. `P3`.
        public let id: String
        public let kind: PseudonymKind
        public let detector: PseudonymDetector
        /// What a bare token unmasks to.
        public let value: String
        /// Other surface forms, in `:f1`, `:f2` order.
        public let forms: [String]
    }

    /// The system prompt, which is sent unmasked (it holds no note text).
    public let system: String
    /// Exactly the user payload egress would send (single-line JSON).
    public let maskedUser: String
    public let legend: [LegendRow]
    /// Token letters the outbound re-scan still finds; non-empty means the request would be blocked.
    public let blockedKinds: [String]
    /// Set when masking itself refuses (e.g. the note already contains ⟦ ⟧).
    public let refusal: String?
    /// Sensitive vocabulary terms in the mask dictionary (withheld from `note.glossary`).
    public let dictionaryTerms: Int

    init(system: String, inspection: PseudonymizedPayload.Inspection?, dictionaryTerms: Int, refusal: String?) {
        self.system = system
        self.maskedUser = inspection?.payload.user ?? ""
        self.blockedKinds = inspection?.leakKinds ?? []
        self.refusal = refusal
        self.dictionaryTerms = dictionaryTerms
        self.legend = (inspection?.payload.map.entries ?? [:])
            .map { LegendRow(id: $0.key, kind: $0.value.kind, detector: $0.value.detector,
                             value: $0.value.canonical, forms: $0.value.forms) }
            .sorted { ($0.kind.rawValue, Int($0.id.dropFirst()) ?? 0) < ($1.kind.rawValue, Int($1.id.dropFirst()) ?? 0) }
    }

    /// Would egress send this request?
    public var wouldSend: Bool { refusal == nil && blockedKinds.isEmpty }

    /// `note.text` (and `note.localHypothesis`) as sent, unescaped for reading.
    public var maskedNoteText: String {
        guard let object = PseudonymizedPayload.jsonObject(maskedUser) as? [String: Any],
              let note = object["note"] as? [String: Any] else { return maskedUser }
        var parts = [(note["text"] as? String) ?? ""]
        if let local = note["localHypothesis"] as? String, !local.isEmpty { parts.append(local) }
        return parts.joined(separator: "\n\n— local hypothesis —\n\n")
    }

    /// The same masked text for Reader/CLI display, without the context builder's
    /// main-text headers. Attachment labels stay so their provenance is visible.
    public var readableNoteText: String { Self.readable(maskedNoteText) }

    public static func readable(_ masked: String) -> String {
        let ns = masked as NSString
        return mainTextHeader.stringByReplacingMatches(
            in: masked, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let mainTextHeader = try! NSRegularExpression(
        pattern: #"^\[MAIN_TEXT(?:[ \t][^\]\n]*)?\][ \t]*\n?"#, options: [.anchorsMatchLines])

    /// The payload pretty-printed; same content as `maskedUser`.
    public var prettyMaskedUser: String {
        guard let object = PseudonymizedPayload.jsonObject(maskedUser),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return maskedUser }
        return String(decoding: data, as: UTF8.self)
    }
}
