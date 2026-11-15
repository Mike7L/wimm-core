import Foundation
import XCTest
@testable import WimmSecretary

final class SecretaryPathResolverTests: XCTestCase {
    func testMatchesFoundationForLinksMissingFilesAndDotEntries() throws {
        // The temporary directory sits behind /var → /private/var, like a real symlinked workspace.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resolver-\(UUID().uuidString)")
        let library = root.appendingPathComponent("Library/Recordings")
        let docs = root.appendingPathComponent("ws/docs")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("ws/recordings"), withDestinationURL: library)
        for name in ["a.meta.json", "b.meta.json"] { try Data().write(to: library.appendingPathComponent(name)) }
        try FileManager.default.createSymbolicLink(at: library.appendingPathComponent("link.meta.json"),
                                                   withDestinationURL: library.appendingPathComponent("a.meta.json"))
        let paths = ["../recordings/a.meta.json", "../recordings/b.meta.json", "../recordings/link.meta.json",
                     "../recordings/missing.meta.json", "../recordings/./a.meta.json", "../recordings/..",
                     "../recordings/", "../ws/../ws/recordings/b.meta.json", "me.md", "../../nowhere/x.meta.json"]
        var resolver = SecretaryPathResolver()
        for _ in 0..<2 { // The second round answers from the folder cache.
            for path in paths {
                let expected = docs.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath().path
                XCTAssertEqual(resolver.resolve(path, relativeTo: docs), expected, path)
            }
            for name in ["a.meta.json", "link.meta.json", "missing.meta.json"] {
                let absolute = root.appendingPathComponent("ws/recordings").path + "/" + name
                XCTAssertEqual(resolver.resolve(absolute: absolute),
                               URL(fileURLWithPath: absolute).resolvingSymlinksInPath().path, name)
            }
        }
    }
}
