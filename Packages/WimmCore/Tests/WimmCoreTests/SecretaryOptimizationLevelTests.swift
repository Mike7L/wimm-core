import Foundation
import XCTest
@testable import WimmInfrastructure
@testable import WimmSecretary

final class SecretaryOptimizationLevelTests: XCTestCase {
    func testOptimizationLevelDefaultsAndPersistence() throws {
        let name = "secretary-opt-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        XCTAssertEqual(SecretaryOptimizationLevel.preferred(defaults: defaults), .l0)
        defaults.set(SecretaryOptimizationLevel.l5.rawValue, forKey: SecretaryOptimizationLevel.defaultsKey)
        XCTAssertEqual(SecretaryOptimizationLevel.preferred(defaults: defaults), .l5)
        defaults.set(999, forKey: SecretaryOptimizationLevel.defaultsKey)
        XCTAssertEqual(SecretaryOptimizationLevel.preferred(defaults: defaults), .l0)
    }

    func testActualNativeHeadersAndRunQualityAreHandledSeparately() {
        let sample = """
        file: /fixture/image.png
        asr_quality[transcript]: {"status":"unknown","checks":"not_recorded"}
        --- image native observations (uncalibrated) ---
        {"tags":[{"identifier":"wood_processed","confidence":0.85}]}

        --- attachment 1 image native observations (uncalibrated) ---
        {"tags":[{"identifier":"structure","confidence":0.7}]}

        --- text ---
        Слова image diagnostics здесь являются буквальным текстом источника.
        """
        let l1 = SecretaryOptimization.filter(sample, level: .l1)
        XCTAssertTrue(l1.contains("asr_quality[transcript]"))
        let l2 = SecretaryOptimization.filter(sample, level: .l2)
        XCTAssertFalse(l2.contains("wood_processed"))
        XCTAssertFalse(l2.contains("structure"))
        XCTAssertTrue(l2.contains("asr_quality[transcript]"))
        XCTAssertTrue(SecretaryOptimization.filter(sample, level: .l3).contains("Слова image diagnostics"))
    }

    func testFilterProgressiveReduction() {
        let sample = """
        id: 12345
        date: 2026-10-25T12:00:00+02:00 (captured)
        kind: audio
        file: /Users/example/Recordings/sample.m4a
        meta: /Users/example/Recordings/sample.meta.json
        sha256: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        updated: 2026-10-25T12:00:00+02:00
        sync_updated: 2026-10-25T10:00:00.000Z
        mark: pending · source S100 · marked 2026-10-25

        text_scope: all_available_text — version receipts attest supplied text, not factual accuracy
        asr_quality[transcript]: {"status":"ok"}
        --- transcript (7 words) ---
        Согласовали бюджет проекта Маяк в 240 евро.

        --- refined (fallback copy) ---
        Согласовали бюджет проекта Маяк в 240 евро.

        --- copy --- = transcript

        --- native scene observations ---
        [{"identifier":"wood_processed","confidence":0.85}]

        --- image diagnostics ---
        {"status":"ok"}

        --- visual source roster (originals not supplied by this text read) ---
        image_index=1; source=/path/to/img.heic
        """

        let l0 = SecretaryOptimization.filter(sample, level: .l0)
        XCTAssertTrue(l0.contains("file: /Users/example"))
        XCTAssertTrue(l0.contains("wood_processed"))
        XCTAssertTrue(l0.contains("visual source roster"))

        let l1 = SecretaryOptimization.filter(sample, level: .l1)
        XCTAssertFalse(l1.contains("file: /Users/example"))
        XCTAssertFalse(l1.contains("visual source roster"))
        XCTAssertTrue(l1.contains("wood_processed"))

        let l2 = SecretaryOptimization.filter(sample, level: .l2)
        XCTAssertFalse(l2.contains("wood_processed"))
        XCTAssertFalse(l2.contains("text_scope: all_available_text"))
        XCTAssertTrue(l2.contains("image diagnostics"))

        let l3 = SecretaryOptimization.filter(sample, level: .l3)
        XCTAssertFalse(l3.contains("image diagnostics"))
        XCTAssertTrue(l3.contains("--- copy --- = transcript"))

        let l4 = SecretaryOptimization.filter(sample, level: .l4)
        XCTAssertFalse(l4.contains("--- copy --- = transcript"))
        XCTAssertTrue(l4.contains("Согласовали бюджет проекта Маяк в 240 евро."))

        let l5 = SecretaryOptimization.filter(sample, level: .l5)
        XCTAssertTrue(l5.contains("date: 2026-10-25T12:00:00+02:00"))
        XCTAssertTrue(l5.contains("mark: pending"))
        XCTAssertTrue(l5.contains("Согласовали бюджет проекта Маяк в 240 евро."))
        XCTAssertFalse(l5.contains("sha256"))
        XCTAssertFalse(l5.contains("wood_processed"))
    }
}
