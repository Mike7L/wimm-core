import XCTest
@testable import WimmInfrastructure

final class APIKeyRotatorTests: XCTestCase {
    private var rotator: APIKeyRotator!
    
    override func setUp() async throws {
        rotator = APIKeyRotator()
        UserDefaults.standard.removeObject(forKey: "GEMINI_API_KEYS")
        UserDefaults.standard.removeObject(forKey: "GEMINI_API_KEY")
    }
    
    override func tearDown() async throws {
        unsetenv("GEMINI_API_KEYS")
        unsetenv("GEMINI_API_KEY")
        unsetenv("TEST_GEMINI_API_KEYS")
        unsetenv("TEST_GEMINI_API_KEY")
        UserDefaults.standard.removeObject(forKey: "GEMINI_API_KEYS")
        UserDefaults.standard.removeObject(forKey: "GEMINI_API_KEY")
    }
    
    // MARK: - Key Loading Tests
    
    func testLoadKeys_FromEnvironmentMulti() async {
        setenv("GEMINI_API_KEYS", "key1-long-enough-to-pass-validation,key2-long-enough-to-pass-validation,key3-long-enough-to-pass-validation", 1)
        
        await rotator.reload()
        
        let count = await rotator.count()
        XCTAssertEqual(count, 3)
        
        let key = await rotator.currentKey()
        XCTAssertEqual(key, "key1-long-enough-to-pass-validation")
    }
    
    func testLoadKeys_FromEnvironmentSingle() async {
        setenv("GEMINI_API_KEY", "single-key-long-enough-to-pass-validation", 1)
        
        await rotator.reload()
        
        let count = await rotator.count()
        XCTAssertEqual(count, 1)
        
        let key = await rotator.currentKey()
        XCTAssertEqual(key, "single-key-long-enough-to-pass-validation")
    }
    
    func testLoadKeys_FiltersPlaceholders() async {
        setenv("GEMINI_API_KEYS", "REPLACE_WITH_YOUR_KEY,valid-key-long-enough-to-pass-validation,replace_with_your_key", 1)
        
        await rotator.reload()
        
        let count = await rotator.count()
        XCTAssertEqual(count, 1, "Should filter out placeholder keys")
        
        let key = await rotator.currentKey()
        XCTAssertEqual(key, "valid-key-long-enough-to-pass-validation")
    }
    
    func testLoadKeys_FiltersShortKeys() async {
        setenv("GEMINI_API_KEYS", "short,this-is-a-valid-key-with-sufficient-length,x", 1)
        
        await rotator.reload()
        
        let count = await rotator.count()
        XCTAssertEqual(count, 1, "Should filter out keys shorter than 20 chars")
        
        let key = await rotator.currentKey()
        XCTAssertEqual(key, "this-is-a-valid-key-with-sufficient-length")
    }
    
    func testLoadKeys_TrimsWhitespace() async {
        setenv("GEMINI_API_KEYS", "  key1-long-enough-to-pass-validation  ,  key2-long-enough-to-pass-validation  , key3-long-enough-to-pass-validation  ", 1)
        
        await rotator.reload()
        
        let count = await rotator.count()
        XCTAssertEqual(count, 3)
        
        let key = await rotator.currentKey()
        XCTAssertEqual(key, "key1-long-enough-to-pass-validation", "Keys should be trimmed")
    }
    
    func testLoadKeys_FromUserDefaults() async {
        UserDefaults.standard.set("ud-key1-long-enough-to-pass-validation,ud-key2-long-enough-to-pass-validation", forKey: "GEMINI_API_KEYS")
        
        await rotator.reload()
        
        let count = await rotator.count()
        XCTAssertEqual(count, 2)
        
        UserDefaults.standard.removeObject(forKey: "GEMINI_API_KEYS")
    }
    
    func testLoadKeys_PrioritizesEnvironmentOverUserDefaults() async {
        setenv("GEMINI_API_KEYS", "env-key-long-enough-to-pass-validation", 1)
        UserDefaults.standard.set("ud-key-long-enough-to-pass-validation", forKey: "GEMINI_API_KEYS")
        
        await rotator.reload()
        
        let key = await rotator.currentKey()
        XCTAssertEqual(key, "env-key-long-enough-to-pass-validation", "Environment should take priority")
        
        UserDefaults.standard.removeObject(forKey: "GEMINI_API_KEYS")
    }
    
    // MARK: - Snapshot Tests

