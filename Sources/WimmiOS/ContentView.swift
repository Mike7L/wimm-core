#if os(iOS)
    import SwiftUI
    import PhotosUI
    import UniformTypeIdentifiers
    import VisionKit
    import WimmDomain
    import WimmInfrastructure

    struct ContentView: View {
        @EnvironmentObject var appState: AppState
        @State private var showRecoveryAlert = false
        @State private var searchText = ""
        @State private var showNewTextNote = false
        @State private var showSettings = false
        @State private var showQueue = false
        @State private var editMode: EditMode = .inactive
        @State private var selection: Set<String> = []

        var body: some View {
            NavigationStack {
                RecordingsList(searchText: searchText, selection: $selection)
                    .environment(\.editMode, $editMode)
                    .navigationTitle(L10n.iOS.Root.title)
                    .navigationBarTitleDisplayMode(.large)
                    .searchable(
                        text: $searchText,
                        placement: .navigationBarDrawer(displayMode: .automatic),
                        prompt: Text(L10n.iOS.List.searchPrompt)
                    )
                    .overlay {
                        if appState.isLoading && appState.recordings.isEmpty {
                            ProgressView(L10n.iOS.Root.loading)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(.regularMaterial)
                        }
                    }
                    .fullScreenCover(isPresented: $appState.showCapture) {
                        SketchCaptureView(audioRecorder: appState.audioRecorder)
                            .environmentObject(appState)
                    }
                    .sheet(isPresented: $showNewTextNote) {
                        NewTextNoteView()
                            .environmentObject(appState)
                    }
                    .alert(L10n.iOS.Success.recoveryComplete, isPresented: $showRecoveryAlert) {
                        Button(L10n.Common.ok, role: .cancel) {}
                    } message: {
                        Text(appState.recoveryMessage ?? "")
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        HomeCaptureBar(showNewTextNote: $showNewTextNote)
                    }
                    .refreshable {
                        await appState.syncNow(fullScan: true)
                        await appState.loadRecordings()
                    }
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button(editMode.isEditing ? L10n.Common.done : L10n.iOS.Reprocess.select) {
                                withAnimation {
                                    editMode = editMode.isEditing ? .inactive : .active
                                    selection = []
                                }
                            }
                        }
                        if editMode.isEditing {
                            ToolbarItem(placement: .navigationBarLeading) {
                                BulkRetranscribeMenu(
                                    urls: selectedAudioURLs,
                                    queue: appState.processingQueue
                                ) {
                                    editMode = .inactive
                                    selection = []
                                    showQueue = true
                                }
                            }
                        }
                        ToolbarItem(placement: .navigationBarTrailing) {
                            NavigationLink {
                                IOSPersonalDocumentView()
                            } label: {
                                Image(systemName: "doc.richtext")
                            }
                            .accessibilityLabel(L10n.PersonalDocument.title)
                        }
                        ToolbarItem(placement: .navigationBarTrailing) {
                            ProcessingQueueButton(queue: appState.processingQueue) {
                                showQueue = true
                            }
                        }
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button {
                                showSettings = true
                            } label: {
                                Image(systemName: "gearshape")
                            }
                            .accessibilityLabel(L10n.iOS.Settings.title)
                        }
                    }
                    .sheet(isPresented: $showSettings) {
                        ModelSettingsView()
                    }
                    .sheet(isPresented: $showQueue) {
                        ProcessingQueueView(queue: appState.processingQueue)
                            .environmentObject(appState)
                    }
                    .onReceive(appState.$recoveryMessage) { message in
                        if message != nil {
                            showRecoveryAlert = true
                        }
                    }
            }
            .tint(.red)
        }
    }

    extension ContentView {
        /// Selected audio notes, in list order.
        fileprivate var selectedAudioURLs: [URL] {
            appState.recordings
                .filter { selection.contains($0.id) && $0.mediaKind == .audio }
                .map(\.fileURL)
        }
    }

    /// "Transcribe again" for the notes picked in selection mode. The jobs go
    /// into the shared processing queue, which runs one at a time.
    private struct BulkRetranscribeMenu: View {
        let urls: [URL]
        @ObservedObject var queue: ProcessingQueue
        let onQueued: () -> Void

        var body: some View {
            Menu {
                Button(L10n.iOS.Reprocess.retranscribe) { enqueue(.transcribe) }
                Button(L10n.iOS.Reprocess.retranscribeOnDevice) { enqueue(.transcribeLocal) }
                if !PrivateMode.isEnabled, let cloud = TranscriptKind.cloud.retranscriptionModel() {
                    Button(L10n.iOS.Reprocess.retranscribeCloud(cloud)) { enqueue(.transcribeCloud) }
                }
            } label: {
                Label(L10n.iOS.Reprocess.selected(urls.count), systemImage: "waveform.badge.magnifyingglass")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(urls.isEmpty)
        }

        private func enqueue(_ kind: ProcessingJobKind) {
            queue.enqueue(urls, kind: kind)
            queue.start()
            onQueued()
        }
    }

    struct RecordingsList: View {
        @EnvironmentObject var appState: AppState
        let searchText: String
        @Binding var selection: Set<String>

        @State private var groups: [RecordingDayGroup] = []
        @State private var isFiltered = false
        @State private var searchIndex = RecordingSearchIndex()

        private var refreshKey: RecordingsRefreshKey {
            RecordingsRefreshKey(
                query: RecordingSearchIndex.normalize(searchText),
                revision: appState.recordingsRevision
            )
        }

        /// Filtering and day grouping run in the index actor, never on the
        /// main thread; a newer keystroke cancels the older pass.
        private func refresh(_ key: RecordingsRefreshKey) async {
            if !key.query.isEmpty {
                try? await Task.sleep(for: .milliseconds(150))
                if Task.isCancelled { return }
            }
            let recordings = appState.recordings
            guard let result = await searchIndex.groups(
                recordings: recordings,
                revision: key.revision,
                query: key.query
            ), !Task.isCancelled else { return }
            groups = result
            isFiltered = !key.query.isEmpty
        }

        private func dayLabel(_ date: Date) -> String {
            let calendar = Calendar.current
            if calendar.isDateInToday(date) {
                return L10n.iOS.Day.today
            } else if calendar.isDateInYesterday(date) {
                return L10n.iOS.Day.yesterday
            } else {
                return date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
            }
        }

        var body: some View {
            List(selection: $selection) {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.recordings) { recording in
                            NavigationLink {
                                RecordingDetailView(recording: recording)
                            } label: {
                                RecordingRow(recording: recording)
                            }
                            .contextMenu {
                                ShareLink(item: recording.fileURL)
                                Button(role: .destructive) {
                                    let state = appState
                                    Task {
                                        await state.deleteRecording(recording)
                                    }
                                } label: {
                                    Label(L10n.Common.delete, systemImage: "trash")
                                }
                            }
                        }
                        .onDelete { indexSet in
                            let state = appState
                            let recs = group.recordings
                            Task {
                                for index in indexSet {
                                    if index < recs.count {
                                        await state.deleteRecording(recs[index])
                                    }
                                }
                            }
                        }
                    } header: {
                        Text(dayLabel(group.id))
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                            .textCase(nil)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .task(id: refreshKey) { await refresh(refreshKey) }
            .overlay {
                if isFiltered && groups.isEmpty && !appState.recordings.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else if appState.recordings.isEmpty {
                    ContentUnavailableView(
                        L10n.iOS.List.emptyTitle,
                        systemImage: "mic.circle",
                        description: Text(L10n.iOS.List.emptyDescription)
                    )
                }
            }
        }
    }

    struct RecordingRow: View {
        let recording: Recording

        private var kind: NoteMediaKind {
            recording.mediaKind
        }

        private var iconName: String {
            switch kind {
            case .audio: return "waveform"
            case .pdf: return "doc.text.fill"
            case .image: return "photo.fill"
            case .text: return "text.alignleft"
            case .document: return "doc.fill"
            }
        }

        private var iconColor: Color {
            switch kind {
            case .audio: return .red
            case .pdf: return .blue
            case .image: return .purple
            case .text: return .indigo
            case .document: return .gray
            }
        }

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                if kind == .image {
                    NoteThumbnailView(url: recording.fileURL, side: 40)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(iconColor.opacity(0.12))
                            .frame(width: 40, height: 40)
                        Image(systemName: iconName)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(iconColor)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(titleText)
                        .font(.headline)
                        .lineLimit(2)

                    if !subtitleText.isEmpty {
                        Text(subtitleText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    HStack(spacing: 8) {
                        Text(recording.timestamp, style: .time)
                            .font(.caption)
                            .foregroundStyle(.tertiary)

                        if kind == .audio, recording.durationSeconds > 0 {
                            Text(formatDurationShort(recording.durationSeconds))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.quaternary.opacity(0.5), in: Capsule())
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }

        private var titleText: String {
            recording.displayTitle
        }

        private var subtitleText: String {
            if let note = recording.note, !note.summary.isEmpty {
                return note.summary
            }
            return ""
        }

        private func formatDurationShort(_ seconds: Double) -> String {
            let totalSeconds = max(0, Int(seconds.rounded()))
            let hours = totalSeconds / 3600
            let minutes = (totalSeconds % 3600) / 60
            let secs = totalSeconds % 60

            if hours > 0 {
                return String(format: "%d:%02d:%02d", hours, minutes, secs)
            }
            if minutes > 0 {
                return String(format: "%d:%02d", minutes, secs)
            }
            return String(format: "0:%02d", secs)
        }
    }

    /// A compact action row that takes its own space below the note list.
    struct HomeCaptureBar: View {
        @EnvironmentObject var appState: AppState
        @Binding var showNewTextNote: Bool
        @State private var selectedItems: [PhotosPickerItem] = []
        @State private var showPhotosPicker = false
        @State private var showCamera = false
        @State private var showFileImporter = false
        @State private var showScanner = false
        @State private var scannedPDF: URL?
        @State private var showImportAlert = false
        @State private var alertMessage = ""

        private var importableTypes: [UTType] {
            var types: [UTType] = [.pdf, .image, .audio, .plainText]
            types.append(contentsOf: ["md", "docx", "doc"].compactMap { UTType(filenameExtension: $0) })
            return types
        }

        var body: some View {
            HStack(spacing: 0) {
                Menu {
                    Button {
                        if VNDocumentCameraViewController.isSupported {
                            showScanner = true
                        } else {
                            showAlert(message: L10n.iOS.Error.cameraUnavailable)
                        }
                    } label: {
                        Label(L10n.iOS.Capture.scanDocument, systemImage: "doc.viewfinder")
                    }

                    Button {
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            showCamera = true
                        } else {
                            showAlert(message: L10n.iOS.Error.cameraUnavailable)
                        }
                    } label: {
                        Label(L10n.iOS.Capture.takePhoto, systemImage: "camera")
                    }

                    Button {
                        showPhotosPicker = true
                    } label: {
                        Label(L10n.iOS.Capture.photos, systemImage: "photo.on.rectangle")
                    }

                    Button {
                        showFileImporter = true
                    } label: {
                        Label(L10n.iOS.Capture.attachFile, systemImage: "folder")
                    }
                } label: {
                    HomeToolIcon(systemName: "plus")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.iOS.Capture.addAttachment)
                .frame(maxWidth: .infinity)

                Button {
                    showNewTextNote = true
                } label: {
                    HomeToolIcon(systemName: "square.and.pencil")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.iOS.NewNote.title)
                .frame(maxWidth: .infinity)

                RecordButton {
                    appState.showCapture = true
                }
                .frame(maxWidth: .infinity)

                Button {
                    Task {
                        await pasteFromClipboard()
                    }
                } label: {
                    HomeToolIcon(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.iOS.Capture.paste)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: 420)
            .frame(height: 60)
            .frame(maxWidth: .infinity)
            .background {
                Color(.systemBackground)
                    .ignoresSafeArea(edges: .bottom)
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(.quaternary)
                    .frame(height: 0.5)
            }
            .photosPicker(isPresented: $showPhotosPicker, selection: $selectedItems, matching: .images)
            .onChange(of: selectedItems) { _, newItems in
                guard !newItems.isEmpty else { return }
                Task {
                    var loadedImages: [UIImage] = []
                    for item in newItems {
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let uiImage = UIImage(data: data) {
                            loadedImages.append(uiImage)
                        }
                    }
                    selectedItems.removeAll()
                    await appState.importImages(loadedImages)
                }
            }
            .sheet(isPresented: $showCamera) {
                CameraPicker { image in
                    if let image {
                        Task {
                            await appState.importImages([image])
                        }
                    }
                }
            }
            .fullScreenCover(isPresented: $showScanner) {
                DocumentScannerView(scannedPDF: $scannedPDF)
                    .ignoresSafeArea()
            }
            .onChange(of: scannedPDF) { _, newURL in
                guard let url = newURL else { return }
                scannedPDF = nil
                Task {
                    await appState.importScannedDocument(url)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: importableTypes,
                allowsMultipleSelection: true
            ) { result in
                guard case .success(let urls) = result else { return }
                Task {
                    let allSupported = await appState.importFiles(urls)
                    if !allSupported {
                        showAlert(message: L10n.iOS.Error.unsupportedFile)
                    }
                }
            }
            .alert(L10n.iOS.Error.unavailable, isPresented: $showImportAlert) {
                Button(L10n.Common.ok, role: .cancel) {}
            } message: {
                Text(alertMessage)
            }
        }

        private func pasteFromClipboard() async {
            let outcome = await appState.importPasteboard()
            switch outcome {
            case .imported:
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            case .empty:
                showAlert(message: L10n.iOS.Error.clipboardEmpty)
            }
        }

        private func showAlert(message: String) {
            alertMessage = message
            showImportAlert = true
        }
    }

    struct HomeToolIcon: View {
        let systemName: String

        var body: some View {
            Image(systemName: systemName)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .strokeBorder(.quaternary, lineWidth: 0.5)
                )
                .frame(width: 64, height: 60)
                .contentShape(Rectangle())
        }
    }

    struct RecordButton: View {
        let onTap: () -> Void

        var body: some View {
            Button(action: onTap) {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 56, height: 56)
                        .overlay(
                            Circle()
                                .strokeBorder(.quaternary, lineWidth: 0.5)
                        )
                    Circle()
                        .fill(Color.red.gradient)
                        .frame(width: 46, height: 46)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 64, height: 60)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.iOS.Capture.quickCapture)
        }
    }

    #Preview {
        ContentView()
            .environmentObject(AppState())
    }
#endif
