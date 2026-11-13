import Foundation
import WimmDomain

#if canImport(AVFoundation)
@preconcurrency import AVFoundation

public typealias LiveAudioBufferHandler = @Sendable (AVAudioPCMBuffer) -> Void
public typealias LiveAudioCompletionHandler = @Sendable (Error?) -> Void

public protocol LiveAudioSource: Sendable {
    func requestAccess() async throws
    func start(
        bufferHandler: @escaping LiveAudioBufferHandler,
        completionHandler: @escaping LiveAudioCompletionHandler
    ) throws -> AVAudioFormat
    func stop()
}

public final class MicrophoneAudioSource: @unchecked Sendable {
    private let audioEngine: AVAudioEngine
    public var isRunning: Bool { audioEngine.isRunning }
    /// The device the running engine is bound to (nil before `start`).
    public var inputDevice: RecordingInputDevice? {
        RecordingInputDeviceInspector.current(inputNode: audioEngine.inputNode)
    }

    private let permissionRequester: @Sendable () async -> Bool

    public init(
        audioEngine: AVAudioEngine = AVAudioEngine(),
        permissionRequester: @escaping @Sendable () async -> Bool = {
            await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    cont.resume(returning: granted)
                }
            }
        }
    ) {
        self.audioEngine = audioEngine
        self.permissionRequester = permissionRequester
    }
}

extension MicrophoneAudioSource: LiveAudioSource {
    public func requestAccess() async throws {
        guard await permissionRequester() else {
            throw NSError(
                domain: "MicrophoneAudioSource",
                code: 2001,
                userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied"]
            )
        }
    }

    public func start(
        bufferHandler: @escaping LiveAudioBufferHandler,
        completionHandler _: @escaping LiveAudioCompletionHandler
    ) throws -> AVAudioFormat {
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0,
              format.sampleRate == inputNode.inputFormat(forBus: 0).sampleRate else {
            throw NSError(domain: "MicrophoneAudioSource", code: 2003,
                          userInfo: [NSLocalizedDescriptionKey: "Microphone input format unavailable"])
        }
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            bufferHandler(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        return format
    }

    public func stop() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
    }
}

public final class FixtureAudioSource: @unchecked Sendable {
    private let fileURL: URL
    private let chunkFrameCount: AVAudioFrameCount
    private let interChunkDelayNanoseconds: UInt64
    private let queue = DispatchQueue(label: "wimm.fixture-audio-source")
    private var producerTask: Task<Void, Never>?

    public init(
        fileURL: URL,
        chunkFrameCount: AVAudioFrameCount = 1024,
        interChunkDelayNanoseconds: UInt64 = 40_000_000
    ) {
        self.fileURL = fileURL
        self.chunkFrameCount = chunkFrameCount
        self.interChunkDelayNanoseconds = interChunkDelayNanoseconds
    }
}

extension FixtureAudioSource: LiveAudioSource {
    public func requestAccess() async throws {}

    public func start(
        bufferHandler: @escaping LiveAudioBufferHandler,
        completionHandler: @escaping LiveAudioCompletionHandler
    ) throws -> AVAudioFormat {
        let audioFile = try AVAudioFile(forReading: fileURL)
        let format = audioFile.processingFormat

        producerTask?.cancel()
        producerTask = Task {
            do {
                while !Task.isCancelled {
                    if audioFile.framePosition >= audioFile.length {
                        completionHandler(nil)
                        return
                    }
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrameCount) else {
                        throw NSError(
                            domain: "FixtureAudioSource",
                            code: 2002,
                            userInfo: [NSLocalizedDescriptionKey: "Failed to allocate audio buffer"]
                        )
                    }
                    try audioFile.read(into: buffer, frameCount: chunkFrameCount)
                    if buffer.frameLength == 0 {
                        completionHandler(nil)
                        return
                    }
                    bufferHandler(buffer)
                    if interChunkDelayNanoseconds > 0 {
                        try await Task.sleep(nanoseconds: interChunkDelayNanoseconds)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                completionHandler(error)
            }
        }

        return format
    }

    public func stop() {
        producerTask?.cancel()
        producerTask = nil
    }
}

#else

public protocol LiveAudioSource: Sendable {
    func requestAccess() async throws
    func start(
        bufferHandler: @escaping @Sendable (Data) -> Void,
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) throws
    func stop()
}

#endif
