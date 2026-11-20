import Foundation
import WimmInfrastructure

/// An upper estimate of one tool-free packet request, made before it is sent.
///
/// A packet request is a single turn, so Claude Code's `--max-budget-usd` could only
/// notice the limit after the turn was paid for (and then threw the paid reply away).
/// Wimm refuses up front instead, from what it already knows: the request size and the
/// owner's price table. An unknown price leaves the estimate unknown (never zero), and
/// an unknown estimate never refuses.
public struct SecretaryPacketCostEstimate: Sendable, Equatable {
    /// Fewer bytes per token than the 3.2 seen on real format-2 packets (2026-11-19), so the
    /// input side errs high.
    public static let bytesPerToken = 2.5
    /// Reply plus reasoning. Observed packet replies took 11k–48k output tokens.
    public static let outputTokenCeiling = 64_000
    /// Claude Code writes the whole request into the prompt cache. Wimm starts it with
    /// `FORCE_PROMPT_CACHING_5M=1` (`ClaudeCodeExecutor.environment`), so the write is the
    /// 5-minute one at 1.25× input (the default 1-hour one costs 2×); the table has no row
    /// for either. Keep this in step with that environment.
    public static let claudeCacheWriteMultiplier = 1.25

    public var inputTokens: Int
    public var outputTokens: Int
    public var usd: Double

    /// nil: the model's price is not in the table (or is a zero placeholder), or the executor
    /// is not metered in dollars.
    public static func estimate(inputBytes: Int, model: String?, executor: String,
                                table: PriceTable?) -> SecretaryPacketCostEstimate? {
        guard executor != "codex", let table, let model, let price = price(for: model, in: table) else { return nil }
        let inputTokens = Int((Double(inputBytes) / bytesPerToken).rounded(.up))
        let multiplier = executor == "claude-code" ? claudeCacheWriteMultiplier : 1
        let usd = (Double(inputTokens) * price.input * multiplier + Double(outputTokenCeiling) * price.output) / 1_000_000
        return SecretaryPacketCostEstimate(inputTokens: inputTokens, outputTokens: outputTokenCeiling, usd: usd)
    }

    /// The refusal text when the estimate does not fit the remaining budget; nil to go ahead.
    public static func refusal(inputBytes: Int, model: String?, executor: String, table: PriceTable?,
                               remainingUSD: Double) -> String? {
        guard let estimate = estimate(inputBytes: inputBytes, model: model, executor: executor, table: table),
              estimate.usd > remainingUSD else { return nil }
        return String(format: "Packet request not sent: estimated up to $%.2f (%d input tokens at the cache-write rate + %d output tokens) exceeds the remaining budget of $%.2f.",
                      estimate.usd, estimate.inputTokens, estimate.outputTokens, max(0, remainingUSD))
    }

    /// The table's row for an id (exact or prefix), else, for a CLI alias such as `haiku`,
    /// the dearest row naming it. Zero rows are the unfilled template, so unknown.
    static func price(for model: String, in table: PriceTable) -> ModelPrice? {
        let known = { (price: ModelPrice) in price.input > 0 || price.output > 0 }
        if let price = table.price(for: model) { return known(price) ? price : nil }
        let alias = model.lowercased()
        guard !alias.isEmpty else { return nil }
        let rows = table.models.filter { $0.key.lowercased().contains(alias) && known($0.value) }.map(\.value)
        guard !rows.isEmpty else { return nil }
        return ModelPrice(input: rows.map(\.input).max() ?? 0, output: rows.map(\.output).max() ?? 0)
    }
}
