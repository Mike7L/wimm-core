import Foundation

/// Источник заметки: пользователь или проактивный ответ WIMM.
///
/// Lived in `SessionAnalysisResult.swift` until the session-analysis DTOs were
/// removed; `CapturedNote.source` is the one thing that still reads it.
public enum NoteSource: String, Codable, Sendable {
    case user
    case wimm
}
