import AppKit
import AVFoundation
import ImageIO
import PDFKit
import Quartz
import SwiftUI
import WimmDomain
import WimmInfrastructure

/// Source files are opened only for the selected tab, never while laying out the timeline.
struct StudioNoteSourceView: View {
    let url: URL

    var body: some View {
        Group {
            if FileStore.isAudioFile(url) {
                StudioNoteAudioPlayer(url: url)
            } else if url.pathExtension.lowercased() == "pdf" {
                StudioNotePDF(url: url)
            } else if NoteAttachmentMedia.imageExtensions.contains(url.pathExtension.lowercased()) {
                StudioNoteImage(url: url)
            } else {
                StudioNoteQuickLook(url: url).frame(height: 460)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct StudioNoteImage: View {
    let url: URL
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxHeight: 540).accessibilityLabel(url.lastPathComponent)
            } else if failed {
                ContentUnavailableView("Изображение недоступно", systemImage: "photo")
            } else { ProgressView().frame(height: 240) }
            HStack {
                Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("Открыть оригинал") { NSWorkspace.shared.open(url) }.controlSize(.small)
            }
        }
        .task(id: url) {
            image = nil; failed = false
            let url = url
            let loaded = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1800,
                      ] as CFDictionary) else { return nil }
                return NSImage(cgImage: thumbnail, size: .zero)
            }.value
            guard !Task.isCancelled else { return }
            image = loaded; failed = loaded == nil
        }
    }
}

private struct StudioNotePDF: View {
    let url: URL
    @State private var image: NSImage?
    @State private var pageCount = 0
    @State private var page = 0
    @State private var failed = false

    var body: some View {
        VStack(spacing: 12) {
            if pageCount > 0 {
                HStack {
                    Button { page -= 1 } label: { Image(systemName: "chevron.left") }
                        .disabled(page == 0).help("Предыдущая страница").accessibilityLabel("Предыдущая страница")
                    Text("\(page + 1) / \(pageCount)").monospacedDigit().foregroundStyle(.secondary)
                    Button { page += 1 } label: { Image(systemName: "chevron.right") }
                        .disabled(page >= pageCount - 1).help("Следующая страница").accessibilityLabel("Следующая страница")
                    Spacer()
                    Button("Открыть оригинал") { NSWorkspace.shared.open(url) }
                }.controlSize(.small)
            }
            if let image {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 580)
                    .accessibilityLabel("\(url.lastPathComponent), страница \(page + 1)")
            } else if failed {
                ContentUnavailableView("Документ недоступен", systemImage: "doc.richtext",
                                       description: Text("Файл отсутствует, защищён паролем или не содержит страниц."))
                Button("Открыть файл") { NSWorkspace.shared.open(url) }
            } else { ProgressView().frame(height: 300) }
        }
        .task(id: "\(url.path):\(page)") {
            image = nil; failed = false
            let url = url, page = page
            // A bounded page image fits the note's one scroll view. PDFKit's tiled
            // PDFView introduces another scroll surface and retains the full document.
            let loaded = await Task.detached(priority: .userInitiated) { () -> (NSImage?, Int) in
                guard let document = PDFDocument(url: url), !document.isLocked,
                      let source = document.page(at: page) else { return (nil, 0) }
                return (source.thumbnail(of: NSSize(width: 1600, height: 1800), for: .mediaBox), document.pageCount)
            }.value
            guard !Task.isCancelled else { return }
            image = loaded.0; pageCount = loaded.1; failed = loaded.0 == nil
        }
    }
}

/// Quick Look supplies native previews for office documents and other imported files.
private struct StudioNoteQuickLook: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = false
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) != url as NSURL { view.previewItem = url as NSURL }
    }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}

struct StudioNoteAudioPlayer: View {
    let url: URL
    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var position = 0.0
    @State private var duration = 0.0
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    guard let player else { return }
                    if player.isPlaying { player.pause(); isPlaying = false }
                    else {
                        if position >= duration { player.currentTime = 0; position = 0 }
                        isPlaying = player.play()
                    }
                } label: { Image(systemName: isPlaying ? "pause.fill" : "play.fill").frame(width: 18) }
                    .disabled(player == nil)
                    .accessibilityLabel(isPlaying ? "Пауза" : "Воспроизвести")
                Slider(value: Binding(get: { position }, set: {
                    position = $0; player?.currentTime = $0
                }), in: 0...max(duration, 0.01))
                    .disabled(player == nil).accessibilityLabel("Позиция записи")
                Text("\(time(position)) / \(time(duration))").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            if failed {
                Text("Аудио недоступно").font(.caption).foregroundStyle(.secondary)
                Button("Открыть файл") { NSWorkspace.shared.open(url) }.controlSize(.small)
            }
        }
        .task(id: url) {
            player?.stop(); player = nil; position = 0; duration = 0; isPlaying = false; failed = false
            let url = url
            let loaded = await Task.detached(priority: .userInitiated) { try? AVAudioPlayer(contentsOf: url) }.value
            guard !Task.isCancelled else { return }
            player = loaded; duration = loaded?.duration ?? 0; failed = loaded == nil
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
                position = loaded?.currentTime ?? 0
                isPlaying = loaded?.isPlaying ?? false
            }
        }
        .onDisappear { player?.stop(); isPlaying = false }
    }

    private func time(_ seconds: Double) -> String {
        let value = seconds.isFinite ? max(0, Int(seconds)) : 0
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
