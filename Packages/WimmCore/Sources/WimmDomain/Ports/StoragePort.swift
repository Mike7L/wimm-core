import Foundation

/// Порт для работы с постоянным хранением (Filesystem / DB).
/// Абстрагирует создание файлов и метаданных.
public protocol StoragePort: Sendable {
    /// Сохранить новую аудиозапись и сразу вернуть структуру заметки.
    /// - Parameters:
    ///   - data: данные аудио файла
    ///   - fileName: имя файла (без пути)
    /// - Returns: Созданная заметка со статусом .pendingAnalysis
    func saveRecording(data: Data, fileName: String, initialText: String) async throws -> CapturedNote

    /// Загрузить все заметки (сканирование директории).
    /// - Returns: Полный список заметок.
    func loadAll() async throws -> [CapturedNote]

    /// Обновить метаданные заметки.
    /// Используется для смены статуса, добавления AnalysisCard и т.д.
    func updateNote(_ note: CapturedNote) async throws

    /// Delete a note and its associated files from storage.
    func deleteNote(id: UUID) async throws

    /// Найти заметку, привязанную к конкретному аудиофайлу.
    /// - Parameter audioPath: Абсолютный URL или имя файла (stem-matching).
    /// - Returns: Заметка или nil если не найдена.
    func loadNote(matchingAudioPath audioPath: String) async throws -> CapturedNote?
}
