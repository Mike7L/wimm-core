import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WimmDomain
import WimmInfrastructure

/// The whole evening note at once ("Вся заметка"): the day on an hourly scale
/// on the left, the note on the right — prepared "День", two questions,
/// "Мысли". The conversation (`EveningWizardView`) is the default face of
/// the window; both share the root's recorder and photos.
struct EveningView: View {
    @Bindable var model: EveningModel
    let recentNotes: RecentNotes
    let capture: CaptureSession
    let onOpenNote: (URL) -> Void
    let onFilesAdded: ([URL]) -> Void
    let recorder: EveningVoiceRecorder
    let photos: EveningPhotos
    var onConversation: (() -> Void)?
    @State private var hovered: String?
    @State private var isEditingDigest = false
    @State private var skipped: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                EveningHourScale(model: model, hovered: $hovered, onOpen: openMetadata, onDropFiles: dropFiles)
                    .frame(width: 150)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        photoStrip
                        digestSection
                        ForEach(model.prompts.filter { !skipped.contains($0) || !model.body(of: $0).isEmpty }, id: \.self) { prompt in
                            answerSection(prompt, skippable: true)
                        }
                        answerSection(EveningJournal.thoughtsHeading, skippable: false)
                        if let error = model.errorMessage ?? recorder.errorMessage ?? photos.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 560)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text(model.document.title).font(.title2.weight(.semibold))
            Text("· \(model.dayNotes.count) записей").foregroundStyle(.secondary)
            Spacer()
            if let onConversation {
                Button { onConversation() } label: { Label("К разговору", systemImage: "bubble.left") }
                    .disabled(recorder.phase == .starting || recorder.phase == .finishing)
            }
            if let closed = model.closedAt {
                Label("День закрыт в \(closed.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
            Button("Открыть заметку") { if let file = model.file { onOpenNote(file) } }
                .disabled(model.file == nil)
            Button(model.closedAt == nil ? "Закрыть день" : "Сохранить") {
                Task { await model.closeDay() }
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    // MARK: - Photos

    @ViewBuilder private var photoStrip: some View {
        switch photos.access {
        case .denied:
            HStack {
                Text("Нет доступа к Фото — можно перетащить снимки на шкалу слева.").foregroundStyle(.secondary)
                Button("Разрешить доступ к Фото") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
                }
            }.font(.callout)
        case .unknown:
            EmptyView()
        case .granted where photos.candidates.isEmpty:
            EmptyView()
        case .granted:
            VStack(alignment: .leading, spacing: 8) {
                Text("ФОТО ЗА ДЕНЬ · нажмите, чтобы добавить").font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(photos.candidates) { candidate in
                            photoTile(candidate)
                        }
                    }
                }
            }
        }
    }

    private func photoTile(_ candidate: EveningPhotos.Candidate) -> some View {
        Button {
            Task {
                if let url = await photos.add(candidate) { onFilesAdded([url]) }
            }
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let image = candidate.thumbnail {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
                .frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 6))
                .opacity(candidate.isAdded ? 0.45 : 1)
                if candidate.isAdded {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .green).padding(4)
                } else if photos.importing.contains(candidate.id) {
                    ProgressView().controlSize(.small).padding(4)
                }
            }
            .overlay(alignment: .topLeading) {
                Text(candidate.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption2).padding(2).background(.black.opacity(0.4)).foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 3)).padding(3)
            }
        }
        .buttonStyle(.plain)
        .disabled(candidate.isAdded)
        .help(candidate.isAdded ? "Уже в дне" : "Добавить в день")
    }

    // MARK: - Digest

    private var digestSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(EveningJournal.digestHeading).font(.title3.weight(.semibold))
                if model.isDigestUntouched {
                    Text("черновик").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !model.isDigestUntouched {
                    Button("Собрать заново") { model.rebuildDigest() }.buttonStyle(.link)
                }
                Button(isEditingDigest ? "Готово" : "Править") { isEditingDigest.toggle() }.buttonStyle(.link)
            }
            if isEditingDigest {
                TextEditor(text: Binding(get: { model.digestBody },
                                         set: { model.setBody($0, of: EveningJournal.digestHeading) }))
                    .font(.system(size: 13, design: .monospaced))
                    .frame(minHeight: 160)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            } else if model.digestBody.isEmpty {
                Text("Сегодня записей нет.").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(model.digestBody.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                        digestLine(line)
                    }
                }
            }
            let missing = model.missingLines
            if !missing.isEmpty {
                Button("+\(missing.count) \(missing.count == 1 ? "запись" : "записей") после правки — добавить") {
                    model.addMissingLines()
                }.buttonStyle(.link).font(.callout)
            }
        }
    }

    private func digestLine(_ line: String) -> some View {
        let names = EveningJournal.linkedMetadataNames(in: line)
        let isHovered = hovered.map { names.contains($0) } ?? false
        let text = line.hasPrefix("- ") ? String(line.dropFirst(2)) : line
        let attributed = (try? AttributedString(markdown: text)) ?? AttributedString(text)
        return Text(attributed)
            .foregroundStyle(model.isDigestUntouched ? .secondary : .primary)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(isHovered ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .onHover { inside in hovered = inside ? names.first : (isHovered ? nil : hovered) }
            .environment(\.openURL, OpenURLAction { url in
                openMetadata(url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent)
                return .handled
            })
    }

    // MARK: - Questions

    private func answerSection(_ heading: String, skippable: Bool) -> some View {
        let isThisRecording = recorder.isRecording && recorder.prompt == heading
        return VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Text(heading).font(.title3.weight(.semibold))
                Spacer()
                Button {
                    Task { await toggleRecording(heading) }
                } label: {
                    Label(isThisRecording ? "Стоп" : "Надиктовать",
                          systemImage: isThisRecording ? "stop.circle.fill" : "mic")
                }
                .tint(isThisRecording ? .red : nil)
                .disabled(capture.isRecording || recorder.phase == .starting || recorder.phase == .finishing
                          || (recorder.isRecording && !isThisRecording))
                .help(capture.isRecording ? "Идёт запись в HUD" : "Ответ голосом: текст встанет сюда, аудио сохранится во вложении")
                if skippable && model.body(of: heading).isEmpty {
                    Button("Пропустить") { skipped.insert(heading) }
                        .disabled(isThisRecording)
                }
            }
            ForEach(model.answerAudio.filter { $0.prompt == heading }, id: \.url) { item in
                StudioNoteAudioPlayer(url: item.url)
            }
            TextEditor(text: Binding(get: { model.body(of: heading) },
                                     set: { model.setBody($0, of: heading) }))
                .font(.system(size: 15))
                .frame(minHeight: heading == EveningJournal.thoughtsHeading ? 140 : 70)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            if isThisRecording {
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                        .scaleEffect(1 + CGFloat(recorder.level))
                        .padding(.top, 5)
                    Text(recorder.liveText.isEmpty ? "Слушаю…" : recorder.liveText)
                        .foregroundStyle(.secondary).italic()
                }
            }
        }
    }

    private func toggleRecording(_ heading: String) async {
        if recorder.isRecording {
            await finishRecording()
            return
        }
        do {
            _ = try model.ensureFile()
            await recorder.start(prompt: heading, audioURL: try EveningJournalStore.newAnswerAudioURL())
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func finishRecording() async {
        guard let result = await recorder.stop() else { return }
        model.attachAnswer(audio: result.url, text: result.text, prompt: result.prompt)
        await model.saveNow()
    }

    // MARK: - Links and drops

    private func openMetadata(_ name: String) {
        let url = FileStore.recordingsDirectory().appendingPathComponent(name)
        if let note = StudioNoteLink.resolve(url, in: recentNotes.notesByURLPath) {
            onOpenNote(note.fileURL)
        }
    }

    private func dropFiles(_ urls: [URL], at date: Date) {
        let added = urls.filter { AttachmentType(fromExtension: $0.pathExtension) == .image }
            .compactMap { photos.addFile($0, fallbackDate: date) }
        if !added.isEmpty { onFilesAdded(added) }
    }
}

// MARK: - Hour scale

/// One evening from 04:00 to 04:00, an hour per row; each note sits at its
/// minute, notes that would overlap move to the next lane.
struct EveningHourScale: View {
    let model: EveningModel
    @Binding var hovered: String?
    let onOpen: (String) -> Void
    let onDropFiles: ([URL], Date) -> Void
    static let hourHeight: CGFloat = 40
    private let firstHour = 6
    @State private var dropY: CGFloat?

    private struct Mark: Identifiable {
        let note: EveningJournal.DayNote
        let y: CGFloat
        let height: CGFloat
        let lane: Int
        var id: String { note.metadataName }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        ForEach(hours, id: \.self) { hour in
                            HStack(alignment: .top, spacing: 4) {
                                Text(String(format: "%02d", hour % 24)).font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary).frame(width: 18, alignment: .trailing)
                                Rectangle().fill(.quaternary).frame(height: 0.5).padding(.top, 6)
                            }
                            .frame(height: Self.hourHeight, alignment: .top)
                            .id(hour)
                        }
                    }
                    ForEach(marks) { mark in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color(mark.note.kind))
                            .frame(width: 16, height: mark.height)
                            .overlay(RoundedRectangle(cornerRadius: 2)
                                .stroke(Color.accentColor, lineWidth: hovered == mark.id ? 2 : 0))
                            .offset(x: 28 + CGFloat(mark.lane) * 19, y: mark.y + 6)
                            .onHover { hovered = $0 ? mark.id : (hovered == mark.id ? nil : hovered) }
                            .onTapGesture { onOpen(mark.id) }
                            .help("\(mark.note.date.formatted(date: .omitted, time: .shortened)) — \(mark.note.title)")
                    }
                    if let dropY {
                        RoundedRectangle(cornerRadius: 4).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                            .frame(width: 90, height: 18).offset(x: 28, y: dropY)
                            .overlay(Text("фото").font(.caption2).offset(x: 28, y: dropY))
                    }
                }
                .padding(.vertical, 10).padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onDrop(of: [.fileURL], delegate: HourDrop(scale: self, dropY: $dropY))
            }
            .onAppear {
                // Hours after midnight are 24…27 on this scale.
                var first = model.dayNotes.first.map { Calendar.current.component(.hour, from: $0.date) } ?? 18
                if first < EveningJournal.dayStartHour { first += 24 }
                proxy.scrollTo(min(max(firstHour, first - 1), hours.last ?? first), anchor: .top)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
    }

    private var hours: [Int] { Array(firstHour..<(24 + EveningJournal.dayStartHour)) }

    private var scaleStart: Date {
        Calendar.current.date(byAdding: .hour, value: firstHour - EveningJournal.dayStartHour, to: model.interval.start)
            ?? model.interval.start
    }

    private func y(for date: Date) -> CGFloat {
        CGFloat(max(0, date.timeIntervalSince(scaleStart)) / 3600) * Self.hourHeight
    }

    func date(at y: CGFloat) -> Date {
        let seconds = max(0, Double(y - 10)) / Double(Self.hourHeight) * 3600
        return min(model.interval.end.addingTimeInterval(-60), scaleStart.addingTimeInterval(seconds))
    }

    private var marks: [Mark] {
        var laneEnds: [CGFloat] = []
        return model.dayNotes.map { note in
            let top = y(for: note.date)
            let height = max(6, min(CGFloat(note.minutes / 60) * Self.hourHeight, Self.hourHeight * 2))
            let lane = laneEnds.firstIndex { $0 <= top } ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(0) }
            laneEnds[lane] = top + height + 1
            return Mark(note: note, y: top, height: height, lane: min(lane, 5))
        }
    }

    private func color(_ kind: EveningJournal.DayNote.Kind) -> Color {
        switch kind {
        case .voice: .red
        case .text: .blue
        case .pdf: .green
        case .image: .orange
        }
    }
}

private struct HourDrop: DropDelegate {
    let scale: EveningHourScale
    @Binding var dropY: CGFloat?

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dropY = info.location.y - 10
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) { dropY = nil }

    func performDrop(info: DropInfo) -> Bool {
        let date = scale.date(at: info.location.y)
        dropY = nil
        let providers = info.itemProviders(for: [.fileURL])
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await Self.loadURL(provider) { urls.append(url) }
            }
            scale.onDropFiles(urls, date)
        }
        return !providers.isEmpty
    }

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }
}
