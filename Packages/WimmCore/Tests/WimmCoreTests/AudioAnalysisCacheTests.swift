import XCTest
import AVFoundation
@testable import WimmInfrastructure
import WimmDomain

final class AudioAnalysisCacheTests: XCTestCase {
    private func fixture() throws -> (URL, URL) {
        let root = StoragePaths.baseDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("signal.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 80000)!
        buffer.frameLength = 80000
        for i in 0..<80000 { buffer.floatChannelData![0][i] = i < 16000 || i >= 64000 ? Float(sin(Double(i) * 0.1)) * 0.4 : 0 }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return (root, url)
    }
    func testOneDecodeFeedsBothFeaturesAndSurvivesProcessCacheRecreation() async throws {
        let (root, url) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let disk = root.appendingPathComponent("cache")
        let cache = AudioAnalysisCache(directory: disk)
        let first = try await cache.analysis(for: url)
        let second = try await cache.analysis(for: url)
        let count = await cache.decodeCount
        XCTAssertEqual(count, 1); XCTAssertEqual(first.peaks, second.peaks)
        let expected = try XCTUnwrap(AudioSilenceMap.analyze(url: url))
        XCTAssertEqual(first.silenceMap, expected)
        let restarted = AudioAnalysisCache(directory: disk)
        let loaded = try await restarted.analysis(for: url)
        let restarts = await restarted.decodeCount
        XCTAssertEqual(restarts, 0); XCTAssertEqual(first.peaks, loaded.peaks)
        XCTAssertEqual(first.duration, 10, accuracy: 0.001)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(1)], ofItemAtPath: url.path)
        _ = try await restarted.analysis(for: url)
        let changed = await restarted.decodeCount
        XCTAssertEqual(changed, 1)
    }
    func testCancelledReadDoesNotPopulateCache() async throws {
        let (root, url) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = AudioAnalysisCache()
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await cache.analysis(for: url)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
        let count = await cache.decodeCount
        XCTAssertEqual(count, 0)
    }
}
