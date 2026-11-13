import Foundation

/// Sampling overrides are deprecated for Gemini 3.x, regardless of whether
/// requests go directly to Google or through OpenRouter. Keep older Gemini
/// models and other providers' explicitly selected settings intact.
public enum ModelSampling {
    public static func temperature(_ requested: Double?, model: String) -> Double? {
        let name = model.lowercased().split(separator: "/").last.map(String.init) ?? ""
        if name == "gemini-3" || name.hasPrefix("gemini-3.") || name.hasPrefix("gemini-3-") { return nil }
        return requested
    }
}
