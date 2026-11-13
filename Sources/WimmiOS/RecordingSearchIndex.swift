#if os(iOS)
    import Foundation

    struct RecordingDayGroup: Identifiable, Sendable {
        /// Start of the day; also the section identity.
        let id: Date
        let recordings: [Recording]
    }

    struct RecordingsRefreshKey: Equatable, Sendable {
        let query: String
        let revision: UInt64
    }

    /// The iPhone list's literal, case-insensitive search. Each recording's
    /// searchable fields are folded once per `recordingsRevision`, so a
    /// keystroke is a plain substring scan instead of a locale-aware compare
    /// of every note's full text on the main thread.
    actor RecordingSearchIndex {
        private var revision: UInt64?
        private var haystacks: [String] = []

        /// Same folding as Reader's `ReaderSearchCorpus.normalize`.
        nonisolated static func normalize(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased().precomposedStringWithCanonicalMapping
        }

        /// Fields joined by NUL so a query never matches across two fields.
        private static func haystack(for recording: Recording) -> String {
            var fields = [recording.titlePreview]
            if let note = recording.note {
                fields.append(note.summary)
                if let refined = note.refined_text { fields.append(refined) }
            }
            fields.append(recording.id)
            var folded = normalize(fields.joined(separator: "\u{0}"))
            folded.makeContiguousUTF8()
            return folded
        }

        /// Matching recordings grouped by day, newest day first, keeping the
        /// list's order inside a day. Nil when the caller's task was cancelled.
        func groups(recordings: [Recording], revision: UInt64, query: String) -> [RecordingDayGroup]? {
            let matches: [Recording]
            if query.isEmpty {
                matches = recordings
            } else {
                if self.revision != revision || haystacks.count != recordings.count {
                    var built: [String] = []
                    built.reserveCapacity(recordings.count)
                    for (index, recording) in recordings.enumerated() {
                        if index & 255 == 0, Task.isCancelled { return nil }
                        built.append(Self.haystack(for: recording))
                    }
                    haystacks = built
                    self.revision = revision
                }
                var found: [Recording] = []
                for (index, recording) in recordings.enumerated() {
                    if index & 255 == 0, Task.isCancelled { return nil }
                    if haystacks[index].contains(query) { found.append(recording) }
                }
                matches = found
            }
            if Task.isCancelled { return nil }
            let calendar = Calendar.current
            var order: [Date] = []
            var byDay: [Date: [Recording]] = [:]
            for recording in matches {
                let day = calendar.startOfDay(for: recording.timestamp)
                if byDay[day] == nil { order.append(day) }
                byDay[day, default: []].append(recording)
            }
            return order.sorted(by: >).map { RecordingDayGroup(id: $0, recordings: byDay[$0] ?? []) }
        }
    }
#endif
