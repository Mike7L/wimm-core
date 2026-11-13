import ArgumentParser
import Foundation
import Darwin
import WimmInfrastructure
import AVFoundation

/// Loads only local models. No note reads/writes, inference, or cloud-provider calls.
struct ProfileModels: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profile-models",
        abstract: "Measure local model load (JSON). Default reloads inside one process and may download. --fresh loads installed parakeet:ultra once, then exits.")

    @Flag(help: "Include the offline diarizer. Ignored by --fresh.")
    var diarizer = false

    @Flag(name: .long, help: "Load installed parakeet:ultra once in this process and exit. No download, inference, diarization, or in-process reload.")
    var fresh = false

    @Option(name: .long, help: "After loading, run this many live-style reads (samples in memory, nothing written) and report the footprint. Read-only.")
    var inference = 0

    @Option(name: .long, help: "Audio file to read samples from for --inference (read-only). Default: synthetic noise and silence.")
    var audio: String?

    func run() async throws {
        if inference > 0 {
            try await runInference()
        } else if fresh {
            try await runFreshLoad()
        } else {
            try await runInProcessReload()
        }
    }

    /// One load of an already installed model, then the process ends. A second
    /// invocation is a new process and sees only the on-disk compile cache.
    private func runFreshLoad() async throws {
        let savedOutput = try redirectStdoutToStderr()
        defer { restoreStdout(savedOutput) }

        let before = taskMemorySample(stage: "before")
        let clock = ContinuousClock()
        let start = clock.now
        try await ParakeetTranscriptionAdapter.preload(
            modelIdentifier: ParakeetModel.ultra,
            onlyIfInstalled: true)
        let seconds = seconds(from: start.duration(to: clock.now))
        let loaded = await LocalModelResources.loadedModels()
        guard loaded.contains(where: { $0 == ParakeetModel.ultra || $0.hasPrefix("parakeet:") }) else {
            throw ValidationError("parakeet:ultra is not installed; refusing to download")
        }
        let after = taskMemorySample(stage: "loaded", seconds: seconds)
        let result: [String: Any] = [
            "mode": "fresh_process",
            "model": ParakeetModel.ultra,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "seconds_to_ready": seconds,
            "phys_footprint_before_bytes": before["footprint_bytes"] ?? 0,
            "phys_footprint_after_bytes": after["footprint_bytes"] ?? 0,
            "phys_footprint_peak_bytes": after["peak_bytes"] ?? 0,
            "loaded_models_at_end": loaded,
            "inference": false,
            "download": false,
            "diarization": false,
            "limitations": "Single process, single load of an already installed parakeet:ultra. No ASR inference, user audio, diarization, download, or in-process reload. Core ML may keep a process-wide cache until this process exits. A compiled Neural Engine cache on disk is left untouched."
        ]
        emitJSON(result, savedOutput: savedOutput)
    }

    /// The live-preview path (`transcribe(samples:)`): growing tails up to 15 s, like a recording.
    private func runInference() async throws {
        let savedOutput = try redirectStdoutToStderr()
        defer { restoreStdout(savedOutput) }
        var stages: [[String: Any]] = [taskMemorySample(stage: "before")]
        try await ParakeetTranscriptionAdapter.preload(modelIdentifier: ParakeetModel.ultra, onlyIfInstalled: true)
        stages.append(taskMemorySample(stage: "loaded"))
        let source = try audio.map { try profileSamples(from: URL(fileURLWithPath: $0)) }
        let adapter = ParakeetTranscriptionAdapter()
        var words = 0
        for round in 1...inference {
            let count = 16_000 * (1 + (round - 1) % 15)
            let samples: [Float]
            if let source, source.count > count {
                let start = (round * 16_000 * 7) % (source.count - count)
                samples = Array(source[start..<start + count])
            } else if round % 4 == 0 {
                samples = [Float](repeating: 0, count: count)
            } else {
                samples = (0..<count).map { _ in Float.random(in: -0.05...0.05) }
            }
            let start = Date()
            let result = try await adapter.transcribe(samples: samples)
            words += result.text.split(whereSeparator: \.isWhitespace).count
            if round <= 3 || round % max(1, inference / 10) == 0 {
                stages.append(taskMemorySample(stage: "read_\(round)", seconds: Date().timeIntervalSince(start)))
            }
        }
        try await Task.sleep(for: .seconds(2))
        stages.append(taskMemorySample(stage: "idle"))
        emitJSON(["stages": stages, "reads": inference, "words": words,
                  "audio": audio ?? "synthetic"], savedOutput: savedOutput)
    }

    private func runInProcessReload() async throws {
        let savedOutput = try redirectStdoutToStderr()
        defer { restoreStdout(savedOutput) }
        var stages: [[String: Any]] = []
        stages.append(taskMemorySample(stage: "before"))
        for round in 1...2 {
            let start = Date()
            try await ParakeetTranscriptionAdapter.preload()
            if diarizer { try await LocalSpeakerDiarizer.preload() }
            stages.append(taskMemorySample(stage: "loaded_\(round)", seconds: Date().timeIntervalSince(start)))
            let release = Date()
            try await LocalModelResources.releaseUnused(force: true)
            try await Task.sleep(for: .seconds(2))
            stages.append(taskMemorySample(stage: "released_\(round)", seconds: Date().timeIntervalSince(release)))
        }
        let result: [String: Any] = [
            "stages": stages,
            "loaded_models_at_end": await LocalModelResources.loadedModels(),
            "limitations": "Core ML may retain process-wide caches. First load may include download/compile; second load measures warm disk reload. No ASR inference or user audio is used."
        ]
        emitJSON(result, savedOutput: savedOutput)
    }

    private func emitJSON(_ result: [String: Any], savedOutput: Int32) {
        fflush(nil)
        dup2(savedOutput, STDOUT_FILENO)
        let data = (try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        print(String(decoding: data, as: UTF8.self))
    }
}

private func redirectStdoutToStderr() throws -> Int32 {
    let savedOutput = dup(STDOUT_FILENO)
    guard savedOutput >= 0 else { throw CocoaError(.fileWriteUnknown) }
    // Some Core ML backends printf to stdout; keep the JSON channel clean.
    dup2(STDERR_FILENO, STDOUT_FILENO)
    return savedOutput
}

private func restoreStdout(_ savedOutput: Int32) {
    dup2(savedOutput, STDOUT_FILENO)
    close(savedOutput)
}

private func seconds(from duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
}

private func taskMemorySample(stage: String, seconds: Double = 0) -> [String: Any] {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return [
        "stage": stage,
        "seconds": seconds,
        "footprint_bytes": status == KERN_SUCCESS ? info.phys_footprint : 0,
        "peak_bytes": status == KERN_SUCCESS ? info.ledger_phys_footprint_peak : 0
    ]
}

private func profileSamples(from url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    guard let converter = AVAudioConverter(from: file.processingFormat, to: target),
          let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(min(file.length, 48_000 * 600)))
    else { throw CocoaError(.fileReadUnknown) }
    try file.read(into: input)
    let capacity = AVAudioFrameCount(Double(input.frameLength) * 16_000 / file.processingFormat.sampleRate) + 1024
    guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw CocoaError(.fileReadUnknown) }
    nonisolated(unsafe) var fed = false
    var failure: NSError?
    converter.convert(to: output, error: &failure) { _, status in
        if fed { status.pointee = .endOfStream; return nil }
        fed = true; status.pointee = .haveData; return input
    }
    if let failure { throw failure }
    return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
}
