#if os(iOS)
import SwiftUI
import PhotosUI
#if canImport(UIKit)
import UIKit
#endif
import WimmDomain
import UniformTypeIdentifiers
import VisionKit

// MARK: - Capture Phase Enum
enum CapturePhase {
    case listening
    case processing
}


// MARK: - Quick Capture Sheet (HUD Style for iOS)
struct SketchCaptureView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var audioRecorder: ReliableRecorder
    @Environment(\.dismiss) var dismiss

    // Phase and Draft State
    @State var phase: CapturePhase = .listening
    @State var savedRecordingURL: URL? = nil
    @State var savedAttachments: [NoteAttachment] = []
    @State var completedSegments: [IOSRecordingSegment] = []

    // Picker & Media States
    @State var selectedItems: [PhotosPickerItem] = []
    @State var selectedImages: [UIImage] = []
    @State var elapsed: TimeInterval = 0
    @State var timer: Timer?
    @State var showCamera = false
    @State var showUnavailableAlert = false
    @State var alertMessage = ""
    @State var pendingImages: [UIImage] = []
    @State var photoQuality: Double = 0.85
    @State var showScanner = false
    @State var scannedPDF: URL?

    // Localized Strings or Fallbacks
    var headerTitle: String {
        switch phase {
        case .listening: return L10n.iOS.Capture.title
        case .processing: return L10n.iOS.SaveStatus.saving
        }
    }

    var phaseColor: Color {
        switch phase {
        case .listening: return .red
        case .processing: return .orange
        }
    }

    var elapsedString: String {
        let totalSeconds = max(0, Int(elapsed.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            // Phase-tinted glow over the system background
            RadialGlowBackground(color: phaseColor)
                .ignoresSafeArea()
                .id(phase) // Re-instantiate gradient pulse when phase changes color
            
            VStack(spacing: 0) {
                // Header navigation bar
                headerRow
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 12)
                
                // Phase-based main body
                Group {
                    switch phase {
                    case .listening:
                        listeningBody
                    case .processing:
                        processingBody
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Phase-based controls
                Group {
                    switch phase {
                    case .listening:
                        listeningControls
                    case .processing:
                        processingControls
                    }
                }
                .padding(.top, 16)
            }
        }
        .alert(L10n.iOS.Error.unavailable, isPresented: $showUnavailableAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
        .sheet(isPresented: $showScanner) {
            DocumentScannerView(scannedPDF: $scannedPDF)
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { image in
                if let image {
                    Task {
                        await persistImages([image], quality: photoQuality)
                    }
                }
            }
        }
        .onChange(of: scannedPDF) { newURL in
            guard let url = newURL else { return }
            scannedPDF = nil
            // The scan lands as its own journal item; the session keeps running
            // so a scan never silently drops the recording in progress.
            Task {
                await saveScannedDocument(url)
            }
        }
        .onChange(of: selectedItems) { newItems in
            Task {
                var loadedImages: [UIImage] = []
                for item in newItems {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let uiImage = UIImage(data: data) {
                        loadedImages.append(uiImage)
                    }
                }
                selectedItems.removeAll()
                await persistImages(loadedImages, quality: photoQuality)
            }
        }
        .onChange(of: audioRecorder.isRecording) { isRecording in
            if isRecording {
                startTimer()
                Task {
                    await persistImages(pendingImages, quality: photoQuality)
                    await MainActor.run {
                        pendingImages.removeAll()
                    }
                }
            } else {
                stopTimer()
            }
        }
        .onAppear {
            if !audioRecorder.isRecording {
                Task {
                    await audioRecorder.startRecording()
                }
            } else {
                startTimer()
            }
        }
        .onDisappear {
            stopTimer()
        }
    }

    // MARK: - Header
    var headerRow: some View {
        let isPulseOn = Int(elapsed) % 2 == 0
        return HStack(spacing: 8) {
            // Status beacon
            Circle()
                .fill(phaseColor)
                .frame(width: 6, height: 6)
                .opacity(phase == .listening ? (isPulseOn ? 1.0 : 0.4) : 1.0)
                .animation(.easeInOut(duration: 0.35), value: isPulseOn)
            
            // Mode Title
            Text(headerTitle)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.secondary)
            
            // Elapsed Timer (for listening)
            if phase == .listening {
                Text(elapsedString)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color.red.opacity(isPulseOn ? 1.0 : 0.55))
                    .animation(.easeInOut(duration: 0.35), value: isPulseOn)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.12))
                    .cornerRadius(4)
            }
            
            Spacer()
            
            // Close Button
            if phase != .processing {
                Button {
                    Task {
                        await discardRecording()
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .font(.system(size: 22))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.Common.cancel)
            }
        }
    }

    // MARK: - Listening Phase UI
    var listeningBody: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 8)
            
            ModernWaveform(
                levels: audioRecorder.audioLevels,
                barCount: 36,
                height: 64,
                barWidth: 4,
                color: audioRecorder.isPaused ? .gray : .red
            )
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(audioRecorder.isPaused ? .gray : .red)
                    Text(L10n.iOS.Capture.liveTranscription)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.secondary)
                    Spacer()
                    if let inputName = audioRecorder.inputName {
                        Label(L10n.iOS.Capture.input(inputName),
                              systemImage: inputName.localizedCaseInsensitiveContains("airpods") ? "airpods" : "mic.fill")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 20)
                
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(completedSegments) { segment in
                                SegmentRow(
                                    segmentText: segment.transcription,
                                    isCurrent: false,
                                    isPaused: false,
                                    color: .green,
                                    copyText: segment.transcription
                                )
                                .id(segment.id)
                            }
                            
                            SegmentRow(
                                segmentText: audioRecorder.transcribedText,
                                isCurrent: true,
                                isPaused: audioRecorder.isPaused,
                                color: audioRecorder.isPaused ? .orange : .red
                            )
                            .id("activeSegment")
                        }
                        .padding(.horizontal, 20)
                    }
                    .onChange(of: audioRecorder.transcribedText) { _ in
                        withAnimation {
                            proxy.scrollTo("activeSegment", anchor: .bottom)
                        }
                    }
                    .onChange(of: completedSegments.count) { _ in
                        withAnimation {
                            proxy.scrollTo("activeSegment", anchor: .bottom)
                        }
                    }
                    .onAppear {
                        proxy.scrollTo("activeSegment", anchor: .bottom)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            
            if !savedAttachments.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.iOS.Capture.attachmentsCount(savedAttachments.count))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 20)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(savedAttachments) { attachment in
                                AttachmentCard(attachment: attachment)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
            }

            Spacer(minLength: 8)
        }
    }

    var listeningControls: some View {
        VStack(spacing: 16) {
            // Secondary row (attachments)
            HStack(spacing: 24) {
                // Photos Picker
                PhotosPicker(selection: $selectedItems, matching: .images) {
                    CaptureToolIcon(systemName: "photo.on.rectangle")
                }

                // Camera Button
                Button {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        showCamera = true
                    } else {
                        showAlert(message: L10n.iOS.Error.cameraUnavailable)
                    }
                } label: {
                    CaptureToolIcon(systemName: "camera")
                }
                .buttonStyle(.plain)

                // Scan Document Button
                Button {
                    if VNDocumentCameraViewController.isSupported {
                        showScanner = true
                    } else {
                        showAlert(message: L10n.iOS.Error.cameraUnavailable)
                    }
                } label: {
                    CaptureToolIcon(systemName: "doc.viewfinder")
                }
                .buttonStyle(.plain)
            }

            // Primary row (recording controls)
            HStack(spacing: 32) {
                // Pause / Resume Button
                Button {
                    togglePause()
                } label: {
                    Image(systemName: audioRecorder.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 20))
                        .foregroundColor(audioRecorder.isPaused ? .white : .primary)
                        .frame(width: 48, height: 48)
                        .background {
                            if audioRecorder.isPaused {
                                Circle().fill(Color.green.gradient)
                            } else {
                                Circle().fill(.ultraThinMaterial)
                            }
                        }
                        .overlay(
                            Circle()
                                .strokeBorder(.quaternary, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                
                // Stop/Finish Button (Dominant)
                Button {
                    Task {
                        await finishRecording()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.red.gradient)
                            .frame(width: 72, height: 72)
                        Circle()
                            .stroke(Color.white, lineWidth: 4)
                            .frame(width: 58, height: 58)
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white)
                            .frame(width: 22, height: 22)
                    }
                    .shadow(color: .red.opacity(0.3), radius: 10, x: 0, y: 5)
                }
                .buttonStyle(.plain)

                // Send / Split Button
                Button {
                    Task {
                        await performSplit()
                    }
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.white)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(Color.blue.gradient))
                        .overlay(
                            Circle()
                                .strokeBorder(.quaternary, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(audioRecorder.isPaused)
                .opacity(audioRecorder.isPaused ? 0.4 : 1.0)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
    }

    // MARK: - Processing Phase UI
    var processingBody: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
                .tint(.orange)
            
            Text(L10n.iOS.SaveStatus.saving)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var processingControls: some View {
        HStack {
            Spacer()
        }
        .padding(.bottom, 24)
    }

}
#endif
