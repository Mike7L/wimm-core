import Foundation
import WimmDomain

/// Декоратор для AnalysisPort, добавляющий логирование и метрики.
/// Генерирует Correlation ID для каждого запроса.
public final class TelemetryDecorator: AnalysisPort, Sendable {
    private let decoratee: AnalysisPort
    private let logger: @Sendable (String) -> Void  // Инъекция логгера (print или файл)

    public init(
        decoratee: AnalysisPort,
        logger: @escaping @Sendable (String) -> Void = { print("[Telemetry] \($0)") }
    ) {
        self.decoratee = decoratee
        self.logger = logger
    }

    public func analyze(text: String) async throws -> AnalysisCard {
        try await withTelemetry(operation: "Analyze", context: "TextLen: \(text.count)") {
            try await decoratee.analyze(text: text)
        }
    }


    // MARK: - Helpers

    private func withTelemetry<T>(
        operation: String,
        context: String,
        work: () async throws -> T
    ) async throws -> T {
        let id = UUID()
        let start = Date()
        logger("Start \(operation) | ID: \(id) | \(context)")
        do {
            let result = try await work()
            logger("Success \(operation) | ID: \(id) | Duration: \(elapsed(since: start))s")
            return result
        } catch {
            logger(
                "Error \(operation) | ID: \(id) | Duration: \(elapsed(since: start))s | Error: \(error)"
            )
            throw error
        }
    }

    private func elapsed(since start: Date) -> String {
        String(format: "%.2f", Date().timeIntervalSince(start))
    }
}
