import Foundation
import WimmInfrastructure
import WimmDomain

/// Throwaway upload copy of a recording for transcribers that get a reduced file
/// (cloud Gemini/OpenRouter, WhisperKit, native speech).
///
/// The copy is a 16 kHz mono low-bitrate re-encode of the original with silence
/// gaps removed per `AudioSilenceMap` (adaptive per-file threshold): fewer billed
/// seconds and less silence for a cloud model to invent text over. When the map
/// finds nothing to trim — or trimming is disabled/fails — it is a plain
/// untrimmed downsample. The original is never modified.
///
/// Since 2026-11-09 nothing persistent is written next to the original: the copy
/// lives in the temp directory and the caller deletes it after the run. Older
/// libraries still hold `_micro.m4a` files (sometimes the only audio of a note),
/// so `FileStore.isDerivedAudioFile` keeps recognizing them.
public enum MicroAudio {
    /// Builds the upload copy in the temp directory and returns its URL, or `nil`
    /// when the input is itself a derived file or every re-encode attempt failed
    /// (the caller then uploads the input as is). The file name ends in `_micro`
    /// so adapters treat it as already prepared and do not re-encode it again.
    /// The caller owns the returned file and must delete it.
    public static func makeUploadCopy(original: URL) -> URL? {
        // Never derive from an already-derived file — that cascades into
        // "_micro_micro.m4a"-style junk when a derived file is passed as the original.
        guard !FileStore.isDerivedAudioFile(original) else {
            log("[Micro] refuse to derive from derived file=\(original.lastPathComponent)")
            return nil
        }
        guard let encoded = reencode(source: original) else { return nil }
        let named = encoded.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString + "_micro.m4a")
        do {
            try FileManager.default.moveItem(at: encoded, to: named)
            return named
        } catch {
            log("[Micro] rename failed error=\(error) original=\(original.lastPathComponent)")
            try? FileManager.default.removeItem(at: encoded)
            return nil
        }
    }

    /// Trimmed re-encode when the silence map finds skippable gaps, plain downsample
    /// otherwise; a failed trimmed attempt (e.g. all-silence input) retries untrimmed
    /// so quiet recordings still get a small uploadable copy.
    private static func reencode(source: URL) -> URL? {
        let trimEnabled = TranscodeCfg.microTrimRMSFloor > 0
        let silences = trimEnabled ? (AudioSilenceMap.analyze(url: source)?.silences ?? []) : []
        if !silences.isEmpty {
            do {
                return try AudioReencoder.reencodeM4A(
                    inputURL: source,
                    toSampleRate: TranscodeCfg.miniSampleRate,
                    channels: AudioCfg.channels,
                    dropIntervals: silences
                )
            } catch {
                log("[Micro] trimmed encode failed, retrying untrimmed error=\(error) original=\(source.lastPathComponent)")
            }
        }
        do {
            return try AudioReencoder.reencodeM4A(
                inputURL: source,
                toSampleRate: TranscodeCfg.miniSampleRate,
                channels: AudioCfg.channels
            )
        } catch {
            log("[Micro] encode failed error=\(error) original=\(source.lastPathComponent)")
            return nil
        }
    }
}
