import Foundation
import WimmDomain

#if canImport(Speech) && canImport(AVFoundation)
import AVFoundation
import Speech

public final class NativeSpeechAdapter: NSObject, TranscriptionPort, @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer?
    private let audioSource: LiveAudioSource
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    private let stateQueue = DispatchQueue(label: "wimm.native-speech.state")

    private var finalText = ""
    private var wavBuilder = WAVBuilder()
    private var isCapturing = false

    public init(
        locale: Locale? = nil,
        audioSource: LiveAudioSource = MicrophoneAudioSource()
    ) {
        self.recognizer = Self.makeRecognizer(preferred: locale)
        self.audioSource = audioSource
        super.init()
    }

    /// Picks a recognizer from WIMM_SPEECH_LOCALES (comma-separated) or the
    /// ru-RU-first default. isAvailable is often false transiently (offline,
    /// model still loading), so a supported preferred locale is kept even when
    /// it isn't available yet — a wrong-language recognizer silently
    /// mistranscribes the whole session.
    private static func makeRecognizer(preferred: Locale?) -> SFSpeechRecognizer? {
        if let preferred { return SFSpeechRecognizer(locale: preferred) }

        var candidates: [String]
        if let env = ProcessInfo.processInfo.environment["WIMM_SPEECH_LOCALES"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            candidates = env.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        } else {
            candidates = ["ru-RU"]
            let system = Locale.current.identifier
            if system != "ru-RU" { candidates.append(system) }
            if !candidates.contains("en-US") { candidates.append("en-US") }
        }

        var firstSupported: SFSpeechRecognizer?
        for id in candidates {
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: id)) else { continue }
            if recognizer.isAvailable {
                log("[NativeSpeech] using locale=\(id) available=true")
                return recognizer
            }
            if firstSupported == nil { firstSupported = recognizer }
        }
        if let recognizer = firstSupported {
            log("[NativeSpeech] using locale=\(recognizer.locale.identifier) available=false (keeping preferred locale)")
            return recognizer
        }
        let fallback = SFSpeechRecognizer()
        log("[NativeSpeech] fallback to system locale=\(fallback?.locale.identifier ?? "none")")
        return fallback
    }

    /// Creates a domain-specific NSError with a human-readable description.
    private static func error(code: Int, _ message: String) -> NSError {
        NSError(domain: "NativeSpeechAdapter", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    public func startStreamingCapture() throws -> AsyncThrowingStream<String, Error> {
        if isCapturing {
            throw Self.error(code: 1001, "Capture already in progress")
        }

        // Permissions are requested asynchronously via the stream itself so that
        // startStreamingCapture() remains synchronous (matching the protocol signature)
        // while the async handshake happens inside the stream's task.
        return AsyncThrowingStream { [weak self] continuation in
            guard let self else {
                continuation.finish(throwing: Self.error(code: 1007, "Adapter deallocated"))
                return
            }
            Task {
                do {
                    try await self.requestPermissions()
                    try self.startCaptureSession()
                    self.stateQueue.sync {
                        self.continuation = continuation
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func stopCapture() async throws -> (audioData: Data, finalText: String) {
        stateQueue.sync {
            if !isCapturing {
                return
            }
            audioSource.stop()
            recognitionRequest?.endAudio()
            isCapturing = false
        }

        // Give recognition callback a short window to flush final hypothesis.
        try? await Task.sleep(nanoseconds: 250_000_000)

        let result = stateQueue.sync { () -> (Data, String) in
            let wav = wavBuilder.build()
            return (wav, finalText)
        }

        cleanup()
        return result
    }

    public func transcribeFile(at fileURL: URL) async throws -> String {
        guard let recognizer, recognizer.isAvailable else {
            throw Self.error(code: 1006, "Speech recognizer is unavailable")
        }

        // Reuse the same permissions check as streaming capture.
        try await requestPermissions()

        return try await withCheckedThrowingContinuation { cont in
            let request = SFSpeechURLRecognitionRequest(url: fileURL)
            request.shouldReportPartialResults = false
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    cont.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func startCaptureSession() throws {
        guard let recognizer, recognizer.isAvailable else {
            throw Self.error(code: 1002, "Speech recognizer is unavailable")
        }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else {
            throw Self.error(code: 1003, "Failed to create recognition request")
        }
        request.shouldReportPartialResults = true

        let format = try audioSource.start(
            bufferHandler: { [weak self] buffer in
                guard let self else { return }
                self.recognitionRequest?.append(buffer)
                self.wavBuilder.append(buffer: buffer)
            },
            completionHandler: { [weak self] error in
                guard let self else { return }
                if let error {
                    self.finishStream(error: error)
                } else {
                    self.recognitionRequest?.endAudio()
                }
            }
        )
        wavBuilder.configure(sampleRate: format.sampleRate, channels: UInt16(max(1, format.channelCount)))
        finalText = ""
        wavBuilder.reset()

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                self.stateQueue.sync {
                    self.finalText = text
                    self.continuation?.yield(text)
                }
                if result.isFinal {
                    self.finishStream(error: nil)
                }
            }

            if let error {
                self.finishStream(error: error)
            }
        }

        isCapturing = true
    }

    private func finishStream(error: Error?) {
        stateQueue.sync {
            guard isCapturing else {
                continuation?.finish(throwing: error)
                return
            }
            isCapturing = false
            audioSource.stop()
            recognitionRequest?.endAudio()
            if let error {
                continuation?.finish(throwing: error)
            } else {
                continuation?.finish()
            }
        }
    }

    private func cleanup() {
        stateQueue.sync {
            audioSource.stop()
            recognitionTask?.cancel()
            recognitionTask = nil
            recognitionRequest = nil
            continuation = nil
            isCapturing = false
        }
    }

    private func requestPermissions() async throws {
        try await audioSource.requestAccess()

        let speechStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard speechStatus == .authorized else {
            throw Self.error(code: 1005, "Speech recognition permission denied")
        }
    }
}

#else

public final class NativeSpeechAdapter: TranscriptionPort, @unchecked Sendable {
    public init() {}

    private static func error(code: Int, _ message: String) -> NSError {
        NSError(domain: "NativeSpeechAdapter", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    public func startStreamingCapture() throws -> AsyncThrowingStream<String, Error> {
        throw Self.error(code: 1000, "Speech/AVFoundation frameworks are unavailable on this platform")
    }

    public func stopCapture() async throws -> (audioData: Data, finalText: String) {
        (Data(), "")
    }

    public func transcribeFile(at fileURL: URL) async throws -> String {
        throw Self.error(code: 1000, "Speech framework is unavailable on this platform")
    }
}

#endif
