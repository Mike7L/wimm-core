import AppKit
import SwiftUI

/// A single lazy list must own the rows. Nested eager stacks defeat viewport virtualization.
public enum DocumentOutline {
    /// Body blocks sit one step inside their heading, even in the flat lazy list.
    /// Hidden blocks never change the active section; pre-heading text stays at the root.
    public static func indentationLevels(levels: [Int?]) -> [Int] {
        var section = 0
        var hasHeading = false
        return levels.map { level in
            if let level, level > 0 {
                section = max(0, level - 2)
                hasHeading = true
            }
            return level == nil && hasHeading ? section + 1 : section
        }
    }

    /// nil is a body block, -1 hidden, 1 the always-open document title.
    public static func visibleIndices(levels: [Int?], expanded: Set<Int>, ids: [Int]) -> [Int] {
        precondition(levels.count == ids.count)
        var result: [Int] = []
        var collapsedLevel: Int?
        for i in levels.indices {
            let level = levels[i]
            if level == -1 { continue }
            if let level {
                if let collapsedLevel, level > collapsedLevel { continue }
                collapsedLevel = nil
                result.append(i)
                if level > 1, !expanded.contains(ids[i]) { collapsedLevel = level }
            } else if collapsedLevel == nil { result.append(i) }
        }
        return result
    }
}

/// Bound both the retained text and number of blocks; keys include all visual inputs.
@MainActor public enum DocumentRenderCache {
    private static let cache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 256
        cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()
    public static func attributed(key: String, render: () -> NSAttributedString?) -> NSAttributedString? {
        if DocumentDiagnostics.reference { DocumentDiagnostics.rendered(); return render() }
        if let value = cache.object(forKey: key as NSString) {
            if DocumentDiagnostics.enabled { DocumentDiagnostics.renderHits += 1 }
            return value
        }
        DocumentDiagnostics.rendered()
        guard let rendered = render() else { return nil }
        let immutable = NSAttributedString(attributedString: rendered)
        cache.setObject(immutable, forKey: key as NSString, cost: immutable.length * 4 + 256)
        return immutable
    }
    public static func removeAll() { cache.removeAllObjects() }
}
