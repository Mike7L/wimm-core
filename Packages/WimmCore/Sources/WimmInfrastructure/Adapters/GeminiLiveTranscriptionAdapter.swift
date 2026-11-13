import Foundation
import WimmDomain

#if canImport(AVFoundation)
@preconcurrency import AVFoundation

public final class GeminiLiveTranscriptionAdapter: NSObject, TranscriptionPort, @unchecked Sendable {
    private let apiKey: String
    private let modelName: String
    private let audioSource: LiveAudioSource
    private let transport: GeminiLiveTransport
    private let stateQueue = DispatchQueue(label: "wimm.gemini-live.state")

    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    private var receiveTask: Task<Void, Never>?
    private var converter: PCMChunkConverter?
    private var pcm16Data = Data()
    private var latestTranscript = ""
    private var isCapturing = false
    private var setupComplete = false
    private var audioStreamEnded = false

    public init(
        apiKey: String,
        modelName: String = "gemini-3.1-flash-live-preview",
        audioSource: LiveAudioSource = MicrophoneAudioSource(),
        transport: GeminiLiveTransport = URLSessionGeminiLiveTransport()
    ) {
        self.apiKey = apiKey
        self.modelName = modelName
        self.audioSource = audioSource
        self.transport = transport
        super.init()
    }

