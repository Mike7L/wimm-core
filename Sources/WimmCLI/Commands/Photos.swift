import ArgumentParser
import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import WimmInfrastructure
import WimmDomain

struct Photos: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Offline MLX photo descriptions with Apple Vision text",
        subcommands: [PhotoStatus.self, PhotoDescribe.self, PhotoExtract.self, PhotoBenchmark.self, PhotoCompare.self, PhotoLibrary.self, PhotoProcessAll.self, PhotoApplyResults.self, PhotoCaptionResults.self])
}

struct PhotoStatus: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status")
    func run() throws {
        print("Model: \(LocalPhotoModel.identifier)")
        print("Ready: \(LocalPhotoModel.isReady)")
        print("Offline inference; captions are drafts in English. Literal text uses Apple Vision.")
        if !LocalPhotoModel.isReady { print("Setup: scripts/setup_local_vision.sh") }
    }
}

struct PhotoDescribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "describe", abstract: "Read-only extraction for one image")
    @Argument var path: String
    @Flag(name: .long) var json = false
    @Option(name:.long) var engine = "vision"
    func run() async throws {
        let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let selected = DocumentOCREngine(rawValue:engine), selected == .vision || selected == .mlx else { throw ValidationError("Choose --engine vision or mlx") }
        let record = try await ImageUnderstanding.extract(file,engine:selected,forceCaption:selected == .mlx)
        let vision = record.vision!
        if json {
            let data = try JSONSerialization.data(withJSONObject: ["text": record.text, "ocrText": vision.ocrText,
                "caption": record.caption?.caption ?? "", "model": record.model,
                "denseDocument": vision.isDenseDocument,
                "vision": try JSONSerialization.jsonObject(with: JSONEncoder().encode(vision))], options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } else { print(record.text) }
    }
}

