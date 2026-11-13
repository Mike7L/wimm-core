import AppKit
import SwiftUI
import WimmDocumentUI
import WimmDomain
import WimmInfrastructure

struct StudioTimelineView: View {
    let notes: [StudioLibraryNote]
    let revision: UInt64
    let document: PersonalDocument?
    let revealNoteID: UUID?
    let onOpenNote: (StudioLibraryNote) -> Void

    @AppStorage("WimmStudio.timelineZoom") private var zoomRaw = StudioTimeline.Zoom.week.rawValue
    @AppStorage("WimmStudio.timelineCitedOnly") private var citedOnly = false
    @State private var timeline: StudioTimeline?
    @State private var openGroupID: String?

    private var zoom: StudioTimeline.Zoom { .init(rawValue: zoomRaw) ?? .week }
    private var citedNames: Set<String> { document.map(StudioTimeline.citedMetadataNames) ?? [] }

    private struct TaskKey: Equatable {
        let revision: UInt64
        let count: Int
        let newest: UUID?
        let zoom: StudioTimeline.Zoom
        let cited: Set<String>
        let citedOnly: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            legend
            Divider()
            if let timeline {
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: zoom == .day ? 3 : 5, pinnedViews: [.sectionHeaders]) {
                        ForEach(sectionRuns(timeline.buckets), id: \.start) { run in
                            Section {
                                ForEach(run.buckets) { bucket in
                                    bucketRow(bucket, maxMinutes: timeline.longestBucketMinutes)
                                }
                            } header: {
                                if let start = run.start {
                                    sectionHeader(start, buckets: run.buckets)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .padding(.top, zoom.sectionComponent == nil ? 10 : 0)
                }
                .onChange(of: revealNoteID) { _, id in
                    guard let id, let bucket = timeline.buckets.first(where: { $0.segments.contains { $0.id == id } }) else { return }
                    withAnimation { proxy.scrollTo(bucket.id, anchor: .center) }
                }
                }
            } else {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        .task(id: TaskKey(revision: revision, count: notes.count, newest: notes.last?.id, zoom: zoom, cited: citedNames, citedOnly: citedOnly)) {
            let notes = notes, zoom = zoom, cited = citedNames, citedOnly = citedOnly
            timeline = await Task.detached(priority: .userInitiated) {
                StudioTimeline(notes: notes, zoom: zoom, citedMetadataNames: cited, citedOnly: citedOnly)
            }.value
        }
    }

    private var header: some View {
        HStack {
            Picker("", selection: $zoomRaw) {
                ForEach(StudioTimeline.Zoom.allCases, id: \.rawValue) { z in
                    Text(z.label).tag(z.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ForEach(StudioTimeline.Kind.allCases, id: \.self) { kind in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(color(for: kind)).frame(width: 9, height: 9)
                        Text(kind.rawValue.capitalized)
                    }
                }
            }
            if let timeline {
                HStack {
                    Text("Cited: \(timeline.citedCount) / \(timeline.totalCount)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.primary)
                    Spacer()
                    Toggle("Cited only", isOn: $citedOnly)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                }
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var barHeight: CGFloat {
        switch zoom {
        case .day: 12
        case .week: 16
        case .month: 22
        case .year: 28
        }
    }

    private struct SectionRun {
        let start: Date?
        let buckets: [StudioTimeline.Bucket]
    }

    private func sectionRuns(_ buckets: [StudioTimeline.Bucket]) -> [SectionRun] {
        var runs: [SectionRun] = []
        for bucket in buckets {
            if let last = runs.last, last.start == bucket.section {
                runs[runs.count - 1] = SectionRun(start: last.start, buckets: last.buckets + [bucket])
            } else {
                runs.append(SectionRun(start: bucket.section, buckets: [bucket]))
            }
        }
        return runs
    }

    private func sectionHeader(_ start: Date, buckets: [StudioTimeline.Bucket]) -> some View {
        let total = buckets.reduce(0) { $0 + $1.segments.count }
        let cited = buckets.reduce(0) { $0 + $1.citedCount }
        let style: Date.FormatStyle = zoom == .month ? .dateTime.year() : .dateTime.month(.wide).year()
        return HStack(alignment: .firstTextBaseline) {
            Text(start.formatted(style))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
            Text("\(cited)/\(total)")
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(cited > 0 ? .primary : .tertiary)
        }
        .padding(.top, 10)
        .padding(.bottom, 3)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.95))
    }

    private func bucketRow(_ bucket: StudioTimeline.Bucket, maxMinutes: Double) -> some View {
        HStack(spacing: 6) {
            Text(bucketLabel(bucket.start))
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
                .lineLimit(1)

            GeometryReader { geo in
                let individual = zoom.showsIndividualNotes && CGFloat(bucket.segments.count) * 4 - 1 <= geo.size.width
                let count = individual ? bucket.segments.count : bucket.groups.count
                let floor: CGFloat = individual ? 3 : 4
                let available = max(0, geo.size.width - CGFloat(max(0, count - 1)))
                let target = max(CGFloat(count) * floor, maxMinutes > 0 ? available * bucket.minutes / maxMinutes : 0)
                let unit = bucket.minutes > 0 ? max(0, target - CGFloat(count) * floor) / bucket.minutes : 0
                HStack(spacing: 1) {
                    // Dense buckets cannot offer one useful 3pt target per note. Use the
                    // existing groups and their lazy note picker instead of clipped thousands of views.
                    if individual {
                        ForEach(bucket.segments) { seg in
                            Button { activate(seg) } label: {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(color(for: seg.kind).opacity(seg.isCited ? 1.0 : 0.24))
                                    .overlay {
                                        if revealNoteID == seg.id {
                                            RoundedRectangle(cornerRadius: 2).stroke(Color.accentColor, lineWidth: 2)
                                        }
                                    }
                                    .frame(width: floor + seg.minutes * unit)
                                    .contentShape(Rectangle())
                            }
                                .buttonStyle(.plain)
                                .help("\(seg.note.studioTitle) (\(String(format: "%.1f", seg.minutes))m)")
                        }
                    } else {
                        ForEach(bucket.groups) { group in
                            let groupKey = "\(bucket.id.timeIntervalSince1970)-\(group.id)"
                            RoundedRectangle(cornerRadius: 3)
                                .fill(color(for: group.kind).opacity(group.isCited ? 1.0 : 0.24))
                                .frame(width: floor + group.minutes * unit)
                                .overlay {
                                    if group.segments.contains(where: { revealNoteID == $0.id }) {
                                        RoundedRectangle(cornerRadius: 3).stroke(Color.accentColor, lineWidth: 2)
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if group.segments.count == 1 {
                                        activate(group.segments[0])
                                    } else {
                                        openGroupID = groupKey
                                    }
                                }
                                .popover(isPresented: Binding(
                                    get: { openGroupID == groupKey },
                                    set: { if !$0 { openGroupID = nil } }
                                ), arrowEdge: .leading) {
                                    groupPopover(group, label: bucketLabel(bucket.start))
                                }
                        }
                    }
                }
                .frame(width: geo.size.width, alignment: .leading)
                .clipped()
            }
            .frame(height: barHeight)

            Text("\(bucket.citedCount)/\(bucket.segments.count)")
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(bucket.citedCount > 0 ? .primary : .tertiary)
                .frame(width: 42, alignment: .trailing)
        }
        .id(bucket.id)
    }

    private func groupPopover(_ group: StudioTimeline.Group, label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(label) · \(group.kind.rawValue.capitalized) (\(group.segments.count))")
                .font(.system(size: 11, weight: .semibold))
                .padding(10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(group.segments.reversed()) { seg in
                        Button {
                            openGroupID = nil
                            activate(seg)
                        } label: {
                            HStack(spacing: 8) {
                                Text(seg.note.studioTitle)
                                    .lineLimit(1)
                                Spacer()
                                if seg.isCited {
                                    Image(systemName: "text.alignleft")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                    }
                }
            }
            .frame(maxHeight: 280)
        }
        .frame(width: 280)
    }

    private func activate(_ segment: StudioTimeline.Segment) {
        onOpenNote(segment.note)
    }

    private func color(for kind: StudioTimeline.Kind) -> Color {
        switch kind {
        case .voice: .red
        case .text: .blue
        case .pdf: .green
        case .image: .orange
        }
    }

    private func bucketLabel(_ date: Date) -> String {
        switch zoom {
        case .day: date.formatted(.dateTime.day().month(.abbreviated))
        case .week: date.formatted(.dateTime.day().month(.abbreviated))
        case .month: date.formatted(.dateTime.month(.abbreviated).year(.twoDigits))
        case .year: date.formatted(.dateTime.year())
        }
    }
}
