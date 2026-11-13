import Foundation

/// Lightweight positional + flag CLI argument parser.
///
/// Usage:
/// ```swift
/// let p = ArgParser(args)
/// let limit = p.int("--limit")
/// let dry   = p.flag("--dry-run")
/// let text  = p.string("--text")
/// ```
struct ArgParser {
    private let args: [String]

    init(_ args: [String]) {
        self.args = args
    }

    /// Returns the value immediately following `flag`, or `nil` if not present.
    func string(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }

    /// Returns the integer value following `flag`, or `nil` if absent / non-numeric.
    func int(_ flag: String) -> Int? {
        guard let s = string(flag) else { return nil }
        return Int(s)
    }

    /// Returns `true` if `flag` is present anywhere in `args`.
    func flag(_ flag: String) -> Bool {
        args.contains(flag)
    }

    /// Returns the first value that follows any of the given flag aliases.
    func string(anyOf flags: String...) -> String? {
        flags.lazy.compactMap { string($0) }.first
    }

    /// Returns the integer value following any of the given flag aliases.
    func int(anyOf flags: String...) -> Int? {
        flags.lazy.compactMap { int($0) }.first
    }

    /// Returns `true` if any of the given flag aliases are present.
    func flag(anyOf flags: String...) -> Bool {
        flags.contains(where: { self.flag($0) })
    }
}
