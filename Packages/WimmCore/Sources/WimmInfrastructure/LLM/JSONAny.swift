import Foundation

// A unified Codable wrapper for JSON-like values used across requests/responses.
// Replaces previous AnyEncodable/AnyCodable duplicates. Keep compatibility via typealias.
public struct JSONAny: Codable {
    public let value: Any

    public init(_ value: Any) { self.value = value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self.value = NSNull(); return }
        if let b = try? c.decode(Bool.self) { self.value = b; return }
        if let i = try? c.decode(Int.self) { self.value = i; return }
        if let d = try? c.decode(Double.self) { self.value = d; return }
        if let s = try? c.decode(String.self) { self.value = s; return }
        if let arr = try? c.decode([JSONAny].self) { self.value = arr.map { $0.value }; return }
        if let dict = try? c.decode([String: JSONAny].self) { self.value = dict.mapValues { $0.value }; return }
        throw DecodingError.typeMismatch(JSONAny.self, .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON type"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull: try c.encodeNil()
        case let b as Bool: try c.encode(b)
        case let i as Int: try c.encode(i)
        case let d as Double: try c.encode(d)
        case let s as String: try c.encode(s)
        case let arr as [Any]: try c.encode(arr.map { JSONAny($0) })
        case let dict as [String: Any]: try c.encode(dict.mapValues { JSONAny($0) })
        default: try c.encode(String(describing: value))
        }
    }
}

// Compatibility alias while refactoring existing call sites.
public typealias AnyEncodable = JSONAny
