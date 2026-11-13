import Foundation

/// The shared default ISO-8601 formatter — `ISO8601DateFormatter()` with its
/// default options (`.withInternetDateTime`, e.g. `2026-10-05T01:32:52Z`).
///
/// The codebase used to build a fresh `ISO8601DateFormatter()` at each call
/// site — 29 of them, several on per-note paths (sidecar writes, transcription
/// receipts, trash markers, exports). Creating one is far more expensive than
/// using one. Output is identical: these are the same options.
///
/// Two shapes are shared: the default, and `.withFractionalSeconds`. Any other
/// configuration (date-only, say) keeps its own instance.
public enum ISO8601 {
    // `ISO8601DateFormatter` is documented thread-safe for formatting and
    // parsing once configured, but is not `Sendable`; it is never mutated here.
    nonisolated(unsafe) private static let formatter = ISO8601DateFormatter()
    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    public static func date(from string: String) -> Date? {
        formatter.date(from: string)
    }

    /// The current time, formatted.
    public static var now: String { string(from: Date()) }

    /// `2026-10-05T01:32:52.512Z` — the variant every log line and every
    /// sync timestamp uses; both used to build a formatter per call.
    public static func stringWithFractionalSeconds(from date: Date) -> String {
        fractionalFormatter.string(from: date)
    }

    public static func dateWithFractionalSeconds(from string: String) -> Date? {
        fractionalFormatter.date(from: string)
    }

    /// Parses either shape — fractional seconds first, then plain. Sidecars
    /// written over the years carry both.
    public static func parseEither(_ string: String) -> Date? {
        dateWithFractionalSeconds(from: string) ?? date(from: string)
    }
}
