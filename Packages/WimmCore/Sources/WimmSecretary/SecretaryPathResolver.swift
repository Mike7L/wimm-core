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
    /// Resolved folder → names in it that are not symbolic links (`nil`: unlistable).
    private var plainNames: [String: Set<String>?] = [:]

    /// `relativeTo` + `path`, standardized and with symbolic links resolved.
    mutating func resolve(_ path: String, relativeTo base: URL) -> String {
        resolve(path, relativeTo: base.path)
    }

    mutating func resolve(_ path: String, relativeTo basePath: String) -> String {
        if relativeBase != basePath { relativeBase = basePath; relativeFolders = [:] }
        let utf8 = path.utf8, slash = UInt8(ascii: "/")
        func full() -> String { URL(fileURLWithPath: basePath + "/" + path).standardizedFileURL.resolvingSymlinksInPath().path }
        guard utf8.first != slash, utf8.last != slash, !Self.hasDoubleSlash(utf8) else { return full() }
        let name: String, folder: String
        if let last = utf8.lastIndex(of: slash) {
            // What NSString's path methods return for a path without doubled or trailing slashes.
            name = String(path[utf8.index(after: last)...]); folder = String(path[..<last])
        } else { name = path; folder = "" }
        guard !name.isEmpty, name != ".", name != ".." else { return full() }
        let resolvedFolder: String
        if let known = relativeFolders[folder] { resolvedFolder = known } else {
            // The same folder resolution the per-path call makes for this path.
            resolvedFolder = URL(fileURLWithPath: (basePath + "/" + path as NSString).deletingLastPathComponent)
                .standardizedFileURL.resolvingSymlinksInPath().path
            relativeFolders[folder] = resolvedFolder
        }
        return plainFile(in: resolvedFolder, name: name) ?? full()
    }

    private static func hasDoubleSlash(_ utf8: String.UTF8View) -> Bool {
        var previous: UInt8 = 0
        for byte in utf8 { if byte == 0x2F, previous == 0x2F { return true }; previous = byte }
        return false
    }

    /// The path when `name` exists in `folder` and is not a symbolic link. One
    /// directory listing per folder answers what an `lstat` per row did.
    private mutating func plainFile(in folder: String, name: String) -> String? {
        let candidate = (folder == "/" ? "" : folder) + "/" + name
        if plainNames[folder] == nil { plainNames[folder] = Self.listPlainNames(folder) }
        if let names = plainNames[folder]!, names.contains(name) { return candidate }
        // Not listed (new since, or an unknown entry type): ask the file system directly.
        var info = stat()
        guard lstat(candidate, &info) == 0, (info.st_mode & S_IFMT) != S_IFLNK else { return nil }
        return candidate
    }

    private static func listPlainNames(_ folder: String) -> Set<String>? {
        guard let directory = opendir(folder) else { return nil }
        defer { closedir(directory) }
        var names = Set<String>()
        while let entry = readdir(directory) {
            // DT_UNKNOWN and links stay out; `plainFile` checks those with `lstat`.
            guard entry.pointee.d_type != UInt8(DT_LNK), entry.pointee.d_type != UInt8(DT_UNKNOWN) else { continue }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            names.insert(name)
        }
        return names
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
        return plainFile(in: resolvedFolder, name: name) ?? full(path)
    }
}
