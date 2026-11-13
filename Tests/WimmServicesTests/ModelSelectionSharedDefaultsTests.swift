import XCTest
import WimmInfrastructure
import WimmDomain
import WimmInfrastructure

final class ModelSelectionSharedDefaultsTests: XCTestCase {
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "wimm.modelselection.tests.\(UUID().uuidString)"
        setenv("WIMM_DEFAULTS_SUITE", suiteName, 1)
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        if let suiteName {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        unsetenv("WIMM_DEFAULTS_SUITE")
        super.tearDown()
    }

    func testHearModelReadsFromSharedSuiteBeforeEnvironment() {
        let suite = UserDefaults(suiteName: suiteName)
        suite?.set("gemini-2.5-flash", forKey: DefaultsKey.capabilityHearModel)
        setenv("OPENROUTER_MODEL", "openai/gpt-oss-20b:free", 1)
        defer { unsetenv("OPENROUTER_MODEL") }

        let model = ModelSelection.model(for: .hear)
        XCTAssertEqual(model, "gemini-2.5-flash")
    }

    func testSetModelWritesToSharedSuite() {
        ModelSelection.setModel("openai/gpt-4o-mini", for: .hear)
        let suite = UserDefaults(suiteName: suiteName)
        XCTAssertEqual(
            suite?.string(forKey: DefaultsKey.capabilityHearModel),
            "openai/gpt-4o-mini"
        )
    }

    func testResolveCopiesStandardHearModelIntoSharedSuite() {
        UserDefaults.standard.set("gemini-2.5-pro", forKey: DefaultsKey.capabilityHearModel)
        defer { UserDefaults.standard.removeObject(forKey: DefaultsKey.capabilityHearModel) }

        let model = ModelSelection.model(for: .hear)
        XCTAssertEqual(model, "gemini-2.5-pro")

        let suite = UserDefaults(suiteName: suiteName)
        XCTAssertEqual(
            suite?.string(forKey: DefaultsKey.capabilityHearModel),
            "gemini-2.5-pro"
        )
    }

    /// Without an explicit suite a test process must never reach the real
    /// app settings — that is how test runs kept resetting the macOS app's
    /// transcription model to `gemini-2.5-flash`.
    func testTestProcessNeverWritesTheRealAppSuite() {
        unsetenv("WIMM_DEFAULTS_SUITE")
        XCTAssertNotEqual(SharedUserDefaults.suiteName, SharedUserDefaults.defaultSuiteName)

        let real = UserDefaults(suiteName: SharedUserDefaults.defaultSuiteName)
        let before = real?.string(forKey: DefaultsKey.capabilityHearModel)
        ModelSelection.setModel("test/never-in-real-suite", for: .hear)
        defer { UserDefaults.standard.removeObject(forKey: DefaultsKey.capabilityHearModel) }

        XCTAssertEqual(real?.string(forKey: DefaultsKey.capabilityHearModel), before)
        XCTAssertEqual(ModelSelection.model(for: .hear), "test/never-in-real-suite")
    }
}