struct PhotoBenchmark: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "benchmark",
        abstract: "Read-only run on N recent image files, forcing a caption for every file; private local report")
    @Option(name: .long) var recent = 100
    @Option(name: .long, help: "New output directory; never inside the library") var output: String

    func run() async throws {
        guard (1...1000).contains(recent) else { throw ValidationError("--recent must be between 1 and 1000") }
        guard LocalPhotoModel.isReady else { throw LocalPhotoModel.Failure.notInstalled }
        let folder = URL(fileURLWithPath: (output as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
        let library = StoragePaths.baseDirectory().standardizedFileURL.resolvingSymlinksInPath()
        guard folder != library, !folder.path.hasPrefix(library.path + "/") else {
            throw ValidationError("Benchmark reports must be outside the note library")
        }
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw ValidationError("Output directory already exists") }
        let targets = await PhotoLibrarySampler.recent(limit: recent)
        guard targets.count == recent else { throw ValidationError("Only \(targets.count) eligible images found; requested \(recent)") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let images = folder.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let start = Date()
        var results: [PhotoRun] = []
        let sidecars = Dictionary(uniqueKeysWithValues: Set(targets.map { FileStore.metadataURL(forRecordingURL: $0.note) }).map { ($0.path, Self.hash($0)) })
        for (index, target) in targets.enumerated() {
            try Task.checkCancellation()
            let itemStart = Date(), before = Self.hash(target.image)
            var row = PhotoRun(id: String(format: "photo_%03d", index + 1), source: target.image.path,
                note: target.note.path, date: target.date, dateBasis: target.dateBasis,
                sourceSHA256: before, text: nil, caption: nil, ocrText: nil, denseDocument: nil,
                seconds: 0, peakMLXGB: nil, error: nil, unchanged: false)
            do {
                let image = try LocalPhotoInput.load(target.image)
                // Exactly one VLM call per file even for documents. Production skips dense documents.
                let extraction = try await LocalPhotoOCRProvider().extract(image: image, forceCaption: true)
                row.text = extraction.text; row.caption = extraction.caption?.caption
                row.ocrText = extraction.ocrText; row.denseDocument = extraction.isDenseDocument
                row.peakMLXGB = extraction.caption?.peakMemoryGB
                row.vision = extraction.vision
                try Self.preview(target.image, to: images.appendingPathComponent(row.id + ".png"))
            } catch is CancellationError { throw CancellationError() }
            catch { row.error = error.localizedDescription }
            row.seconds = Date().timeIntervalSince(itemStart)
            row.unchanged = before != nil && before == Self.hash(target.image)
            results.append(row)
            try Self.write(results, to: folder.appendingPathComponent("results-private.json"))
            print("[\(index + 1)/\(recent)] \(row.id) \(row.error == nil ? "ok" : "failed") \(String(format: "%.2f", row.seconds))s")
        }
        let elapsed = Date().timeIntervalSince(start), times = results.map(\.seconds).sorted()
        let changedSidecars = sidecars.filter { $0.value != Self.hash(URL(fileURLWithPath: $0.key)) }.count
        let failed = results.filter { $0.error != nil }.count
        let report = PhotoReport(model: LocalPhotoModel.identifier, attempted: results.count,
            succeeded: results.count - failed, failed: failed, seconds: elapsed,
            medianSeconds: times[times.count / 2], maxSeconds: times.max() ?? 0,
            peakMLXGB: results.compactMap(\.peakMLXGB).max() ?? 0,
            changedOriginals: results.filter { !$0.unchanged }.count, changedSidecars: changedSidecars,
            dateMin: targets.map(\.date).min()!, dateMax: targets.map(\.date).max()!,
            fallbackDates: targets.filter { $0.dateBasis == "file_creation_fallback" }.count)
        try Self.write(report, to: folder.appendingPathComponent("summary.json"))
        try Self.html(results, report: report).write(to: folder.appendingPathComponent("gallery.html"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: folder.appendingPathComponent("gallery.html").path)
        print("Completed \(report.attempted): \(report.succeeded) succeeded, \(failed) failed; peak MLX \(String(format: "%.2f", report.peakMLXGB)) GB; changed originals \(report.changedOriginals), sidecars \(changedSidecars)")
        if failed > 0 || report.changedOriginals > 0 || changedSidecars > 0 { throw ExitCode.failure }
    }

    private static func hash(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private static func preview(_ source: URL, to target: URL) throws {
        let image = try LocalPhotoInput.load(source, maximumSide: 1024)
        guard let out = CGImageDestinationCreateWithURL(target as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(out, image, nil)
        guard CGImageDestinationFinalize(out) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
    private static func html(_ rows: [PhotoRun], report: PhotoReport) -> String {
        func escape(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
        let items = rows.map { row in "<article><h2>\(row.id)</h2><img loading=\"lazy\" src=\"images/\(row.id).png\"><p>\(escape(row.caption ?? row.error ?? ""))</p><details><summary>Apple Vision text</summary><pre>\(escape(row.ocrText ?? ""))</pre></details><small>\(String(format: "%.2f", row.seconds))s</small></article>" }.joined(separator: "\n")
        return "<!doctype html><meta charset=\"utf-8\"><title>Local photo benchmark</title><style>body{font:17px system-ui;max-width:1000px;margin:40px auto;padding:20px;background:#eee}article{background:white;padding:20px;margin:25px 0}img{max-width:100%;max-height:600px}pre{white-space:pre-wrap}</style><h1>\(escape(report.model)) — \(report.attempted) images</h1><p>Offline, read-only. Captions are drafts and have not been independently verified. Text uses Apple Vision. No accuracy percentage is implied by a successful run.</p>\(items)"
    }
}

private struct PhotoRun: Codable {
    let id: String, source: String, note: String
    let date: Date
    let dateBasis: String
    let sourceSHA256: String?
    var text: String?, caption: String?, ocrText: String?, denseDocument: Bool?
    var seconds: Double, peakMLXGB: Double?, error: String?
    var unchanged: Bool
    var vision: VisionImageAnalysis? = nil
}
private struct PhotoReport: Codable {
    let model: String
    let attempted: Int, succeeded: Int, failed: Int
    let seconds: Double, medianSeconds: Double, maxSeconds: Double, peakMLXGB: Double
    let changedOriginals: Int, changedSidecars: Int
    let dateMin: Date, dateMax: Date
    let fallbackDates: Int
}
