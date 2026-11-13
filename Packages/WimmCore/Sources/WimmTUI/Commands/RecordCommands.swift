import Foundation
import WimmDomain

// MARK: - record / process / capture commands

extension WimmTUIRuntime {

    static func runRecord(
        args: [String],
        container: AppContainer,
        autoProcessAfterRecord: inout Bool
    ) async throws {
        if let override = parseAutoProcessOverride(args: args) {
            autoProcessAfterRecord = override
            print("Auto-process set to: \(autoProcessAfterRecord ? "on" : "off")")
        }
        print("Recording... (Press Enter to stop)")

        let stream = try container.transcriber.startStreamingCapture()
        let live = RecordLiveTranscript()
        let streamTask = Task {
            do {
                for try await text in stream {
                    await live.update(text)
                    print("\rTranscribed: \(text)", terminator: "")
                    fflush(stdout)
                }
            } catch {
                print("\nLive transcription stream error: \(error.localizedDescription)")
            }
        }

        _ = readLine()
        print("\nStopping capture…")

        let (data, final) = try await container.transcriber.stopCapture()
        await streamTask.value
        let transcript = await resolveRecordedTranscript(
            finalText: final,
            liveFallback: live.latest
        )

        let note = try await container.storage.saveRecording(
            data: data,
            fileName: "recording_\(Int(Date().timeIntervalSince1970)).m4a",
            initialText: transcript
        )
        print("Saved note: [\(note.shortID)]")
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            print("Warning: empty transcript. Check microphone/speech permissions or selected engine.")
        } else {
            print("Final transcript: \(transcript.prefix(120))")
        }

        if autoProcessAfterRecord {
            await container.queueSupervisor.notifyNewTask()
        } else {
            print("Auto-process disabled. Run `queue process` manually.")
        }
    }

    static func runProcess(args: [String], container: AppContainer) async throws {
        if let fileArg = args.first, !fileArg.hasPrefix("-") {
            let fileURL: URL
            if fileArg.hasPrefix("/") {
                fileURL = URL(fileURLWithPath: fileArg)
            } else {
                fileURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent(fileArg)
            }
            let dryRun = ArgParser(args).flag("--dry-run")
            let mode = parseTranscriptionMode(args: args)

            if dryRun {
                print("Dry-run: would process file \(fileURL.lastPathComponent)")
                print("  transcription mode: \(mode)")
            } else {
                print("Processing file: \(fileURL.lastPathComponent)...")
                let result = try await container.processFile.execute(
                    fileURL: fileURL,
                    transcriptionMode: mode,
                    dryRun: false
                )
                print("Done. Status: \(result.note.status)")
                if result.didTranscribe { print("Transcribed: \(result.note.text.prefix(80))...") }
                if let card = result.note.card { print("Card: \(card.title)") }
            }
        } else {
            print("Processing queue...")
            let count = try await container.queueSupervisor.processQueue()
            print("Processed \(count) notes.")
        }
    }

    static func runCapture(args: [String], container: AppContainer) async throws {
        let dryRun = ArgParser(args).flag("--dry-run")
        if dryRun {
            print("capture: dry-run mode (no audio device required)")
            let result = try await container.capture.stopAndProcess(dryRun: true)
            print("Dry-run capture complete. Transcript preview: \(result.transcript.isEmpty ? "(empty)" : result.transcript)")
            return
        }

        print("Starting microphone capture… press Enter to stop.")
        let stream = try container.capture.startCapture()
        let streamTask = Task {
            do {
                for try await partial in stream {
                    print("[live] \(partial)")
                }
            } catch {
                print("Live transcription stream error: \(error.localizedDescription)")
            }
        }

        _ = readLine()

        print("Stopping capture, saving and analysing…")
        let result = try await container.capture.stopAndProcess()
        await streamTask.value
        print("Capture complete. Note ID: \(result.note.id), status: \(result.note.status)")
        if let card = result.note.card { print("Card: \(card.title)") }
    }

    // MARK: - Parsing helpers

    static func parseAutoProcessOverride(args: [String]) -> Bool? {
        guard let value = ArgParser(args).string("--auto-process") else { return nil }
        switch value.lowercased() {
        case "on":  return true
        case "off": return false
        default:    return nil
        }
    }

    static func parseTranscriptionMode(args: [String]) -> TranscriptionMode {
        switch ArgParser(args).string(anyOf: "--transcribe", "-t")?.lowercased() {
        case "always": return .always
        case "skip":   return .skip
        default:       return .ifMissing
        }
    }
}

actor RecordLiveTranscript {
    private(set) var latest: String?

    func update(_ text: String) {
        latest = text
    }
}
