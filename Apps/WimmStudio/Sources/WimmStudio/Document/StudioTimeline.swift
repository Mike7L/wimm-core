import Foundation
import WimmDomain
import WimmInfrastructure

/// Library timeline alongside the document, with calibrated reading speed
/// (700 chars/min) and a 10-second duration for images without text.
struct StudioTimeline: Sendable {
    enum Zoom: Int, CaseIterable, Comparable, Sendable {
        case day, week, month, year

        var label: String {
            switch self {
            case .day: "Day"
            case .week: "Week"
            case .month: "Month"
            case .year: "Year"
            }
        }

        var component: Calendar.Component {
            switch self {
            case .day: .day
            case .week: .weekOfYear
            case .month: .month
            case .year: .year
            }
        }

        var sectionComponent: Calendar.Component? {
            switch self {
            case .day, .week: .month
            case .month: .year
            case .year: nil
            }
        }

        var showsIndividualNotes: Bool { self <= .week }

        static func < (lhs: Zoom, rhs: Zoom) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    enum Kind: String, CaseIterable, Sendable {
        case voice, text, pdf, image

        static func classify(_ note: Note) -> Kind {
            let ext = note.fileURL.pathExtension.lowercased()
            if FileStore.isAudioFile(note.fileURL) { return .voice }
            if ext == "pdf" { return .pdf }
            if ["heic", "jpg", "jpeg", "png", "gif", "webp", "tiff"].contains(ext) { return .image }
            return .text
        }
    }

    struct Segment: Identifiable, Sendable {
        let note: StudioLibraryNote
        let kind: Kind
        let minutes: Double
        let isCited: Bool
        var id: UUID { note.id }
    }

    struct Group: Identifiable, Sendable {
        let kind: Kind
        let isCited: Bool
        let segments: [Segment]
        var id: String { "\(kind.rawValue)-\(isCited)" }
        var minutes: Double { segments.reduce(0) { $0 + $1.minutes } }
    }

    struct Bucket: Identifiable, Sendable {
        let start: Date
        let section: Date?
        let segments: [Segment]
        let groups: [Group]
        var id: Date { start }
        var minutes: Double { segments.reduce(0) { $0 + $1.minutes } }
        var citedCount: Int { segments.filter(\.isCited).count }
    }

    /// Calibrated reading speed: 700 characters per minute (~110–120 words/min).
    static let charactersPerMinute = 700.0
    /// A picture without text is 10 seconds (`10 / 60` of a minute).
    static let textlessImageMinutes = 10.0 / 60.0
    /// Minimum clickable floor for tiny text notes (10 seconds).
    static let minimumMinutes = 10.0 / 60.0

    let buckets: [Bucket]
    let longestBucketMinutes: Double
    let totalCount: Int
    let citedCount: Int

    init(notes: [StudioLibraryNote], zoom: Zoom, citedMetadataNames: Set<String> = [],
         citedOnly: Bool = false, calendar: Calendar = .current) {
        var grouped: [Date: [Segment]] = [:]
        var citedTotal = 0
        for note in notes {
            let cited = note.metadataURL.map { citedMetadataNames.contains($0.lastPathComponent) } ?? false
            if cited { citedTotal += 1 }
            if citedOnly && !cited { continue }
            guard let start = calendar.dateInterval(of: zoom.component, for: note.absoluteDate)?.start else { continue }
            let kind = note.kind
            grouped[start, default: []].append(Segment(
                note: note, kind: kind, minutes: note.minutes, isCited: cited))
        }
        buckets = grouped.map { start, segments in
            let ordered = segments.sorted {
                $0.isCited != $1.isCited ? $0.isCited : $0.note.absoluteDate < $1.note.absoluteDate
            }
            var groups: [Group] = []
            for isCited in [true, false] {
                for kind in Kind.allCases {
                    let items = ordered.filter { $0.isCited == isCited && $0.kind == kind }
                    if !items.isEmpty { groups.append(Group(kind: kind, isCited: isCited, segments: items)) }
                }
            }
            let section = zoom.sectionComponent.flatMap { calendar.dateInterval(of: $0, for: start)?.start }
            return Bucket(start: start, section: section, segments: ordered, groups: groups)
        }.sorted { $0.start > $1.start }
        longestBucketMinutes = buckets.map(\.minutes).max() ?? 0
        totalCount = notes.count
        citedCount = citedTotal
    }

    static func minutes(of note: Note, kind: Kind? = nil) -> Double {
        let resolvedKind = kind ?? Kind.classify(note)
        if note.duration > 0 {
            return max(minimumMinutes, note.duration / 60.0)
        }
        let body = (note.refinedText ?? note.text).trimmingCharacters(in: .whitespacesAndNewlines)
        if resolvedKind == .image && body.isEmpty {
            return textlessImageMinutes
        }
        return max(minimumMinutes, Double(body.count) / charactersPerMinute)
    }

    static func citedMetadataNames(in document: PersonalDocument) -> Set<String> {
        Set(document.blocks.flatMap { document.sources(in: $0) }
            .map { ($0.target as NSString).lastPathComponent }
            .filter { $0.hasSuffix(".meta.json") })
    }

    static func citingBlock(for note: StudioLibraryNote, in document: PersonalDocument) -> PersonalDocument.Block? {
        guard let name = note.metadataURL?.lastPathComponent else { return nil }
        return document.blocks.first { block in
            document.sources(in: block).contains { ($0.target as NSString).lastPathComponent == name }
        }
    }
}
