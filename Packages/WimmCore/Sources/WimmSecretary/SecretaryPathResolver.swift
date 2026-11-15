import Darwin
import Foundation

/// `base.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath().path`
/// for many paths in a few folders. Each folder is resolved once; a final component
/// that is itself a symbolic link, is missing or is a dot entry takes the full
/// Foundation path, so the result never differs from the per-path call. Resolving
/// every registry row that way cost ~8k URL resolutions per packet.
struct SecretaryPathResolver {
    private var folders: [String: String] = [:]
    private var relativeBase: String?
    /// Relative folder (`../recordings`) → resolved folder, for `relativeBase`.
    private var relativeFolders: [String: String] = [:]

    /// `relativeTo` + `path`, standardized and with symbolic links resolved.
    mutating func resolve(_ path: String, relativeTo base: URL) -> String {
        let basePath = base.path
        if relativeBase != basePath { relativeBase = basePath; relativeFolders = [:] }
        let name: String, folder: String
        if let slash = path.utf8.lastIndex(of: UInt8(ascii: "/")), !path.contains("//") {
            // What NSString's path methods return for a path without doubled or trailing slashes.
            name = String(path[path.index(after: slash)...]); folder = String(path[..<slash])
        } else if !path.contains("/") {
            name = path; folder = ""
        } else {
            let ns = path as NSString
            name = ns.lastPathComponent; folder = ns.deletingLastPathComponent
        }
        guard !path.hasPrefix("/"), !path.hasSuffix("/"), !name.isEmpty, name != ".", name != ".." else {
            return resolve(absolute: basePath + "/" + path, standardize: true)
        }
        let resolvedFolder: String
        if let known = relativeFolders[folder] { resolvedFolder = known } else {
            // The same folder resolution `resolve(absolute:)` makes for this path.
            resolvedFolder = URL(fileURLWithPath: (basePath + "/" + path as NSString).deletingLastPathComponent)
                .standardizedFileURL.resolvingSymlinksInPath().path
            relativeFolders[folder] = resolvedFolder
        }
        return Self.existingPlainFile(in: resolvedFolder, name: name)
            ?? URL(fileURLWithPath: basePath + "/" + path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The path when `name` exists in `folder` and is not a symbolic link.
    private static func existingPlainFile(in folder: String, name: String) -> String? {
        let candidate = (folder == "/" ? "" : folder) + "/" + name
        var info = stat()
        guard lstat(candidate, &info) == 0, (info.st_mode & S_IFMT) != S_IFLNK else { return nil }
        return candidate
    }

    /// `URL(fileURLWithPath: path)` (`standardizedFileURL` first when `standardize`) `.resolvingSymlinksInPath().path`.
    mutating func resolve(absolute path: String, standardize: Bool = false) -> String {
        func full(_ value: String) -> String {
            let url = URL(fileURLWithPath: value)
            return (standardize ? url.standardizedFileURL : url).resolvingSymlinksInPath().path
        }
        let ns = path as NSString
        let name = ns.lastPathComponent
        guard path.hasPrefix("/"), !path.hasSuffix("/"), !name.isEmpty, name != ".", name != ".." else { return full(path) }
        let folder = ns.deletingLastPathComponent
        let resolvedFolder: String
        if let known = folders[folder] { resolvedFolder = known } else {
            resolvedFolder = full(folder); folders[folder] = resolvedFolder
        }
        return Self.existingPlainFile(in: resolvedFolder, name: name) ?? full(path)
    }
}

/// Order-preserving map over all cores for pure per-element work (block terms of
/// a large document). Same results as `map`, in the same order.
enum SecretaryParallel {
    private final class Slots<T>: @unchecked Sendable {
        var values: [T?]
        init(_ count: Int) { values = Array(repeating: nil, count: count) }
    }

    static func map<T, U>(_ items: [T], minimumPerTask: Int = 256, _ transform: (T) -> U) -> [U] {
        let tasks = min(ProcessInfo.processInfo.activeProcessorCount, items.count / max(1, minimumPerTask))
        guard tasks > 1 else { return items.map(transform) }
        let slots = Slots<U>(items.count)
        slots.values.withUnsafeMutableBufferPointer { buffer in
            let out = UnsafeSendableBuffer(buffer)
            withoutActuallyEscaping(transform) { transform in
                let work = UnsafeSendableClosure(transform)
                DispatchQueue.concurrentPerform(iterations: tasks) { task in
                    let lower = items.count * task / tasks, upper = items.count * (task + 1) / tasks
                    for index in lower..<upper { out.buffer[index] = work.closure(items[index]) }
                }
            }
        }
        return slots.values.map { $0! }
    }

    private struct UnsafeSendableBuffer<U>: @unchecked Sendable { let buffer: UnsafeMutableBufferPointer<U?>; init(_ b: UnsafeMutableBufferPointer<U?>) { buffer = b } }
    private struct UnsafeSendableClosure<T, U>: @unchecked Sendable { let closure: (T) -> U; init(_ c: @escaping (T) -> U) { closure = c } }
}
