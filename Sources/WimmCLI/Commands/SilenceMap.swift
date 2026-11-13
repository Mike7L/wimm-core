import ArgumentParser
import AVFoundation
import Foundation
import WimmDomain
import WimmInfrastructure
import WimmTranscription

/// Inspect the playback silence map for one audio file — the same map the
/// skip-silence toggle uses in the macOS and iOS players. Read-only; useful
/// for tuning the detection thresholds against real recordings.
struct SilenceMapCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "silence-map",
        abstract: "Print the skip-silence map for an audio file"
    )

    @Argument(help: "Path to the audio file")
    var path: String

    @Flag(name: .long, help: "Also build the silence-trimmed upload copy (temp file, deleted afterwards) and report its duration")
    var uploadCopy: Bool = false

    func run() async throws {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let map = await AudioSilenceAnalyzer.shared.silenceMap(for: url) else {
            throw ValidationError("Could not decode audio: \(url.path)")
        }
        let fmt: (Double) -> String = { String(format: "%d:%05.2f", Int($0) / 60, $0.truncatingRemainder(dividingBy: 60)) }
        print("duration: \(fmt(map.duration))  silences: \(map.silences.count)  skippable: \(fmt(map.totalSilence)) (\(Int(map.totalSilence / max(map.duration, 0.001) * 100))%)")
        for gap in map.silences {
            print("  \(fmt(gap.start)) – \(fmt(gap.end))  (\(String(format: "%.1f", gap.length))s)")
        }

        if uploadCopy {
            guard let copy = MicroAudio.makeUploadCopy(original: url) else {
                print("upload copy: not created (derived input, or encoding failed)")
                return
            }
            defer { try? FileManager.default.removeItem(at: copy) }
            let seconds = (try? await AVURLAsset(url: copy).load(.duration)).map(CMTimeGetSeconds) ?? 0
            let bytes: (URL) -> Int = { u in
                ((try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0) ?? 0
            }
            print("upload copy: \(fmt(seconds))  \(bytes(copy) / 1024)KB (orig \(bytes(url) / 1024)KB)")
        }
    }
}
