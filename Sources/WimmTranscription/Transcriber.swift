import Foundation

public protocol Transcriber {
    func transcribe(file url: URL, language: String) async -> TranscriptionResult
}
