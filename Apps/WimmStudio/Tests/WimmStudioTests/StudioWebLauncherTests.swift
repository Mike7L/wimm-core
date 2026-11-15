import XCTest
@testable import WimmStudio

final class StudioWebLauncherTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioWebLauncherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeExecutable(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func testNodeVersionsCompareNumerically() {
        XCTAssertGreaterThan(StudioWebLauncher.compareNodeVersions("v22.13.0", "v22.9.1"), 0)
        XCTAssertGreaterThan(StudioWebLauncher.compareNodeVersions("v24.0.0", "v22.13.0"), 0)
        XCTAssertLessThan(StudioWebLauncher.compareNodeVersions("v18.20.0", "v20.1.0"), 0)
        XCTAssertEqual(StudioWebLauncher.compareNodeVersions("v22.6", "v22.6.0"), 0)
    }

    func testOverrideComesFirstThenNewestNvm() throws {
        let home = tmp.appendingPathComponent("home")
        for version in ["v20.1.0", "v22.13.0", "v22.9.0"] {
            try makeExecutable(home.appendingPathComponent(".nvm/versions/node/\(version)/bin/node"))
        }
        let candidates = StudioWebLauncher.nodeCandidates(override: "/custom/node", home: home)
        XCTAssertEqual(candidates.first, "/custom/node")
        let nvm = candidates.filter { $0.contains(".nvm") }
        XCTAssertEqual(nvm.map { URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().lastPathComponent },
                       ["v22.13.0", "v22.9.0", "v20.1.0"])
        XCTAssertLessThan(candidates.firstIndex(of: "/opt/homebrew/bin/node")!, candidates.firstIndex(of: nvm[0])!)
    }

    func testFindNodeSkipsMissingOverride() throws {
        let home = tmp.appendingPathComponent("home")
        let override = tmp.appendingPathComponent("bin/node")
        try makeExecutable(override)
        XCTAssertEqual(StudioWebLauncher.findNode(override: override.path, home: home), override.path)
        // A missing override falls through to the system/nvm locations rather than failing.
        let found = StudioWebLauncher.findNode(override: tmp.appendingPathComponent("nope").path, home: home)
        XCTAssertNotEqual(found, tmp.appendingPathComponent("nope").path)
    }

    func testSetupProblemAsksForBuildWhenDistIsMissing() throws {
        let web = tmp.appendingPathComponent("web")
        XCTAssertNotNil(StudioWebLauncher.setupProblem(directory: web))
        try FileManager.default.createDirectory(at: web.appendingPathComponent("server"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: web.appendingPathComponent("package.json").path, contents: Data("{}".utf8))
        FileManager.default.createFile(atPath: web.appendingPathComponent("server/start.ts").path, contents: Data())
        let problem = try XCTUnwrap(StudioWebLauncher.setupProblem(directory: web))
        XCTAssertTrue(problem.contains(StudioWebLauncher.setupCommand), problem)
        try FileManager.default.createDirectory(at: web.appendingPathComponent("dist"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: web.appendingPathComponent("dist/index.html").path, contents: Data())
        XCTAssertNil(StudioWebLauncher.setupProblem(directory: web))
    }

    func testServerRunsStartScriptWithoutShell() {
        XCTAssertEqual(StudioWebLauncher.serverArguments.last, "server/start.ts")
        XCTAssertFalse(StudioWebLauncher.serverArguments.contains("-ilc"))
    }

    func testEnvironmentPutsNodeFolderOnPath() {
        let env = StudioWebLauncher.serverEnvironment(
            nodePath: "/Users/x/.nvm/versions/node/v22.13.0/bin/node",
            base: ["PATH": "/usr/bin:/bin", "HOME": "/Users/x"]
        )
        XCTAssertEqual(env["HOME"], "/Users/x")
        XCTAssertEqual(env["PATH"], "/Users/x/.nvm/versions/node/v22.13.0/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
    }
}
