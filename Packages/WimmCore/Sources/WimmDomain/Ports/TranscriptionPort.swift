import Foundation

/// Порт для batch-транскрипции аудиофайла (REST API, без микрофона).
public protocol FileTranscriptionPort: Sendable {
    /// Транскрибировать существующий аудиофайл с диска.
    /// - Parameter fileURL: URL файла на диске (m4a/wav/mp3).
    /// - Returns: Полный транскрибированный текст.
    func transcribeFile(at fileURL: URL) async throws -> String
}

/// Порт для потоковой транскрипции с микрофона.
/// Расширяет `FileTranscriptionPort` — реализации могут транскрибировать файлы и живой звук.
public protocol TranscriptionPort: FileTranscriptionPort {
    /// Начать захват звука с микрофона и транскрипцию.
    /// - Returns: Асинхронный поток частичных результатов текста.
    func startStreamingCapture() throws -> AsyncThrowingStream<String, Error>

    /// Завершить захват и вернуть финальный аудиофайл.
    /// - Returns: tuple (данные m4a, финальный текст).
    func stopCapture() async throws -> (audioData: Data, finalText: String)
}
