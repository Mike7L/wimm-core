#if os(iOS)
import Observation
import SwiftUI
import WimmDomain
import WimmInfrastructure
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

// Rows, cards and the audio player used by RecordingDetailView.

/// Collapsed source row: icon, source type, file name; expands to the full
/// original text with a share action for the underlying file.
struct SourceDisclosureRow: View {
    let source: RecordingDetailView.NoteSource
    @State private var expanded = false

    private var previewLine: String {
        source.text
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: source.icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .background(Color(.tertiarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.title)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                        Text(expanded ? source.fileName : previewLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    Text(source.text)
                        .font(.callout)
                        .textSelection(.enabled)

                    if let url = source.fileURL {
                        ShareLink(item: url) {
                            Label(L10n.iOS.Recording.shareFile, systemImage: "square.and.arrow.up")
                                .font(.footnote)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Rounded card section used across the detail screen.
struct DetailCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.footnote)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Thin iOS wrapper around the shared `NoteAudioPlayer` that configures
/// `AVAudioSession` for playback and persists the skip-silence toggle.
@MainActor
@Observable
final class AudioPlayerController {
    private static let skipSilenceDefaultsKey = "skipSilencePlayback"

    private let engine: NoteAudioPlayer

    var currentTime: Double { engine.position }
    var duration: Double { engine.duration }
    var isPlaying: Bool { engine.isPlaying }
    var isReady: Bool { engine.isReady }

    var skipSilence: Bool {
        didSet {
            UserDefaults.standard.set(skipSilence, forKey: Self.skipSilenceDefaultsKey)
            engine.skipSilence = skipSilence
        }
    }

    init() {
        let savedSkipSilence = UserDefaults.standard.bool(forKey: Self.skipSilenceDefaultsKey)
        self.skipSilence = savedSkipSilence
        self.engine = NoteAudioPlayer(skipSilence: savedSkipSilence) {
            // The recorder leaves the shared session in .record; switch to
            // playback or the device stays silent (also respects the mute switch).
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default)
                try session.setActive(true)
            } catch {
                print("Failed to activate playback session: \(error)")
            }
        }
    }

    func load(url: URL) async {
        await engine.load(url)
    }

    func play(url: URL) {
        engine.play(url: url)
    }

    func pause() {
        engine.pause()
    }

    func stop() {
        engine.stop()
    }

    func seek(to time: Double) {
        engine.seek(to: time)
    }
}
/// The note's transcriptions side by side — Realtime, On-device, Cloud and
/// the runs a re-transcription replaced (`NoteTranscriptVariant`), the iOS
/// counterpart of the Reader's `NoteTextVariantsSection`. Each opens to its
/// text with Copy and "Use as text".
struct TranscriptVariantsCard: View {
    let variants: [NoteTranscriptVariant]
    let bodyText: String
    let onUseAsText: (String) -> Void

    var body: some View {
        DetailCard(title: L10n.Reader.NoteView.Variants.transcriptions, systemImage: "waveform") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(variants.enumerated()), id: \.element.id) { index, variant in
                    if index > 0 { Divider().padding(.vertical, 6) }
                    TranscriptVariantRow(
                        variant: variant,
                        isBody: variant.text == bodyText.trimmingCharacters(in: .whitespacesAndNewlines),
                        onUseAsText: onUseAsText)
                }
            }
        }
    }
}

private struct TranscriptVariantRow: View {
    let variant: NoteTranscriptVariant
    let isBody: Bool
    let onUseAsText: (String) -> Void
    @State private var isExpanded = false

    private var title: String {
        switch variant.kind {
        case .realtime: L10n.Reader.NoteView.Variants.realtime
        case .local: L10n.Reader.NoteView.Variants.local
        case .cloud: L10n.Reader.NoteView.Variants.cloud
        case .current: L10n.Reader.NoteView.Variants.current
        case .speakers(let count): L10n.Reader.NoteView.Variants.speakers(count)
        case .previous: L10n.Reader.NoteView.Variants.previous
        }
    }

    private var badge: String? {
        let text = [variant.provider?.uppercased(), variant.model].compactMap { $0 }.joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text(variant.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 16) {
                    Button(L10n.Reader.NoteView.Variants.useAsText) { onUseAsText(variant.text) }
                        .disabled(isBody)
                    Button {
                        UIPasteboard.general.string = variant.text
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .accessibilityLabel(L10n.Common.copy)
                    Spacer(minLength: 0)
                }
                .font(.subheadline)
                .buttonStyle(.borderless)
            }
            .padding(.top, 6)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    if variant.isCurrentRun {
                        Text(L10n.Reader.NoteView.Variants.currentRun)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.green)
                    }
                    if isBody {
                        Text(L10n.Reader.NoteView.Variants.sameAsText)
                            .font(.caption2)
                            .italic()
                            .foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 6) {
                    if let badge {
                        Text(badge)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    if let date = variant.date {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}
#endif
