import XCTest
import AVFoundation
@testable import WimmStudio
@testable import WimmDocumentUI
import WimmInfrastructure

@MainActor
final class CaptureInputSwitchTests: XCTestCase {
    private let builtIn = AudioInputOption(uid: "builtIn-1", name: "MacBook Air Microphone", transport: "builtIn")
    private let airPods = AudioInputOption(uid: "airpods-1", name: "AirPods Pro von Mikhail", transport: "bluetooth")
    private let btGeneric = AudioInputOption(uid: "bt-1", name: "Sony WH-1000XM5", transport: "bluetooth")
    private let usbMic = AudioInputOption(uid: "usb-1", name: "USB Podcast Mic", transport: "usb")

    func testStartUsesBoundBuiltInUIDWhenSystemDefaultIsAirPods() async {
        let suite = "wimm.capture-switch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        AudioInputPreference.builtInOnly.save(to: defaults)

        let spy = RecorderSpy()
        let capture = CaptureSession(
            deviceSourceFactory: { uid in SwitchTestMicrophone(uid: uid, spy: spy) },
            liveFactory: { SwitchTestASR() },
            availableInputsProvider: { [self.builtIn, self.airPods] },
            systemDefaultUIDProvider: { self.airPods.uid },
            preferences: defaults,
            observeHardwareChanges: false
        )
        capture.allowsNoteCardAnalysis = false
        defer { capture.finishForTermination() }

        XCTAssertEqual(capture.displayedInputDevice, builtIn)
        await capture.start()

        XCTAssertEqual(capture.phase, .recording)
        XCTAssertEqual(spy.startUIDs, [builtIn.uid])
    }

    func testToggleInputWhileIdlePersistsPreferenceWithoutRecording() {
        let suite = "wimm.capture-switch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let spy = RecorderSpy()
        let capture = CaptureSession(
            deviceSourceFactory: { uid in SwitchTestMicrophone(uid: uid, spy: spy) },
            liveFactory: { SwitchTestASR() },
            availableInputsProvider: { [self.builtIn, self.airPods] },
            systemDefaultUIDProvider: { self.airPods.uid },
            preferences: defaults,
            observeHardwareChanges: false
        )

        XCTAssertEqual(capture.displayedInputDevice, airPods)
        capture.toggleInputDevice()

        XCTAssertEqual(capture.phase, .idle)
        XCTAssertEqual(capture.inputPreference, .builtInOnly)
        XCTAssertEqual(AudioInputPreference.load(from: defaults), .builtInOnly)
        XCTAssertEqual(capture.displayedInputDevice, builtIn)
        XCTAssertTrue(spy.startUIDs.isEmpty)
    }

    func testToggleInputMidRecordingSwitchesSourceWithoutStoppingNote() async throws {
        let suite = "wimm.capture-switch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        AudioInputPreference.builtInOnly.save(to: defaults)

        let spy = RecorderSpy()
        let capture = CaptureSession(
            deviceSourceFactory: { uid in SwitchTestMicrophone(uid: uid, spy: spy) },
            liveFactory: { SwitchTestASR() },
            availableInputsProvider: { [self.builtIn, self.airPods] },
            systemDefaultUIDProvider: { self.airPods.uid },
            preferences: defaults,
            observeHardwareChanges: false
        )
        capture.allowsNoteCardAnalysis = false
        defer { capture.finishForTermination() }

        await capture.start()
        XCTAssertEqual(capture.phase, .recording)
        let urlBefore = try XCTUnwrap(capture.recordingURL)
        XCTAssertEqual(spy.startUIDs, [builtIn.uid])

        capture.toggleInputDevice()
        for _ in 0..<50 {
            if !capture.isSwitchingInput && spy.startUIDs.count >= 2 { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        // Let levelLoop tick once after switching to ensure no spurious restart occurs.
        try? await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(spy.stopCount, 1)
        XCTAssertEqual(spy.startUIDs, [builtIn.uid, airPods.uid])
        XCTAssertEqual(capture.phase, .recording)
        XCTAssertEqual(capture.recordingURL, urlBefore)
        XCTAssertEqual(capture.inputPreference, .device(uid: airPods.uid))
        XCTAssertEqual(capture.displayedInputDevice, airPods)
        XCTAssertFalse(capture.isSwitchingInput)
    }

    func testHUDMicIconSymbolsAndTooltips() {
        XCTAssertEqual(HUDMicIcon.symbol(for: airPods), "airpodspro")
        XCTAssertEqual(HUDMicIcon.symbol(for: btGeneric), "headphones")
        XCTAssertEqual(HUDMicIcon.symbol(for: builtIn), "laptopcomputer")
        XCTAssertEqual(HUDMicIcon.symbol(for: usbMic), "mic.fill")
        XCTAssertEqual(HUDMicIcon.symbol(for: nil), "mic")

        XCTAssertEqual(HUDMicIcon.inputTooltip(current: nil, target: nil), "Микрофон не найден")
        XCTAssertEqual(HUDMicIcon.inputTooltip(current: builtIn, target: nil), "Микрофон: MacBook Air Microphone")
        let switchTip = HUDMicIcon.inputTooltip(current: airPods, target: builtIn)
        XCTAssertTrue(switchTip.contains("AirPods Pro von Mikhail"))
        XCTAssertTrue(switchTip.contains("MacBook Air Microphone"))

        let recMode = HUDMicIcon.micModeTooltip(active: .voiceIsolation, preferred: .standard, isRecording: true)
        XCTAssertTrue(recMode.contains("Изоляция голоса"))
        let idleMode = HUDMicIcon.micModeTooltip(active: .standard, preferred: .wideSpectrum, isRecording: false)
        XCTAssertTrue(idleMode.contains("Широкий спектр"))
        XCTAssertTrue(idleMode.contains("во время записи"))
    }
}

private final class RecorderSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _startUIDs: [String?] = []
    private var _stopCount = 0

    var startUIDs: [String?] { lock.lock(); defer { lock.unlock() }; return _startUIDs }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return _stopCount }

    func recordStart(_ uid: String?) {
        lock.lock(); _startUIDs.append(uid); lock.unlock()
    }

    func recordStop() {
        lock.lock(); _stopCount += 1; lock.unlock()
    }
}

private struct SwitchTestMicrophone: LiveAudioSource {
    let uid: String?
    let spy: RecorderSpy

    func requestAccess() async throws {}

    func start(
        bufferHandler: @escaping LiveAudioBufferHandler,
        completionHandler _: @escaping LiveAudioCompletionHandler
    ) throws -> AVAudioFormat {
        spy.recordStart(uid)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) {
            buffer.frameLength = 1024
            buffer.floatChannelData?[0][0] = 0.01
            bufferHandler(buffer)
        }
        return format
    }

    func stop() {
        spy.recordStop()
    }
}

private actor SwitchTestASR: CaptureLiveTranscribing {
    func prepare() async throws {}
    func append(_ samples: [Float]) {}
    func refresh() async throws -> String? { nil }
    func finish() async throws -> String { "" }
}
