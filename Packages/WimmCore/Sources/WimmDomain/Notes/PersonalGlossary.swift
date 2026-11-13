import Foundation

/// What a personal term names. Drives the placeholder type when the term is
/// masked before a cloud call (`⟦P3⟧` person, `⟦O1⟧` org, `⟦L2⟧` place).
public enum PersonalGlossaryKind: String, Codable, CaseIterable, Sendable {
    case person, org, place, other

    /// Unknown values (written by a newer build) read as `.other` instead of
    /// making the whole glossary file unreadable.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PersonalGlossaryKind(rawValue: raw) ?? .other
    }
}

public struct PersonalGlossaryTerm: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var canonical: String
    public var context: String
    public var observedForms: [String]
    public var isEnabled: Bool
    public var sourceNoteID: UUID?
    public var confirmedAt: Date
    /// Optional; files written before 2026-10-19 have no kind.
    public var kind: PersonalGlossaryKind?
    /// Masked before cloud calls in private mode and never sent in
    /// `note.glossary` there. Absent in older files, read as `false`.
    public var sensitive: Bool

    public init(id: UUID = UUID(), canonical: String = "", context: String = "",
                observedForms: [String] = [], isEnabled: Bool = true,
                sourceNoteID: UUID? = nil, confirmedAt: Date = Date(),
                kind: PersonalGlossaryKind? = nil, sensitive: Bool = false) {
        self.id = id
        self.canonical = canonical
        self.context = context
        self.observedForms = observedForms
        self.isEnabled = isEnabled
        self.sourceNoteID = sourceNoteID
        self.confirmedAt = confirmedAt
        self.kind = kind
        self.sensitive = sensitive
    }

    private enum CodingKeys: String, CodingKey {
        case id, canonical, context, observedForms, isEnabled, sourceNoteID, confirmedAt, kind, sensitive
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        canonical = try c.decode(String.self, forKey: .canonical)
        context = try c.decode(String.self, forKey: .context)
        observedForms = try c.decode([String].self, forKey: .observedForms)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        sourceNoteID = try c.decodeIfPresent(UUID.self, forKey: .sourceNoteID)
        confirmedAt = try c.decode(Date.self, forKey: .confirmedAt)
        kind = try c.decodeIfPresent(PersonalGlossaryKind.self, forKey: .kind)
        sensitive = try c.decodeIfPresent(Bool.self, forKey: .sensitive) ?? false
    }

    /// Omits the new keys while unset, so a file without them re-saves the way
    /// an older build wrote it.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(canonical, forKey: .canonical)
        try c.encode(context, forKey: .context)
        try c.encode(observedForms, forKey: .observedForms)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encodeIfPresent(sourceNoteID, forKey: .sourceNoteID)
        try c.encode(confirmedAt, forKey: .confirmedAt)
        try c.encodeIfPresent(kind, forKey: .kind)
        if sensitive { try c.encode(true, forKey: .sensitive) }
    }
}

public struct PersonalGlossaryDocument: Codable, Equatable, Sendable {
    public var schema = "PersonalGlossary@v1"
    public var revision = 0
    public var includeBundledTerms = true
    public var terms: [PersonalGlossaryTerm] = []
    public init() {}
}
