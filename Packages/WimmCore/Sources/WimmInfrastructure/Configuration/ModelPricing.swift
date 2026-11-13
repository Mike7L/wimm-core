import Foundation
import WimmDomain

/// Price of one model, in USD per 1M tokens.
///
/// `audioInput` and `cachedInput` fall back to `input` when the provider does
/// not price them apart.
public struct ModelPrice: Codable, Sendable, Equatable {
    public var input: Double
    public var output: Double
    public var audioInput: Double?
    public var cachedInput: Double?

    public init(input: Double, output: Double, audioInput: Double? = nil, cachedInput: Double? = nil) {
        self.input = input
        self.output = output
        self.audioInput = audioInput
        self.cachedInput = cachedInput
    }

    enum CodingKeys: String, CodingKey {
        case input
        case output
        case audioInput = "audio_input"
        case cachedInput = "cached_input"
    }
}

/// A dated snapshot of provider prices.
///
/// Versioned on purpose: providers change their rates, and a report over last
/// quarter must be able to say which table produced its numbers. Recomputing
/// old months with today's prices would quietly rewrite history.
public struct PriceTable: Codable, Sendable {
    public var version: String
    public var currency: String
    public var source: String?
    public var models: [String: ModelPrice]

    public init(version: String, currency: String = "USD", source: String? = nil, models: [String: ModelPrice]) {
        self.version = version
        self.currency = currency
        self.source = source
        self.models = models
    }

    /// Exact match first, then the longest key that is a prefix of the model id
    /// — provider ids pick up suffixes (`-preview`, dated snapshots) that should
    /// not each need their own row.
    public func price(for model: String) -> ModelPrice? {
        if let exact = models[model] { return exact }
        let id = model.lowercased()
        return models
            .filter { id.hasPrefix($0.key.lowercased()) }
            .max { $0.key.count < $1.key.count }?
            .value
    }
}

/// What one logged call cost, split the way it is billed.
public struct CostBreakdown: Sendable, Equatable {
    public var textInput: Double = 0
    public var cachedInput: Double = 0
    public var audioInput: Double = 0
    public var output: Double = 0
    /// Hidden reasoning, at the output rate.
    public var thoughts: Double = 0

    public init(textInput: Double = 0, cachedInput: Double = 0, audioInput: Double = 0, output: Double = 0, thoughts: Double = 0) {
        self.textInput = textInput
        self.cachedInput = cachedInput
        self.audioInput = audioInput
        self.output = output
        self.thoughts = thoughts
    }

    public var total: Double { textInput + cachedInput + audioInput + output + thoughts }

    public static func + (lhs: CostBreakdown, rhs: CostBreakdown) -> CostBreakdown {
        CostBreakdown(
            textInput: lhs.textInput + rhs.textInput,
            cachedInput: lhs.cachedInput + rhs.cachedInput,
            audioInput: lhs.audioInput + rhs.audioInput,
            output: lhs.output + rhs.output,
            thoughts: lhs.thoughts + rhs.thoughts)
    }
}

public enum ModelPricing {
    /// User-editable table. Deliberately not compiled in: rates are external
    /// facts with an expiry date, and a stale constant in the binary is worse
    /// than an honest "unknown".
    public static func tableURL() -> URL {
        StoragePaths.baseDirectory()
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("model_prices.json")
    }

    public static func loadTable(at url: URL? = nil) -> PriceTable? {
        let fileURL = url ?? tableURL()
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(PriceTable.self, from: data)
    }

    public static func save(_ table: PriceTable, to url: URL? = nil) throws {
        let fileURL = url ?? tableURL()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(table).write(to: fileURL, options: .atomic)
    }

    /// A skeleton listing the models actually seen in the logs, with zero rates
    /// to be filled from the provider's own pricing page. Zeros keep the totals
    /// visibly wrong rather than plausibly wrong.
    public static func template(models: [String]) -> PriceTable {
        let today = ISO8601DateFormatter()
        today.formatOptions = [.withFullDate]
        var rows: [String: ModelPrice] = [:]
        for model in models where !model.isEmpty {
            rows[model] = ModelPrice(input: 0, output: 0, audioInput: nil, cachedInput: nil)
        }
        return PriceTable(
            version: today.string(from: Date()),
            currency: "USD",
            source: "Fill in from the provider's pricing page; USD per 1M tokens.",
            models: rows)
    }

    /// Cost of a single call. Returns nil when the model has no row — an unknown
    /// price must not silently count as free.
    public static func cost(usage: TokenUsage, model: String, table: PriceTable) -> CostBreakdown? {
        guard let price = table.price(for: model) else { return nil }
        let audio = usage.audioTokens ?? 0
        let cached = usage.cachedInputTokens ?? 0
        let text = usage.textInputTokens ?? 0
        let output = usage.outputTokens ?? 0
        let thoughts = usage.billedThoughtsTokens ?? 0
        let perToken = 1_000_000.0
        return CostBreakdown(
            textInput: Double(text) * price.input / perToken,
            cachedInput: Double(cached) * (price.cachedInput ?? price.input) / perToken,
            audioInput: Double(audio) * (price.audioInput ?? price.input) / perToken,
            output: Double(output) * price.output / perToken,
            thoughts: Double(thoughts) * price.output / perToken)
    }
}
