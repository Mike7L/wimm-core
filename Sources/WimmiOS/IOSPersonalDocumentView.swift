#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers
import WimmInfrastructure

/// A small reader over the personal document. By default it shows the copy the
/// Mac publishes through CloudKit (`PersonalDocumentSync`); a user-selected file,
/// including one in iCloud Drive, is the alternative. It never writes to either.
struct IOSPersonalDocumentView: View {
    @AppStorage("PersonalDocument.iOS.bookmark") private var bookmark: Data?
    /// "synced" (the Mac's copy) or "file" (the bookmark).
    @AppStorage("PersonalDocument.iOS.source") private var source = "synced"
    @Environment(\.scenePhase) private var scenePhase
    @State private var document: PersonalDocument?
    @State private var syncedAt: Date?
    @State private var choosingFile = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let document {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if source == "synced", let syncedAt {
                            Text(L10n.PersonalDocument.syncedFromMac(syncedAt.formatted(.relative(presentation: .named))))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(document.blocks) { block in
                            switch block.kind {
                            case .hidden:
                                EmptyView()
                            case .heading(let level):
                                Text(block.markdown.drop(while: { $0 == "#" || $0.isWhitespace }))
                                    .font(level == 1 ? .title.bold() : .title2.bold())
                                    .padding(.top, 8)
                            case .body:
                                Text((try? AttributedString(markdown: block.markdown,
                                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                                     ?? AttributedString(block.markdown))
                                    .font(.body)
                                    .lineSpacing(5)
                            }
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(20)
                    .frame(maxWidth: .infinity)
                }
                .refreshable { await load(refreshSynced: true) }
            } else if !isLoading {
                ContentUnavailableView {
                    Label(L10n.PersonalDocument.title, systemImage: "doc.richtext")
                } description: {
                    Text(source == "synced" ? L10n.PersonalDocument.notSyncedYet : L10n.PersonalDocument.chooseDescription)
                } actions: {
                    Button(L10n.PersonalDocument.choose) { choosingFile = true }
                }
            }
        }
        .navigationTitle(L10n.PersonalDocument.title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if isLoading { ProgressView() } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu(L10n.PersonalDocument.title, systemImage: "ellipsis.circle") {
                    Button(L10n.PersonalDocument.fromMac, systemImage: source == "synced" ? "checkmark" : "laptopcomputer") {
                        guard source != "synced" else { return }
                        source = "synced"
                        document = nil
                        Task { await load(refreshSynced: true) }
                    }
                    Button(L10n.PersonalDocument.choose, systemImage: source == "file" ? "checkmark" : "folder") { choosingFile = true }
                }
                .disabled(isLoading)
            }
        }
        .fileImporter(isPresented: $choosingFile,
                      allowedContentTypes: [UTType(filenameExtension: "md") ?? .plainText,
                                            UTType(filenameExtension: "markdown") ?? .plainText]) { result in
            switch result {
            case .success(let url): Task { await load(selectedURL: url) }
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .task { await load(refreshSynced: true) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await load(refreshSynced: true) } }
        }
        .alert(L10n.PersonalDocument.title, isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button(L10n.Common.ok, role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    /// The Mac's copy: show what the library holds at once, then ask the cloud
    /// for a newer one. Offline, the cached copy simply stays.
    @MainActor
    private func load(refreshSynced: Bool = false, selectedURL: URL? = nil) async {
        guard selectedURL == nil, source == "synced" else { return await loadFile(selectedURL: selectedURL) }
        guard !isLoading else { return }
        isLoading = document == nil
        defer { isLoading = false }
        let sync = PersonalDocumentSync.live()
        let cache = sync?.cache ?? PersonalDocumentSnapshotCache()
        showSynced(await Task.detached { cache.load() }.value)
        guard refreshSynced, let sync else { return }
        do {
            if try await sync.refresh() { showSynced(await Task.detached { cache.load() }.value) }
        } catch where document != nil {
            // A stale copy is still worth reading; the next sync retries.
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor
    private func showSynced(_ snapshot: (info: PersonalDocumentSnapshotInfo, text: String)?) {
        guard let snapshot else { return }
        document = PersonalDocument(text: snapshot.text)
        syncedAt = snapshot.info.publishedAt
    }

    @MainActor
    private func loadFile(selectedURL: URL?) async {
        guard !isLoading, selectedURL != nil || bookmark != nil else { return }
        isLoading = true
        defer { isLoading = false }
        let savedBookmark = bookmark
        do {
            let (loaded, updatedBookmark) = try await Task.detached(priority: .userInitiated) {
                var stale = false
                let url: URL
                if let selectedURL { url = selectedURL }
                else if let savedBookmark {
                    url = try URL(resolvingBookmarkData: savedBookmark, options: [],
                                  relativeTo: nil, bookmarkDataIsStale: &stale)
                } else { throw CocoaError(.fileNoSuchFile) }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                var coordinationError: NSError?
                var contents: Result<String, Error> = .failure(CocoaError(.fileReadUnknown))
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
                    contents = Result { try String(contentsOf: target, encoding: .utf8) }
                }
                if let coordinationError { throw coordinationError }
                let text = try contents.get()
                let data = try url.bookmarkData(options: .minimalBookmark,
                                                includingResourceValuesForKeys: nil, relativeTo: nil)
                return (PersonalDocument(text: text), data)
            }.value
            document = loaded
            bookmark = updatedBookmark
            source = "file"
            syncedAt = nil
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
}
#endif
