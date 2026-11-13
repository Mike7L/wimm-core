import Foundation

// Centralized error domain constants for network/service layers.
public enum ErrorDomain {
    // Provider-agnostic error identifiers
    public static let badStatus = "LLMBadStatus"
    public static let noText = "LLMNoText"
}
