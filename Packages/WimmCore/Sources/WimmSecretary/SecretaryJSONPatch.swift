import Foundation
import WimmInfrastructure

/// Edits selected JSON spans; untouched rows/history keep their original bytes and order.
/// JSONSerialization validates the document; this scanner only locates its values.
struct SecretaryJSONPatch {
    let bytes: [UInt8]
    init(_ data: Data) throws {
        _ = try JSONSerialization.jsonObject(with: data)
        bytes = Array(data)
    }
    struct Member { let key: String; let value: Range<Int> }
    func members(_ range: Range<Int>) throws -> [Member] {
        var i = skip(range.lowerBound)
        guard bytes[i] == 123 else { throw Failure() }
        i = skip(i + 1)
        var result: [Member] = []
        while bytes[i] != 125 {
            let keyStart = i; i = try end(i)
            let keyData = Data([91]) + Data(bytes[keyStart..<i]) + Data([93])
            guard let key = (try JSONSerialization.jsonObject(with: keyData) as? [String])?.first else { throw Failure() }
            i = skip(i); guard bytes[i] == 58 else { throw Failure() }; i = skip(i + 1)
            let start = i; i = try end(i)
            result.append(Member(key: key, value: start..<i))
            i = skip(i)
            if bytes[i] == 44 { i = skip(i + 1) } else if bytes[i] != 125 { throw Failure() }
        }
        return result
    }
    func elements(_ range: Range<Int>) throws -> [Range<Int>] {
        var i = skip(range.lowerBound)
        guard bytes[i] == 91 else { throw Failure() }; i = skip(i + 1)
        var result: [Range<Int>] = []
        while bytes[i] != 93 {
            let start = i; i = try end(i); result.append(start..<i); i = skip(i)
            if bytes[i] == 44 { i = skip(i + 1) } else if bytes[i] != 93 { throw Failure() }
        }
        return result
    }
    func applying(_ edits: [(Range<Int>, Data)]) throws -> Data {
        var result = Data(bytes), lower = bytes.count
        for (range, replacement) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            guard range.upperBound <= lower else { throw Failure() }
            result.replaceSubrange(range, with: replacement); lower = range.lowerBound
        }
        _ = try JSONSerialization.jsonObject(with: result)
        return result
    }
    static func encode(_ value: Any, indent: Int = 0) throws -> Data {
        let raw = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        let string = String(decoding: raw, as: UTF8.self).replacingOccurrences(of: "\n", with: "\n" + String(repeating: " ", count: indent))
        return Data(string.utf8)
    }
    func indentation(at index: Int) -> Int {
        var start = index
        while start > 0 && bytes[start - 1] != 10 { start -= 1 }
        return bytes[start..<index].prefix(while: { $0 == 32 }).count
    }
    private func skip(_ index: Int) -> Int {
        var i = index
        while i < bytes.count && [9, 10, 13, 32].contains(bytes[i]) { i += 1 }
        return i
    }
    private func end(_ index: Int) throws -> Int {
        guard index < bytes.count else { throw Failure() }
        if bytes[index] == 34 {
            var i = index + 1
            while i < bytes.count {
                if bytes[i] == 92 { i += 2; continue }
                if bytes[i] == 34 { return i + 1 }; i += 1
            }
            throw Failure()
        }
        if bytes[index] == 123 || bytes[index] == 91 {
            let close: UInt8 = bytes[index] == 123 ? 125 : 93
            var i = skip(index + 1)
            while i < bytes.count {
                if bytes[i] == close { return i + 1 }
                if bytes[i] == 44 || bytes[i] == 58 { i = skip(i + 1); continue }
                i = skip(try end(i))
            }
            throw Failure()
        }
        var i = index
        while i < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[i]) { i += 1 }
        guard i > index else { throw Failure() }; return i
    }
    private struct Failure: LocalizedError { var errorDescription: String? { "Cannot safely patch registry JSON." } }
}
