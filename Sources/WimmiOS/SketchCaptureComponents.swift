#if os(iOS)
import SwiftUI
import PhotosUI
#if canImport(UIKit)
import UIKit
#endif
import WimmDomain
import UniformTypeIdentifiers
import VisionKit

// Small views and models used by SketchCaptureView.

// MARK: - Radial Pulsing Glow Background
struct RadialGlowBackground: View {
    let color: Color
    @State private var isAnimating = false
    
    var body: some View {
        GeometryReader { geometry in
            RadialGradient(
                colors: [color.opacity(0.12), color.opacity(0.0)],
                center: .center,
                startRadius: 0,
                endRadius: min(geometry.size.width, geometry.size.height) * 0.8
            )
            .scaleEffect(isAnimating ? 1.15 : 0.95)
            .blur(radius: 20)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 2.0)
                    .repeatForever(autoreverses: true)
                ) {
                    isAnimating = true
                }
            }
        }
    }
}

// MARK: - CaptureToolIcon
/// Circular glass button icon used for the attachment tools row.
struct CaptureToolIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: 44, height: 44)
            .background(.ultraThinMaterial)
            .clipShape(Circle())
            .overlay(
                Circle()
                    .strokeBorder(.quaternary, lineWidth: 1)
            )
    }
}

// MARK: - CameraPicker UIViewControllerRepresentable
struct CameraPicker: UIViewControllerRepresentable {
    let onComplete: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onComplete: (UIImage?) -> Void

        init(onComplete: @escaping (UIImage?) -> Void) {
            self.onComplete = onComplete
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
            onComplete(nil)
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let image = info[.originalImage] as? UIImage
            picker.dismiss(animated: true)
            onComplete(image)
        }
    }
}

// MARK: - AttachmentCard
struct AttachmentCard: View {
    let attachment: NoteAttachment
    var onRemove: (() -> Void)? = nil
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if attachment.url.pathExtension.lowercased() == "pdf" {
                    VStack(spacing: 6) {
                        Image(systemName: "doc.richtext.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.orange)
                        Text(attachment.url.lastPathComponent)
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                    }
                    .frame(width: 72, height: 72)
                    .background(Color.primary.opacity(0.06))
                } else {
                    AsyncImage(url: attachment.url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                        default:
                            Color.primary.opacity(0.08)
                                .overlay(
                                    Image(systemName: "photo")
                                        .foregroundColor(.secondary)
                                )
                        }
                    }
                    .frame(width: 72, height: 72)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.quaternary, lineWidth: 1)
            )

            if let onRemove {
                Button {
                    onRemove()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.red)
                        .background(Circle().fill(.background))
                }
                .offset(x: 5, y: -5)
                .buttonStyle(.plain)
            }
        }
        .frame(width: 78, height: 78)
    }
}

// MARK: - Segment Models & Views

struct IOSRecordingSegment: Identifiable {
    let id = UUID()
    let fileURL: URL
    let transcription: String
    let duration: TimeInterval
    let timestamp: Date
}

struct SegmentRow: View {
    let segmentText: String
    let isCurrent: Bool
    let isPaused: Bool
    let color: Color
    var copyText: String? = nil
    @State private var isCopied = false
    
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                if isCurrent && !isPaused {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                        .opacity(isCurrent ? 1.0 : 0.6)
                } else {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 6)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(segmentText.isEmpty ? (isCurrent ? L10n.iOS.Capture.listening : L10n.iOS.Capture.noInput) : segmentText)
                    .font(.system(size: 15, weight: isCurrent ? .medium : .regular, design: .rounded))
                    .foregroundColor(segmentText.isEmpty ? .secondary : .primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let copyText, !copyText.isEmpty {
                Button {
                    UIPasteboard.general.string = copyText
                    withAnimation { isCopied = true }
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        withAnimation { isCopied = false }
                    }
                } label: {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundStyle(isCopied ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(isCurrent ? 0.06 : 0.03))
        .cornerRadius(8)
    }
}

#endif
