import Foundation

extension UnifiedModelManager {
    public func submitInstructionAnalysisAndWait(
        instruction: String,
        context: String,
        priority: ModelPriority = .normal
    ) async throws -> String {
        struct Payload: Encodable {
            let instruction: String
            let context: String
        }

        let payload = Payload(instruction: instruction, context: context)
        let data = try JSONEncoder().encode(payload)
        guard let input = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "UnifiedModelManager", code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode instruction analysis payload"]
            )
        }

        return try await submitAndWait(
            type: .analysis,
            input: input,
            priority: priority,
            engine: ModelSelection.model(for: .understand),
            context: [
                "origin": UnifiedJobOrigin.uiInstructionAnalysis,
                "analysis_kind": "instruction",
            ]
        )
    }

    public func submitCardsAnalysisAndWait(
        texts: [String],
        priority: ModelPriority = .normal
    ) async throws -> String {
        struct Payload: Encodable {
            let texts: [String]
        }

        let payload = Payload(texts: texts)
        let data = try JSONEncoder().encode(payload)
        guard let input = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "UnifiedModelManager", code: 1002,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode cards analysis payload"]
            )
        }

        return try await submitAndWait(
            type: .analysis,
            input: input,
            priority: priority,
            engine: ModelSelection.model(for: .understand),
            context: [
                "origin": UnifiedJobOrigin.uiCardsAnalysis,
                "analysis_kind": "cards",
            ]
        )
    }
}
