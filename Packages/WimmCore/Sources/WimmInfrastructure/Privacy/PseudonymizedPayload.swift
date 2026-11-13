import Foundation

/// The egress copy of one LLM request: masked user payload plus the map that
/// restores the answer. JSON payloads are masked value by value (keys stay),
/// so an escape sequence such as `\n` never glues itself to a name and a
/// restored value is re-escaped on the way back.
public struct PseudonymizedPayload: Sendable {
    public let user: String
    public let map: PseudonymMap

    /// The egress copy. Throws `outboundLeak` when the re-scan still finds
    /// an identifier: such a request is never sent.
    public static func mask(user: String, filter: PseudonymFilter,
                            session: PseudonymSession = PseudonymSession()) throws -> PseudonymizedPayload {
        let inspection = try inspect(user: user, filter: filter, session: session)
        guard inspection.leakKinds.isEmpty else {
            throw PseudonymizationError.outboundLeak(kinds: inspection.leakKinds)
        }
        return inspection.payload
    }

    /// Masking plus the outbound re-scan verdict, without acting on it. `mask`
    /// is built on this, so the local preview shows exactly what egress would
    /// send (or why it would block).
    public struct Inspection: Sendable {
        public let payload: PseudonymizedPayload
        /// Token letters of identifiers the re-scan still finds; empty means it would be sent.
        public let leakKinds: [String]
    }

    public static func inspect(user: String, filter: PseudonymFilter,
                               session: PseudonymSession = PseudonymSession()) throws -> Inspection {
        var leaks = Set<String>()
        let collect: (String) -> Void = { text in
            leaks.formUnion(filter.detect(in: text).map(\.kind.rawValue))
        }
        let masked: String
        if let object = jsonObject(user) {
            let maskedObject = try mapStrings(object) { try filter.mask($0, session: session) }
            forEachString(maskedObject, collect)
            masked = try jsonString(maskedObject)
        } else {
            masked = try filter.mask(user, session: session)
            collect(masked)
        }
        return Inspection(payload: PseudonymizedPayload(user: masked, map: session.map), leakKinds: leaks.sorted())
    }

    /// Inbound guard and restore. A JSON answer (bare or fenced) is restored
    /// value by value and returned as plain JSON; anything else as text.
    public func unmask(response: String) throws -> String {
        if let object = Self.jsonObject(response) ?? Self.jsonObject(LLMText.stripFences(response)) {
            let restored = try Self.mapStrings(object) { try PseudonymFilter.unmask($0, map: map) }
            // Keys come from the model too; a token there is still a token.
            try Self.forEachKey(restored) { _ = try PseudonymFilter.unmask($0, map: map) }
            return try Self.jsonString(restored)
        }
        return try PseudonymFilter.unmask(response, map: map)
    }

    // MARK: JSON walking

    static func jsonObject(_ text: String) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["), let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func jsonString(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }

    static func mapStrings(_ object: Any, _ transform: (String) throws -> String) rethrows -> Any {
        switch object {
        case let string as String:
            return try transform(string)
        case let dictionary as [String: Any]:
            var result: [String: Any] = [:]
            for (key, value) in dictionary { result[key] = try mapStrings(value, transform) }
            return result
        case let array as [Any]:
            return try array.map { try mapStrings($0, transform) }
        default:
            return object
        }
    }

    static func forEachString(_ object: Any, _ body: (String) throws -> Void) rethrows {
        _ = try mapStrings(object) { try body($0); return $0 }
    }

    static func forEachKey(_ object: Any, _ body: (String) throws -> Void) rethrows {
        switch object {
        case let dictionary as [String: Any]:
            for (key, value) in dictionary {
                try body(key)
                try forEachKey(value, body)
            }
        case let array as [Any]:
            for value in array { try forEachKey(value, body) }
        default:
            break
        }
    }
}