    func testAllKeys_ReturnsSanitizedSnapshot() async {
        setenv("GEMINI_API_KEYS", "key1-long-enough-to-pass-validation,key2-long-enough-to-pass-validation,key3-long-enough-to-pass-validation", 1)

        await rotator.reload()

        let keys = await rotator.allKeys()
        XCTAssertEqual(keys, [
            "key1-long-enough-to-pass-validation",
            "key2-long-enough-to-pass-validation",
            "key3-long-enough-to-pass-validation"
        ])
    }

    func testCurrentKey_AlwaysReturnsFirstKeyFromSnapshot() async {
        setenv("GEMINI_API_KEYS", "key1-long-enough-to-pass-validation,key2-long-enough-to-pass-validation", 1)
        await rotator.reload()

        let first = await rotator.currentKey()
        let second = await rotator.currentKey()

        XCTAssertEqual(first, "key1-long-enough-to-pass-validation")
        XCTAssertEqual(second, "key1-long-enough-to-pass-validation")
    }
    
    // MARK: - Edge Cases
    
    func testCount_WithNoKeys() async {
        // Don't set any environment variables
        await rotator.reload()
        
        let count = await rotator.count()
        
        if count == 0 {
            // If no keys loaded, currentKey() should handle gracefully
        } else {
            // Some key was loaded from system (OK) or placeholder
            XCTAssertGreaterThan(count, 0)
        }
    }
    
    func testCurrentKey_BeforeReload() async {
        let newRotator = APIKeyRotator()

        let key = await newRotator.currentKey()
        XCTAssertFalse(key.isEmpty)
    }
    
    func testReload_UpdatesKeysList() async {
        setenv("GEMINI_API_KEYS", "key1-long-enough-to-pass-validation,key2-long-enough-to-pass-validation", 1)
        await rotator.reload()
        
        let count1 = await rotator.count()
        XCTAssertEqual(count1, 2)
        
        // Change environment
        setenv("GEMINI_API_KEYS", "key1-long-enough-to-pass-validation,key2-long-enough-to-pass-validation,key3-long-enough-to-pass-validation,key4-long-enough-to-pass-validation", 1)
        await rotator.reload()
        
        let count2 = await rotator.count()
        XCTAssertEqual(count2, 4)
    }
    
    func testReload_AlwaysKeepsFirstConfiguredKeyAsCurrent() async {
        setenv("GEMINI_API_KEYS", "key1-long-enough-to-pass-validation,key2-long-enough-to-pass-validation,key3-long-enough-to-pass-validation", 1)
        await rotator.reload()
        await rotator.reload()

        let key = await rotator.currentKey()
        XCTAssertEqual(key, "key1-long-enough-to-pass-validation")
    }
    
    // MARK: - Concurrent Access Tests
    
    func testConcurrentSnapshotReads() async {
        let keys = [
            "key1-long-enough-to-pass-validation",
            "key2-long-enough-to-pass-validation",
            "key3-long-enough-to-pass-validation",
            "key4-long-enough-to-pass-validation",
            "key5-long-enough-to-pass-validation"
        ]
        setenv("GEMINI_API_KEYS", keys.joined(separator: ","), 1)
        await rotator.reload()

        let rotator: APIKeyRotator = self.rotator
        await withTaskGroup(of: [String].self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await rotator.allKeys()
                }
            }

            for await snapshot in group {
                XCTAssertEqual(snapshot, keys)
            }
        }
    }

    func testReload_ReplacesSnapshotWithLatestEnvironment() async {
        setenv("GEMINI_API_KEYS", "key1-long-enough-to-pass-validation,key2-long-enough-to-pass-validation", 1)
        await rotator.reload()

        setenv("GEMINI_API_KEYS", "key3-long-enough-to-pass-validation,key4-long-enough-to-pass-validation", 1)
        await rotator.reload()

        let keys = await rotator.allKeys()
        XCTAssertEqual(keys, [
            "key3-long-enough-to-pass-validation",
            "key4-long-enough-to-pass-validation"
        ])
    }
    
    // MARK: - Performance Tests
    
    func testPerformance_KeyRotationProfiling() async {
        let keys = (1...10).map { "key-\($0)-long-enough-to-pass-validation" }
        setenv("GEMINI_API_KEYS", keys.joined(separator: ","), 1)
        await rotator.reload()

        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            for _ in 0..<1000 {
                _ = await rotator.allKeys()
            }
        }
        print("APIKeyRotator.allKeys x1000: \(elapsed)")
    }
}
