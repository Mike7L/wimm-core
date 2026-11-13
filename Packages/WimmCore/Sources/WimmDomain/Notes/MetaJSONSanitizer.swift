import Foundation

public extension FileStore {
    /// Keys that are considered redundant and should no longer be written to `.meta.json`,
    /// because they can be derived from file/embedded metadata.
    static let redundantMetaJSONKeys: Set<String> = [
        "createdAt",
        "importedAt",
        "duration"
    ]

    /// Removes redundant keys from updates (recursively), preserving backward compatibility:
    /// - Existing `.meta.json` files may still contain these keys.
    /// - We simply stop writing/overwriting them for new updates.
    static func sanitizeMetaJSONUpdates(_ updates: [String: Any]) -> [String: Any] {
        sanitizeMetaJSONDictionary(updates)
    }
}

private func sanitizeMetaJSONDictionary(_ dict: [String: Any]) -> [String: Any] {
    var out: [String: Any] = [:]
    out.reserveCapacity(dict.count)
    for (key, value) in dict {
        guard !FileStore.redundantMetaJSONKeys.contains(key) else { continue }
        out[key] = sanitizeMetaJSONValue(value)
    }
    return out
}

private func sanitizeMetaJSONValue(_ value: Any) -> Any {
    if let dict = value as? [String: Any] {
        return sanitizeMetaJSONDictionary(dict)
    }
    if let array = value as? [Any] {
        return array.map(sanitizeMetaJSONValue(_:))
    }
    return value
}

