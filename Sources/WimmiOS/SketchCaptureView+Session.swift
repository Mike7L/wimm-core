#if os(iOS)
import SwiftUI
import PhotosUI
#if canImport(UIKit)
import UIKit
#endif
import WimmDomain
import UniformTypeIdentifiers
import VisionKit

// Part of `SketchCaptureView`: the recording session's actions and
// persistence (pause, split, finish, discard, attachments, scans). The view
// body lives in SketchCaptureView.swift. Members the two halves share are
// module-internal rather than private for that reason.

extension SketchCaptureView {
    // MARK: - Actions & Helpers
    func togglePause() {
        if audioRecorder.isPaused {
            audioRecorder.resumeRecording()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                Task { @MainActor in
                    self.elapsed += 0.25
                }
            }
        } else {
            audioRecorder.pauseRecording()
            timer?.invalidate()
            timer = nil
        }
        
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    func performSplit() async {
        guard audioRecorder.isRecording && !audioRecorder.isPaused else { return }
        
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
        
        if let finalizedURL = await audioRecorder.splitRecording() {
            do {
                let meta = try await IOSRecordingRepository.shared.loadMetadata(for: finalizedURL)
                let segment = IOSRecordingSegment(
                    fileURL: finalizedURL,
                    transcription: meta.transcription,
                    duration: meta.duration,
                    timestamp: meta.timestamp
                )
                await upsertFallbackNoteCard(for: finalizedURL, transcript: meta.transcription)
                withAnimation {
                    completedSegments.append(segment)
                }
            } catch {
                print("SketchCaptureView: Failed to load split segment metadata: \(error)")
                let segment = IOSRecordingSegment(
                    fileURL: finalizedURL,
                    transcription: audioRecorder.transcribedText,
                    duration: elapsed,
                    timestamp: Date()
                )
                withAnimation {
                    completedSegments.append(segment)
                }
            }
            await appState.publishRecording(at: finalizedURL)
            appState.scheduleRecordingSync(for: finalizedURL)
        }
    }

    /// Split segments never pass through persistNote, so without this they'd
    /// stay title-less placeholders until the desktop processes them. The card is
    /// written without refined_edited_at so desktop reprocessing can still replace it.
    func upsertFallbackNoteCard(for url: URL, transcript: String) async {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let repository = IOSRecordingRepository.shared
        guard await repository.existingNoteCard(for: url) == nil else { return }
        let card = NoteCard(
            note_file: url.lastPathComponent,
            lang: nil,
            title: extractTitle(from: text),
            summary: text,
            refined_text: text,
            refined_edited_at: nil
        )
        await repository.upsertNoteCard(for: url, card: card, lang: nil)
    }

    /// Stop, persist the note and leave. The flow has no review step: the
    /// transcript lands in the journal and the sheet closes right away.
    func finishRecording() async {
        guard phase == .listening else { return }
        guard audioRecorder.isRecording else {
            dismiss()
            return
        }
        savedRecordingURL = audioRecorder.recordingURL
        withAnimation {
            phase = .processing
        }
        await appState.finishRecording()
    }

    func discardRecording() async {
        stopTimer()

        if audioRecorder.isRecording {
            let url = audioRecorder.recordingURL
            await audioRecorder.stopRecording()
            if let url {
                _ = await IOSRecordingRepository.shared.moveToTrash(file: url)
            }
        }

        await appState.loadRecordings()
        dismiss()
    }

    /// A photo taken during capture is its own image note, never an
    /// attachment of the recording (one note = one media, 2026-11-09). It is
    /// written at once, so it no longer waits for the recording to start.
    /// `savedAttachments` only lists this session's photos on screen.
    func persistImages(_ images: [UIImage], quality: Double) async {
        guard !images.isEmpty else { return }
        let saved = await appState.importImages(images, quality: quality)
        await MainActor.run {
            savedAttachments.append(contentsOf: saved.map { NoteAttachment(url: $0, type: "image") })
        }
    }

    func saveScannedDocument(_ sourceURL: URL) async {
        // Same path as the home-screen scanner: metadata plus a note card, so
        // the scan shows up in the journal with a title instead of a bare file.
        await appState.importScannedDocument(sourceURL)
    }

    func extractTitle(from text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "Recording" }
        let sentence = normalized.split(whereSeparator: { ".!?".contains($0) }).first.map(String.init) ?? normalized
        let title = String(sentence.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Recording" : title
    }

    func heicData(for image: UIImage, quality: Double) -> Data? {
        guard let cgImage = image.cgImage else { return nil }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil)
        else {
            return nil
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    func startTimer() {
        stopTimer()
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            Task { @MainActor in
                self.elapsed += 0.25
            }
        }
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
        if !audioRecorder.isRecording {
            elapsed = 0
        }
    }

    func showAlert(message: String) {
        alertMessage = message
        showUnavailableAlert = true
    }
}
#endif
