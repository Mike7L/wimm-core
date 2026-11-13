import Foundation
import WimmInfrastructure
import WimmDomain
import AVFoundation
import AudioToolbox

// Re-encodes compressed audio (e.g., m4a) to a new file with the desired sample rate/channels.
// Returns URL of the newly written file. Throws on failure.
public enum AudioReencoder {
    public struct Options { public let sampleRate: Double; public let channels: Int }

    /// - Parameter trimSilenceRMSFloor: when `> 0`, windows (~100 ms) whose RMS is
    ///   below this floor are dropped, collapsing long pauses / room tone. Generous
    ///   padding (~100 ms pre-roll, ~400 ms hangover) is kept around every voiced run
    ///   so speech onsets/tails are never clipped. `0` copies every frame through.
    /// - Parameter dropIntervals: source-timeline gaps (from `AudioSilenceMap`, which
    ///   already pads speech and ignores short pauses) whose audio is dropped outright.
    ///   When non-empty this takes precedence over `trimSilenceRMSFloor` — the map's
    ///   adaptive per-file threshold beats a global absolute floor.
    public static func reencodeM4A(
        inputURL: URL,
        toSampleRate: Double,
        channels: Int = 1,
        trimSilenceRMSFloor: Float = 0,
        dropIntervals: [AudioSilenceMap.Interval] = []
    ) throws -> URL {
        let outURL = FileStore.temporaryDirectory().appendingPathComponent(UUID().uuidString + ".m4a")

        var srcFile: ExtAudioFileRef? = nil
        var dstFile: ExtAudioFileRef? = nil
        let statusOpen = ExtAudioFileOpenURL(inputURL as CFURL, &srcFile)
        guard statusOpen == noErr, let src = srcFile else {
            throw NSError(domain: "AudioReencoder", code: Int(statusOpen), userInfo: [NSLocalizedDescriptionKey: "ExtAudioFileOpen failed code=\(statusOpen)"])
        }
        defer { ExtAudioFileDispose(src) }

        // Destination AAC format (encoder fills most fields)
    var dstFormat = AudioStreamBasicDescription(mSampleRate: toSampleRate,
                                                    mFormatID: kAudioFormatMPEG4AAC,
                                                    mFormatFlags: 0,
                                                    mBytesPerPacket: 0,
                                                    mFramesPerPacket: 1024,
                                                    mBytesPerFrame: 0,
                                                    mChannelsPerFrame: UInt32(max(1, channels)),
                                                    mBitsPerChannel: 0,
                                                    mReserved: 0)

        // Client format: 16-bit PCM at target rate for consistent conversion path
        var clientFormat = AudioStreamBasicDescription(mSampleRate: toSampleRate,
                                                       mFormatID: kAudioFormatLinearPCM,
                                                       mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                                       mBytesPerPacket: 2 * UInt32(max(1, channels)),
                                                       mFramesPerPacket: 1,
                                                       mBytesPerFrame: 2 * UInt32(max(1, channels)),
                                                       mChannelsPerFrame: UInt32(max(1, channels)),
                                                       mBitsPerChannel: 16,
                                                       mReserved: 0)

        // Create destination m4a file with AAC
        let createStatus = ExtAudioFileCreateWithURL(outURL as CFURL,
                                                     kAudioFileM4AType,
                                                     &dstFormat,
                                                     nil,
                                                     AudioFileFlags.eraseFile.rawValue,
                                                     &dstFile)
        guard createStatus == noErr, let dst = dstFile else {
            throw NSError(domain: "AudioReencoder", code: Int(createStatus), userInfo: [NSLocalizedDescriptionKey: "create dst failed code=\(createStatus)"])
        }
        defer { ExtAudioFileDispose(dst) }

    // Set client formats
    let set1 = ExtAudioFileSetProperty(src, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFormat)
        guard set1 == noErr else { throw NSError(domain: "AudioReencoder", code: Int(set1), userInfo: [NSLocalizedDescriptionKey: "set client src fmt failed"]) }
        let set2 = ExtAudioFileSetProperty(dst, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFormat)
        guard set2 == noErr else { throw NSError(domain: "AudioReencoder", code: Int(set2), userInfo: [NSLocalizedDescriptionKey: "set client dst fmt failed"]) }

        // Try to set AAC encoder bitrate through the underlying AudioConverter
        do {
            var conv: AudioConverterRef? = nil
            var convSize = UInt32(MemoryLayout<AudioConverterRef?>.size)
            let st = ExtAudioFileGetProperty(dst, kExtAudioFileProperty_AudioConverter, &convSize, &conv)
            if st == noErr, let conv {
                var br: UInt32 = UInt32(TranscodeCfg.miniBitRate)
                _ = AudioConverterSetProperty(conv, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &br)
            }
        }

        // Transfer loop. Reads in ~100 ms windows so silence trimming has fine-enough
        // granularity without chopping mid-word. When trimming is off the windows are
        // copied straight through, matching the original behavior.
        let bytesPerFrame = Int(clientFormat.mBytesPerFrame)
        let windowFrames = UInt32(max(256, Int(toSampleRate * 0.1)))
        let bufferByteCount = Int(windowFrames) * bytesPerFrame
        var data = Data(count: bufferByteCount)

        let mapEnabled = !dropIntervals.isEmpty
        let trimEnabled = trimSilenceRMSFloor > 0 && !mapEnabled
        var dropCursor = 0
        var sourceFramesRead: Int64 = 0
        // Keep ~400 ms of trailing audio after the last voiced window, and re-attach
        // the single window immediately before a voiced onset, so cuts only ever land
        // in the middle of a long pause.
        let hangoverWindows = 4
        var hangoverRemaining = 0
        var stash = Data()            // last dropped silent window, held for pre-roll
        var stashFrames: UInt32 = 0

        var totalFramesWritten: Int64 = 0
        var eof = false

        // Writes `frames` worth of PCM from `bytes` to the destination. ExtAudioFileWrite
        // only reads the buffer, so borrowing the immutable storage is safe.
        func writeFrames(_ bytes: Data, _ frames: UInt32) -> Bool {
            guard frames > 0 else { return true }
            var ok = true
            bytes.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                guard let base = ptr.baseAddress else { ok = false; return }
                let audioBuffer = AudioBuffer(mNumberChannels: clientFormat.mChannelsPerFrame,
                                              mDataByteSize: frames * UInt32(bytesPerFrame),
                                              mData: UnsafeMutableRawPointer(mutating: base))
                var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: audioBuffer)
                if ExtAudioFileWrite(dst, frames, &bufferList) != noErr { ok = false }
            }
            return ok
        }

        while !eof {
            var framesToRead: UInt32 = windowFrames
            let rms: Float? = data.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) -> Float? in
                guard let base = ptr.baseAddress else { return nil }
                let audioBuffer = AudioBuffer(mNumberChannels: clientFormat.mChannelsPerFrame,
                                              mDataByteSize: UInt32(bufferByteCount),
                                              mData: base)
                var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: audioBuffer)
                let readStatus = ExtAudioFileRead(src, &framesToRead, &bufferList)
                if readStatus != noErr || framesToRead == 0 { return nil }
                guard trimEnabled else { return 0 }
                let sampleCount = Int(framesToRead) * Int(clientFormat.mChannelsPerFrame)
                let samples = base.assumingMemoryBound(to: Int16.self)
                var sum = 0.0
                for i in 0..<sampleCount { let v = Double(samples[i]) / 32768.0; sum += v * v }
                return Float((sum / Double(max(1, sampleCount))).squareRoot())
            }
            guard let windowRMS = rms, framesToRead > 0 else { eof = true; break }

            if mapEnabled {
                // Client format runs at the target sample rate, so frames-read maps
                // directly onto the source timeline the silence map was built from.
                let windowMid = (Double(sourceFramesRead) + Double(framesToRead) / 2) / toSampleRate
                sourceFramesRead += Int64(framesToRead)
                while dropCursor < dropIntervals.count, dropIntervals[dropCursor].end <= windowMid {
                    dropCursor += 1
                }
                if dropCursor < dropIntervals.count, dropIntervals[dropCursor].contains(windowMid) {
                    continue
                }
                if !writeFrames(data, framesToRead) { eof = true; break }
                totalFramesWritten += Int64(framesToRead)
                continue
            }

            if !trimEnabled {
                if !writeFrames(data, framesToRead) { eof = true; break }
                totalFramesWritten += Int64(framesToRead)
                continue
            }

            if windowRMS >= trimSilenceRMSFloor {
                // Voiced: flush the held pre-roll window, then this window.
                if stashFrames > 0 {
                    if !writeFrames(stash, stashFrames) { eof = true; break }
                    totalFramesWritten += Int64(stashFrames)
                    stashFrames = 0
                }
                if !writeFrames(data, framesToRead) { eof = true; break }
                totalFramesWritten += Int64(framesToRead)
                hangoverRemaining = hangoverWindows
            } else if hangoverRemaining > 0 {
                // Still inside the trailing pad after speech: keep it.
                if !writeFrames(data, framesToRead) { eof = true; break }
                totalFramesWritten += Int64(framesToRead)
                hangoverRemaining -= 1
                stashFrames = 0
            } else {
                // Droppable silence: hold it as the candidate pre-roll for the next onset.
                stash = Data(data[0..<(Int(framesToRead) * bytesPerFrame)])
                stashFrames = framesToRead
            }
        }
        if totalFramesWritten == 0 { throw NSError(domain: "AudioReencoder", code: -30, userInfo: [NSLocalizedDescriptionKey: "no frames written"]) }
        return outURL
    }
}
