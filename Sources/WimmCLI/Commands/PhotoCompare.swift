import ArgumentParser
import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import WimmDomain
import WimmInfrastructure

struct PhotoCompare: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "compare",
        abstract: "Compare full native Vision with a verified earlier MLX batch on exactly the same files; read-only")
    @Option(name: .long, help: "Earlier photos benchmark results-private.json") var baseline: String
    @Option(name: .long, help: "New private directory outside the library") var output: String

    func run() async throws {
        let source = URL(fileURLWithPath: (baseline as NSString).expandingTildeInPath)
        let rows = try JSONDecoder().decode([BaselinePhoto].self, from: Data(contentsOf: source))
        guard !rows.isEmpty, rows.count <= 1000, Set(rows.map(\.source)).count == rows.count else {
            throw ValidationError("Baseline must contain 1...1000 distinct source files")
        }
        let folder = URL(fileURLWithPath: (output as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
        let library = StoragePaths.baseDirectory().standardizedFileURL.resolvingSymlinksInPath()
        guard folder != library, !folder.path.hasPrefix(library.path + "/"),
              !FileManager.default.fileExists(atPath: folder.path) else {
            throw ValidationError("Output must be a new directory outside the note library")
        }
        // Validate every original before any comparison; never silently replace old cases
        // with newer notes or compare a new image against a stale caption.
        for row in rows {
            guard row.error == nil, row.caption != nil, let expected = row.sourceSHA256,
                  Self.hash(URL(fileURLWithPath: row.source)) == expected else {
                throw ValidationError("Baseline has a failed/missing caption or a changed original")
            }
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let images = folder.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let sidecars = Dictionary(uniqueKeysWithValues: Set(rows.map { FileStore.metadataURL(forRecordingURL: URL(fileURLWithPath: $0.note)) }).map { ($0.path, Self.hash($0)) })
        var results: [ComparisonPhoto] = []
        let start = Date()
        for (index, row) in rows.enumerated() {
            try Task.checkCancellation()
            let id = String(format: "photo_%03d", index + 1), imageURL = URL(fileURLWithPath: row.source)
            let t = Date()
            var result = ComparisonPhoto(id: id, baseline: row, vision: nil, visionSeconds: 0, error: nil, unchanged: false)
            do {
                let image = try LocalPhotoInput.load(imageURL)
                result.vision = try await VisionDocumentAndSceneExtractor.analyze(image: image)
                result.visionSeconds = Date().timeIntervalSince(t)
                let preview = try LocalPhotoInput.load(imageURL, maximumSide: 1024)
                let file = images.appendingPathComponent(id + ".png")
                guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
                CGImageDestinationAddImage(destination, preview, nil)
                guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            } catch is CancellationError { throw CancellationError() }
            catch { result.error = error.localizedDescription; result.visionSeconds = Date().timeIntervalSince(t) }
            result.unchanged = Self.hash(imageURL) == row.sourceSHA256
            results.append(result)
            try Self.write(results, folder.appendingPathComponent("comparison-private.json"))
            print("[\(index+1)/\(rows.count)] \(id) \(result.error == nil ? "ok" : "failed")")
        }
        let valid = results.compactMap(\.vision), times = results.map(\.visionSeconds).sorted()
        let dense = valid.filter(\.isDenseDocument).count
        let labels = valid.filter { !$0.isDenseDocument && $0.hasSceneSearchLabels }.count
        let changedSidecars = sidecars.filter { Self.hash(URL(fileURLWithPath: $0.key)) != $0.value }.count
        let report = ComparisonSummary(images: rows.count, failures: results.filter { $0.error != nil }.count,
            visionSeconds: Date().timeIntervalSince(start), medianVisionSeconds: (times[(times.count-1)/2] + times[times.count/2])/2,
            baselineTotalSeconds: rows.map(\.seconds).reduce(0,+), denseDocuments: dense,
            sparseImagesWithLabels: labels, sparseImagesWithoutLabels: valid.count - dense - labels,
            imagesWithCodes: valid.filter { !$0.codes.isEmpty }.count, codeCount: valid.reduce(0) { $0 + $1.codes.count },
            imagesWithData: valid.filter { !$0.detectedData.isEmpty }.count, dataCount: valid.reduce(0) { $0 + $1.detectedData.count },
            imagesWithDiagnostics: valid.filter { !$0.issues.isEmpty }.count,
            changedOriginals: results.filter { !$0.unchanged }.count, changedSidecars: changedSidecars)
        try Self.write(report, folder.appendingPathComponent("summary.json"))
        try Self.gallery(results, report: report).write(to: folder.appendingPathComponent("gallery.html"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: folder.appendingPathComponent("gallery.html").path)
        print("Compared \(rows.count): dense \(dense), sparse with search labels \(labels); failures \(report.failures). MLX captions reused, not rerun. No semantic accuracy score.")
        if report.failures > 0 || report.changedOriginals > 0 || changedSidecars > 0 { throw ExitCode.failure }
    }

    private static func hash(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func write<T: Encodable>(_ value: T, _ file: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private static func gallery(_ rows: [ComparisonPhoto], report: ComparisonSummary) -> String {
        func escape(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
        let items = rows.map { row in
            let route = row.vision?.isDenseDocument == true ? "Vision document; production skips MLX" : (row.vision?.hasSceneSearchLabels == true ? "Vision has search labels; human review needed before omitting MLX" : "No native scene label; MLX candidate")
            return "<article><h2>\(row.id)</h2><img loading=\"lazy\" src=\"images/\(row.id).png\"><p>\(route)</p><div class=\"columns\"><section><h3>Native Vision</h3><pre>\(escape(row.vision?.text ?? row.error ?? ""))</pre></section><section><h3>Earlier Qwen caption</h3><pre>\(escape(row.baseline.caption ?? ""))</pre></section></div><details><summary>Diagnostics</summary><pre>\(escape(row.vision?.issues.joined(separator: "\n") ?? ""))</pre></details></article>"
        }.joined(separator: "\n")
        return "<!doctype html><meta charset=\"utf-8\"><title>Vision / Qwen comparison</title><style>body{font:17px system-ui;max-width:1200px;margin:auto;padding:30px;background:#eee}article{background:white;padding:24px;margin:24px 0}img{max-height:550px;max-width:100%}.columns{display:grid;grid-template-columns:1fr 1fr;gap:24px}pre{white-space:pre-wrap;overflow-wrap:anywhere}</style><h1>Native Vision / Qwen: \(report.images) files</h1><p>Same originals verified by SHA256. Qwen captions reused from the earlier run; only native Vision rerun. Search labels are not full descriptions. No human semantic accuracy grading. Further caption omission is diagnostic only.</p>\(items)"
    }
}
private struct BaselinePhoto: Codable {
    let id: String, source: String, note: String
    let sourceSHA256: String?
    let caption: String?, ocrText: String?, error: String?
    let seconds: Double
}
private struct ComparisonPhoto: Codable {
    let id: String, baseline: BaselinePhoto
    var vision: VisionImageAnalysis?
    var visionSeconds: Double
    var error: String?
    var unchanged: Bool
}
private struct ComparisonSummary: Codable {
    let images: Int, failures: Int
    let visionSeconds: Double, medianVisionSeconds: Double, baselineTotalSeconds: Double
    let denseDocuments: Int, sparseImagesWithLabels: Int, sparseImagesWithoutLabels: Int
    let imagesWithCodes: Int, codeCount: Int, imagesWithData: Int, dataCount: Int
    let imagesWithDiagnostics: Int, changedOriginals: Int, changedSidecars: Int
}