    public func startStreamingCapture() throws -> AsyncThrowingStream<String, Error> {
        try PrivateMode.refuseCloudAudio(provider: "gemini-live")
        if stateQueue.sync(execute: { isCapturing }) {
            throw Self.error(code: 3001, "Capture already in progress")
        }

        return AsyncThrowingStream { [weak self] continuation in
            guard let self else {
                continuation.finish(throwing: Self.error(code: 3002, "Adapter deallocated"))
                return
            }
            Task {
                do {
                    try await self.audioSource.requestAccess()
                    try await self.startSession(continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                    self.cleanup()
                }
            }
        }
    }

    public func stopCapture() async throws -> (audioData: Data, finalText: String) {
        stateQueue.sync {
            guard isCapturing else { return }
            audioSource.stop()
            isCapturing = false
        }

        try? await sendAudioStreamEndIfNeeded()
        try? await Task.sleep(nanoseconds: 600_000_000)

        let result = stateQueue.sync { () -> (Data, String) in
            let wav = WAVBuilder.makeWAV(fromPCM16: pcm16Data, sampleRate: 16_000, channels: 1)
            return (wav, latestTranscript)
        }
        cleanup()
        return result
    }

    public func transcribeFile(at fileURL: URL) async throws -> String {
        try await GeminiTranscriptionAdapter(apiKey: apiKey, modelName: modelName).transcribeFile(at: fileURL)
    }

    private func startSession(continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        let request = try makeRequest()
        let stream = try await transport.connect(request: request)

        stateQueue.sync {
            self.continuation = continuation
            self.pcm16Data = Data()
            self.latestTranscript = ""
            self.setupComplete = false
            self.audioStreamEnded = false
        }

        receiveTask = Task { [weak self] in
            await self?.receiveLoop(stream: stream)
        }

        try await sendSetup()
        try await waitForSetup()
        try startAudioCapture()
    }

    private func makeRequest() throws -> URLRequest {
        guard let url = URL(
            string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent"
        ) else {
            throw Self.error(code: 3003, "Invalid Gemini Live URL")
        }
        var request = URLRequest(url: url)
        request.addValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        return request
    }

    private func sendSetup() async throws {
        try await sendJSONObject([
            "setup": [
                "model": modelName.hasPrefix("models/") ? modelName : "models/\(modelName)",
                "generationConfig": [
                    "responseModalities": ["TEXT"]
                ],
                "systemInstruction": [
                    "parts": [
                        ["text": "Transcribe the user's speech exactly. Keep assistant responses empty."]
                    ]
                ],
                "inputAudioTranscription": [:]
            ]
        ])
    }

    private func waitForSetup() async throws {
        for _ in 0..<50 {
            if stateQueue.sync(execute: { setupComplete }) {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw Self.error(code: 3004, "Gemini Live setup timed out")
    }

    private func startAudioCapture() throws {
        let format = try audioSource.start(
            bufferHandler: { [weak self] buffer in
                guard let self else { return }
                do {
                    if self.converter == nil {
                        self.converter = PCMChunkConverter(inputFormat: buffer.format)
                    }
                    guard let converter = self.converter else {
                        throw Self.error(code: 3005, "Failed to create PCM converter")
                    }
                    let pcmChunk = try converter.convert(buffer: buffer)
                    self.stateQueue.sync {
                        self.pcm16Data.append(pcmChunk)
                    }
                    Task {
                        try? await self.sendAudioChunk(pcmChunk)
                    }
                } catch {
                    self.finish(with: error)
                }
            },
            completionHandler: { [weak self] error in
                guard let self else { return }
                if let error {
                    self.finish(with: error)
                    return
                }
                Task {
                    try? await self.sendAudioStreamEndIfNeeded()
                }
            }
        )

        if converter == nil {
            converter = PCMChunkConverter(inputFormat: format)
        }
        guard converter != nil else {
            throw Self.error(code: 3005, "Failed to create PCM converter")
        }
        stateQueue.sync { isCapturing = true }
    }

    private func sendAudioChunk(_ data: Data) async throws {
        try await sendJSONObject([
            "realtimeInput": [
                "mediaChunks": [
                    [
                        "mimeType": "audio/pcm;rate=16000",
                        "data": data.base64EncodedString()
                    ]
                ]
            ]
        ])
    }

    private func sendAudioStreamEndIfNeeded() async throws {
        let shouldSend = stateQueue.sync { () -> Bool in
            if audioStreamEnded {
                return false
            }
            audioStreamEnded = true
            return true
        }
        guard shouldSend else { return }
        try await sendJSONObject([
            "realtimeInput": [
                "audioStreamEnd": true
            ]
        ])
    }

    private func sendJSONObject(_ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        try await transport.send(data)
    }

    private func receiveLoop(stream: AsyncThrowingStream<Data, Error>) async {
        do {
            for try await data in stream {
                handleServerMessage(data)
            }
        } catch {
            finish(with: error)
        }
    }

    private func handleServerMessage(_ data: Data) {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        if payload["setupComplete"] != nil {
            stateQueue.sync { setupComplete = true }
        }
        if let input = payload["inputTranscription"] as? [String: Any],
           let text = input["text"] as? String {
            stateQueue.sync {
                latestTranscript = text
                continuation?.yield(text)
            }
        }
        if let goAway = payload["goAway"] as? [String: Any],
           let timeLeft = goAway["timeLeft"] {
            finish(with: Self.error(code: 3007, "Gemini Live session closing soon: \(timeLeft)"))
        }
    }

    private func finish(with error: Error?) {
        let continuation = stateQueue.sync { () -> AsyncThrowingStream<String, Error>.Continuation? in
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
        cleanup(finishStream: false)
    }

    private func cleanup(finishStream: Bool = true) {
        let continuation = stateQueue.sync { () -> AsyncThrowingStream<String, Error>.Continuation? in
            audioSource.stop()
            receiveTask?.cancel()
            receiveTask = nil
            converter = nil
            setupComplete = false
            isCapturing = false
            audioStreamEnded = false
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        if finishStream {
            continuation?.finish()
        }
        transport.close()
    }

    private static func error(code: Int, _ message: String) -> NSError {
        NSError(domain: "GeminiLiveTranscriptionAdapter", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private final class PCMChunkConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat

    private final class BufferFeed: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        var delivered = false

        init(buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }
    }

    init?(inputFormat: AVAudioFormat) {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ),
        let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }
        self.outputFormat = outputFormat
        self.converter = converter
    }

    func convert(buffer: AVAudioPCMBuffer) throws -> Data {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw NSError(domain: "GeminiLiveTranscriptionAdapter", code: 3010, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate output buffer"])
        }

        let feed = BufferFeed(buffer: buffer)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if feed.delivered {
                outStatus.pointee = .noDataNow
                return nil
            }
            feed.delivered = true
            outStatus.pointee = .haveData
            return feed.buffer
        }

        if status == .error {
            throw conversionError ?? NSError(domain: "GeminiLiveTranscriptionAdapter", code: 3011, userInfo: [NSLocalizedDescriptionKey: "PCM conversion failed"])
        }

        guard let channel = output.int16ChannelData?.pointee else { return Data() }
        let byteCount = Int(output.frameLength) * MemoryLayout<Int16>.size
        return Data(bytes: channel, count: byteCount)
    }
}

#else

public final class GeminiLiveTranscriptionAdapter: TranscriptionPort, @unchecked Sendable {
    public init(
        apiKey: String,
        modelName: String = "gemini-3.1-flash-live-preview"
    ) {}

    public func startStreamingCapture() throws -> AsyncThrowingStream<String, Error> {
        throw NSError(domain: "GeminiLiveTranscriptionAdapter", code: 3000, userInfo: [NSLocalizedDescriptionKey: "AVFoundation is unavailable on this platform"])
    }

    public func stopCapture() async throws -> (audioData: Data, finalText: String) {
        (Data(), "")
    }

    public func transcribeFile(at fileURL: URL) async throws -> String {
        throw NSError(domain: "GeminiLiveTranscriptionAdapter", code: 3000, userInfo: [NSLocalizedDescriptionKey: "AVFoundation is unavailable on this platform"])
    }
}

#endif
