import SwiftUI
import WimmDomain
import WimmDocumentUI
import WimmInfrastructure

/// Resolve only this visible block's citations; never retain the entire full library.
struct StudioCitedImages: View {
    let sourceNames: [String]
    let notesByMetadataName: [String: StudioLibraryNote]
    let revision: UInt64
    let scale: CGFloat
    let onOpenNote: (StudioLibraryNote) -> Void
    struct ImageSource: Sendable {
        let url: URL
        let note: StudioLibraryNote
    }
    @State private var images: [ImageSource] = []
    private var entries: [StudioLibraryNote] {
        var seen: Set<URL> = []
        return sourceNames.compactMap { notesByMetadataName[$0] }.filter { seen.insert($0.fileURL).inserted }
    }
    var body: some View {
        Group { if !images.isEmpty {
            DocumentMediaGallery(urls: images.map(\.url), scale: scale, onOpen: { url in
                if let source = images.first(where: { $0.url == url }) { onOpenNote(source.note) }
            })
        } }
            .task(id: "\(revision)|\(sourceNames.joined(separator: ","))") {
                let entries = entries
                let result = await Task.detached(priority: .utility) {
                    let metadata = MetadataRepository(), transcripts = TranscriptRepository()
                    var images: [ImageSource] = [], seen: Set<URL> = []
                    for entry in entries {
                        guard !Task.isCancelled else { break }
                        let file = entry.fileURL
                        let note = await NoteBuilder.build(file: file, index: 0, metaRepo: metadata,
                                                           transcriptRepo: transcripts, includeSearchMetadata: false)
                        var candidates: [URL] = []
                        if AttachmentType(fromExtension: note.fileURL.pathExtension) == .image { candidates.append(note.fileURL) }
                        if let screenshot = note.screenshotURL { candidates.append(screenshot) }
                        candidates += note.attachments.filter { $0.typeEnum == .image }.map(\.url)
                        for url in candidates where seen.insert(url).inserted { images.append(.init(url: url, note: entry)) }
                        if images.count >= 12 { break }
                    }
                    return Array(images.prefix(12))
                }.value
                guard !Task.isCancelled else { return }
                images = result
            }
    }
}
