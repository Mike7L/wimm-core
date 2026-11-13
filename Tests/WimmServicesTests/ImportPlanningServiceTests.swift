import XCTest
import WimmDomain
import WimmInfrastructure

final class ImportPlanningServiceTests: XCTestCase {
    private var baseDir: URL!

    override func setUp() {
        super.setUp()
        baseDir = FileManager.default.temporaryDirectory.appendingPathComponent("WimmImportPlanningTests_" + UUID().uuidString)
        setenv("WIMM_BASE_DIR", baseDir.path, 1)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: FileStore.recordingsDirectory(), withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let baseDir {
            try? FileManager.default.removeItem(at: baseDir)
        }
        super.tearDown()
    }

    func testCollectCandidatesIncludesNestedFilesRecursively() throws {
        let service = ImportPlanningService()
        let input = baseDir.appendingPathComponent("input")
        let nested = input.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let topFile = input.appendingPathComponent("a.txt")
        let nestedFile = nested.appendingPathComponent("b.pdf")
        try "a".write(to: topFile, atomically: true, encoding: .utf8)
        try Data([1, 2]).write(to: nestedFile)

        let candidates = service.collectCandidates(from: [input])
        let names = Set(candidates.map(\.lastPathComponent))
        XCTAssertTrue(names.contains(topFile.lastPathComponent))
        XCTAssertTrue(names.contains(nestedFile.lastPathComponent))
    }

    func testCollectCandidatesDedupesSameInputPath() throws {
        let service = ImportPlanningService()
        let input = baseDir.appendingPathComponent("input_dedupe")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let topFile = input.appendingPathComponent("same.txt")
        try "a".write(to: topFile, atomically: true, encoding: .utf8)

        let candidates = service.collectCandidates(from: [topFile, topFile])
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.path, topFile.path)
    }

    func testCollectCandidatesReportsFinalScanProgress() throws {
        let service = ImportPlanningService()
        let input = baseDir.appendingPathComponent("input_progress")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        for index in 0..<31 {
            try "file \(index)".write(
                to: input.appendingPathComponent("\(index).txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        let recorder = ScanProgressRecorder()
        let candidates = service.collectCandidates(from: [input]) { found, currentURL in
            recorder.append(found: found, currentURL: currentURL)
        }
        let updates = recorder.snapshot()

        XCTAssertEqual(candidates.count, 31)
        XCTAssertEqual(updates.last?.0, 31)
        XCTAssertEqual(updates.last?.1?.path, candidates.last?.path)
        XCTAssertTrue(updates.contains(where: { $0.0 == 25 }))
    }

    func testPlanDetectsAlreadyImportedAndSelectionDuplicates() throws {
        let service = ImportPlanningService()
        let recordings = FileStore.recordingsDirectory()
        let existing = recordings.appendingPathComponent("existing.txt")
        try "same".write(to: existing, atomically: true, encoding: .utf8)

        let input = baseDir.appendingPathComponent("input2")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)

        let sameAsExisting = input.appendingPathComponent("dup_existing.txt")
        let dupA = input.appendingPathComponent("dup_a.txt")
        let dupB = input.appendingPathComponent("dup_b.txt")
        let unsupported = input.appendingPathComponent("blob.xyz")
        try "same".write(to: sameAsExisting, atomically: true, encoding: .utf8)
        try "pair".write(to: dupA, atomically: true, encoding: .utf8)
        try "pair".write(to: dupB, atomically: true, encoding: .utf8)
        try "x".write(to: unsupported, atomically: true, encoding: .utf8)

        let candidates = service.collectCandidates(from: [input])
        let plan = service.plan(from: candidates)

        XCTAssertEqual(plan.totalCount, 4)
        XCTAssertEqual(plan.duplicateCount, 2)

        let textGroup = plan.groups.first(where: { $0.kind == .text })
        XCTAssertNotNil(textGroup)
        XCTAssertEqual(textGroup?.urls.count, 1)
        XCTAssertEqual(textGroup?.duplicates.count, 2)
        XCTAssertTrue(textGroup?.duplicates.contains(where: { $0.reason == .alreadyImported }) == true)
        XCTAssertTrue(textGroup?.duplicates.contains(where: { $0.reason == .duplicateInSelection }) == true)

        let otherGroup = plan.groups.first(where: { $0.kind == .other })
        XCTAssertEqual(otherGroup?.urls.count, 1)
    }

    func testPlanDoesNotFlagSameSizeDifferentContentAsDuplicate() throws {
        // The size prefilter must fall through to hashing: equal byte size
        // with different content is not a duplicate.
        let service = ImportPlanningService()
        let recordings = FileStore.recordingsDirectory()
        let existing = recordings.appendingPathComponent("existing.txt")
        try "aaaa".write(to: existing, atomically: true, encoding: .utf8)

        let input = baseDir.appendingPathComponent("input3")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)

        let sameSize = input.appendingPathComponent("same_size.txt")      // 4 bytes, differs
        let uniqueSize = input.appendingPathComponent("unique_size.txt")  // no size collision
        try "bbbb".write(to: sameSize, atomically: true, encoding: .utf8)
        try "unique content".write(to: uniqueSize, atomically: true, encoding: .utf8)

        let plan = service.plan(from: [sameSize, uniqueSize])

        XCTAssertEqual(plan.duplicateCount, 0)
        let textGroup = plan.groups.first(where: { $0.kind == .text })
        XCTAssertEqual(textGroup?.urls.count, 2)
        XCTAssertEqual(textGroup?.duplicates.count, 0)
    }
}

private final class ScanProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [(Int, URL?)] = []

    func append(found: Int, currentURL: URL?) {
        lock.lock()
        updates.append((found, currentURL))
        lock.unlock()
    }

    func snapshot() -> [(Int, URL?)] {
        lock.lock()
        defer { lock.unlock() }
        return updates
    }
}
