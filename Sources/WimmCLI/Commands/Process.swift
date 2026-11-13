import ArgumentParser
import WimmTUI
import Foundation
import Darwin

struct Process: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Process audio/video files (Transcribe, OCR, NoteCard generation)"
    )

    @Argument(help: "Path to the file to process")
    var path: String

    @Option(name: .long, help: "Transcription language (default: Auto)")
    var lang: String = "Auto"

    @Option(name: .long, help: "Force specific transcription model")
    var model: String?

    @Option(name: .long, help: "Transcription engine (native, gemini, openrouter, whisper). Default: gemini")
    var engine: String = "gemini"

    @Flag(name: .long, help: "Skip transcription")
    var skipTranscription: Bool = false

    @Flag(name: .long, help: "Skip NoteCard generation (LLM processing)")
    var skipAnalysis: Bool = false

    mutating func run() async throws {
        let normalizedEngine = engine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalizedEngine {
        case "native", "gemini", "openrouter", "whisper", "mock":
            setenv("WIMM_TRANSCRIBER", normalizedEngine, 1)
        default:
            print("Warning: --engine \(engine) is unsupported. Allowed: native|gemini|openrouter|whisper|mock. Using gemini.")
            setenv("WIMM_TRANSCRIBER", "gemini", 1)
        }
        if model != nil {
            print("Warning: --model is not supported by WIMM; ignoring.")
        }
        if lang != "Auto" {
            print("Warning: --lang \(lang) is not supported by WIMM; using system locale.")
        }

        var tuiArgs = ["process", path]
        if skipTranscription {
            tuiArgs += ["--transcribe", "skip"]
        } else if skipAnalysis {
            print("Warning: --skip-analysis is partially supported; WIMM will transcribe but attempt analysis. Use queue retry to control analysis separately.")
            tuiArgs += ["--transcribe", "if-missing"]
        } else {
            tuiArgs += ["--transcribe", "if-missing"]
        }
        try await WimmTUIRuntime.runOnce(tuiArgs)
    }
}