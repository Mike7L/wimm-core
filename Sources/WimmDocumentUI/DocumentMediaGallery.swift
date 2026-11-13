import AppKit
import ImageIO
import SwiftUI

/// Bounded thumbnails; full images are loaded only when the gallery is opened.
public struct DocumentMediaGallery: View {
    let urls: [URL]
    let scale: CGFloat
    let onOpen: ((URL) -> Void)?
    @State private var selected: Int?
    public init(urls: [URL], scale: CGFloat = 1, onOpen: ((URL) -> Void)? = nil) {
        self.urls = urls; self.scale = scale; self.onOpen = onOpen
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(urls.enumerated()), id: \.element) { index, url in
                    Button {
                        if let onOpen { onOpen(url) } else { selected = index }
                    } label: {
                        DocumentMediaImage(url: url, pixels: Int(528 * scale))
                            .frame(height: 132 * scale).clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(onOpen == nil ? "Открыть изображение" : "Открыть заметку с изображением")
                }
            }
        }
        .sheet(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let index = selected, urls.indices.contains(index) {
                VStack(spacing: 12) {
                    HStack {
                        Button { selected = (index + urls.count - 1) % urls.count } label: { Image(systemName: "chevron.left") }
                            .keyboardShortcut(.leftArrow, modifiers: []).disabled(urls.count < 2)
                        Spacer()
                        Text("\(index + 1) / \(urls.count)").monospacedDigit()
                        Spacer()
                        Button { selected = (index + 1) % urls.count } label: { Image(systemName: "chevron.right") }
                            .keyboardShortcut(.rightArrow, modifiers: []).disabled(urls.count < 2)
                        Button("Закрыть") { selected = nil }.keyboardShortcut(.cancelAction)
                    }
                    DocumentMediaImage(url: urls[index], pixels: 2400)
                    Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([urls[index]]) }
                }.padding(16).frame(minWidth: 640, minHeight: 480)
            }
        }
    }

    public static func inlineImageURL(_ markdown: String, baseURL: URL?) -> URL? {
        let text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(of: #"^!\[[^\]]*\]\(([^)]+)\)$"#, options: .regularExpression) != nil,
              let start = text.range(of: "]("),
              let url = URL(string: String(text[start.upperBound...].dropLast()), relativeTo: baseURL)?.absoluteURL,
              url.isFileURL else { return nil }
        return url
    }
}

private struct DocumentMediaImage: View {
    let url: URL
    let pixels: Int
    @State private var image: NSImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else if failed { Label("Изображение недоступно", systemImage: "photo").foregroundStyle(.secondary) }
            else { ProgressView() }
        }
        .task(id: url) {
            image = nil; failed = false
            let loaded = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: pixels,
                      ] as CFDictionary) else { return nil as NSImage? }
                return NSImage(cgImage: cg, size: .zero)
            }.value
            guard !Task.isCancelled else { return }
            image = loaded; failed = loaded == nil
        }
    }
}
