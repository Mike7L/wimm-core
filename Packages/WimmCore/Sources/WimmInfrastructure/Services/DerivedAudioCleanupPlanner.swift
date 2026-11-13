import Foundation
import WimmDomain

/// Decides which derived-audio files (`_mini`, `_micro`, cascades such as `_micro_mini`)
/// `wimm-cli clean derived` may delete.
///
/// A derived file is only disposable while the recording it was derived from is still on
/// disk. On 2026-10-20 `clean derived --mini --force` deleted 1729 legacy `_mini` files
/// without checking, and for 267 notes that was the only audio left — `clean originals`
/// had deleted their originals earlier because the mini existed. So the rule here is
/// strict: a candidate is deletable only when a **non-derived audio** file with the same
/// session base sits in the same directory. A sidecar, `.txt`, image, or another derived
/// tier does not count — none of those is the recording.
public enum DerivedAudioCleanupPlanner {
    public struct Plan: Equatable, Sendable {
        /// Derived files whose original audio sibling exists.
        public var deletable: [URL]
        /// Derived files that are the only remaining audio of their note — never delete.
        public var orphans: [URL]
    }

    /// Whether `url` is a derived-audio file this cleanup targets. Cascades are always
    /// candidates; plain `_mini` only when `includeLegacyMini` is set. Plain `_micro` is
    /// the live tier and never a candidate.
    public static func isCandidate(_ url: URL, includeLegacyMini: Bool) -> Bool {
        guard FileStore.isAudioFile(url) else { return false }
        let base = url.deletingPathExtension().lastPathComponent
        if base.hasSuffix("_micro_mini") { return true }
        return includeLegacyMini && base.hasSuffix("_mini")
    }

    /// Splits candidates into deletable and orphan, reading each directory once.
    public static func plan(candidates: [URL], fileManager: FileManager = .default) -> Plan {
        var primaryBasesByDirectory: [String: Set<String>] = [:]
        var plan = Plan(deletable: [], orphans: [])
        for url in candidates {
            let directory = url.deletingLastPathComponent()
            let primaries: Set<String>
            if let cached = primaryBasesByDirectory[directory.path] {
                primaries = cached
            } else {
                primaries = primaryAudioBases(in: directory, fileManager: fileManager)
                primaryBasesByDirectory[directory.path] = primaries
            }
            let base = FileStore.strippingDerivedAudioSuffix(url.deletingPathExtension().lastPathComponent)
            if primaries.contains(base) {
                plan.deletable.append(url)
            } else {
                plan.orphans.append(url)
            }
        }
        return plan
    }

    /// Session bases of the non-derived audio files directly inside `directory`.
    /// An unreadable directory yields an empty set, so every candidate in it is kept;
    /// a zero-byte "original" is not a recording and does not count either.
    static func primaryAudioBases(in directory: URL, fileManager: FileManager) -> Set<String> {
        let items = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var bases = Set<String>()
        for item in items where FileStore.isAudioFile(item) && !FileStore.isDerivedAudioFile(item) {
            guard let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { continue }
            bases.insert(item.deletingPathExtension().lastPathComponent)
        }
        return bases
    }
}
