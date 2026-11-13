import Foundation

// MARK: - Errors

/// Storage layer errors propagated from infrastructure adapters.
public enum StorageError: Error, Sendable {
    case noteNotFound(String)
    case writeFailed(String)
}

// MARK: - Core Entities

/// Статус обработки задачи.
///
/// В Architecture 2.0 мы используем enum со связанными значениями для ошибок,
/// чтобы хранить причину отказа прямо в статусе.
public enum ProcessingStatus: Codable, Sendable, Equatable {
    case pendingAnalysis  // Аудио есть, транскрипция есть, ждем LLM
    case completed  // Все готово (есть AnalysisCard)
    case failed(reason: String, retryable: Bool)

    // Для совместимости с легаси JSON (где могут быть строки)
    // добавим кастомный декодинг при необходимости, но пока держим чисто.
}

/// Основная сущность Заметки.
///
/// Является агрегатом. В Architecture 2.0 CapturedNote - это иммутабельная структура данных,
/// которую мы читаем с диска целиком и пишем целиком.
public struct CapturedNote: Codable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date

    public var title: String?
    public var text: String  // Транскрибированный текст
    public var audioPath: String?  // Относительный путь к .m4a

    // Метаданные обработки
    public var status: ProcessingStatus

    // Результат анализа (AnalysisCard)
    public var card: AnalysisCard?

    /// Источник заметки: user (по умолчанию) или wimm (проактивный ответ).
    public var source: NoteSource?

    /// First 8 characters of the UUID string, used for display and logging.
    public var shortID: String { String(id.uuidString.prefix(8)) }

    public init(
        id: UUID = UUID(), createdAt: Date = Date(), text: String, audioPath: String?,
        status: ProcessingStatus, source: NoteSource? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.audioPath = audioPath
        self.status = status
        self.source = source
    }
}

/// Карточка знаний (результат работы LLM).
///
/// Должна быть совместима с легаси-структурой, но здесь мы определяем чистую версию.
public struct AnalysisCard: Codable, Sendable {
    public var title: String
    public var summary: String
    public var tags: [String]
    public var projects: [String]
    /// Corresponds to WimmCoreMinimal NoteCard.is_artifact
    public var isArtifact: Bool
    /// Corresponds to WimmCoreMinimal NoteCard.is_draft
    public var isDraft: Bool
    /// Corresponds to WimmCoreMinimal NoteCard.is_insight
    public var isInsight: Bool
    /// Corresponds to WimmCoreMinimal NoteCard.is_liked
    public var isLiked: Bool

    public init(
        title: String,
        summary: String,
        tags: [String],
        projects: [String],
        isArtifact: Bool = false,
        isDraft: Bool = false,
        isInsight: Bool = false,
        isLiked: Bool = false
    ) {
        self.title = title
        self.summary = summary
        self.tags = tags
        self.projects = projects
        self.isArtifact = isArtifact
        self.isDraft = isDraft
        self.isInsight = isInsight
        self.isLiked = isLiked
    }
}

public struct NoteQuestionAnswer: Sendable, Equatable {
    public let noteID: UUID
    public let normalizedQuestion: String
    public let answer: String
    public let role: String?
    public let outputLanguage: String?

    public init(
        noteID: UUID,
        normalizedQuestion: String,
        answer: String,
        role: String? = nil,
        outputLanguage: String? = nil
    ) {
        self.noteID = noteID
        self.normalizedQuestion = normalizedQuestion
        self.answer = answer
        self.role = role
        self.outputLanguage = outputLanguage
    }
}

public struct NoteCollectionAnswer: Sendable, Equatable {
    public let noteIDs: [UUID]
    public let normalizedQuestion: String
    public let answer: String
    public let role: String?
    public let outputLanguage: String?

    public init(
        noteIDs: [UUID],
        normalizedQuestion: String,
        answer: String,
        role: String? = nil,
        outputLanguage: String? = nil
    ) {
        self.noteIDs = noteIDs
        self.normalizedQuestion = normalizedQuestion
        self.answer = answer
        self.role = role
        self.outputLanguage = outputLanguage
    }
}
