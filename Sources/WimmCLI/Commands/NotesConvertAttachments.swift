import ArgumentParser
import Foundation
import WimmDomain
import WimmInfrastructure

/// `wimm-cli notes convert-attachments`: before `split-attachments`, turns an
/// attachment of a type the library does not list (SVG, AMR, WebM, HTML, ICS,
/// zip) into one it does, next to the original, which stays. Dry-run unless
/// `--apply`. See `AttachmentConversion`.
struct NotesConvertAttachments: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "convert-attachments",
        abstract: "Convert unsupported attachments (SVG, AMR, HTML…) to PNG, m4a or text before split-attachments"
    )

    @Flag(name: .long, help: "Write converted files and repoint the attachments. Without it nothing changes.")
    var apply: Bool = false

    @Option(name: .long, help: "Where to write the JSON report (default: a temp file)")
    var report: String?

    func run() async throws {
        if apply && NotesSplitAttachments.desktopAppIsRunning() {
            print("Wimm or Wimm Studio is running. Quit it first.")
            throw ExitCode.failure
        }
        let library = StoragePaths.baseDirectory()
        let result = try AttachmentConversion.run(library: library, apply: apply, converter: Self.systemConverter)
        let reportURL = report.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("convert-attachments-\(UUID().uuidString.prefix(8)).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(result).write(to: reportURL, options: .atomic)
        print(apply ? "APPLIED to \(library.path)" : "DRY RUN (nothing changed) on \(library.path)")
        print("Attachments: \(result.items.count)")
        for (title, counts) in [("By format", result.byFormat), ("By action", result.byAction)] {
            print("\(title): " + counts.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        }
        print("Report: \(reportURL.path)")
        if result.byAction["failed", default: 0] > 0 { throw ExitCode.failure }
    }

    static let systemConverter = AttachmentConversion.Converter(
        svgToPNG: { source, output in
            // Quick Look renders SVG; it needs the extension to know the type.
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("wimm-svg-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            let copy = temp.appendingPathComponent("image.svg")
            try FileManager.default.copyItem(at: source, to: copy)
            _ = try runTool("/usr/bin/qlmanage", ["-t", "-s", "2000", "-o", temp.path, copy.path])
            try FileManager.default.moveItem(at: temp.appendingPathComponent("image.svg.png"), to: output)
        },
        audioToM4A: { source, output in
            if (try? runTool("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", source.path, output.path])) != nil,
               FileManager.default.fileExists(atPath: output.path) { return }
            try? FileManager.default.removeItem(at: output)
            for ffmpeg in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"] where FileManager.default.isExecutableFile(atPath: ffmpeg) {
                _ = try runTool(ffmpeg, ["-nostdin", "-loglevel", "error", "-i", source.path, "-vn", "-c:a", "aac",
                                         "-f", "ipod", output.path])
                return
            }
            throw CocoaError(.fileReadUnknown)
        },
        htmlToText: { source in
            try runTool("/usr/bin/textutil", ["-format", "html", "-convert", "txt", "-stdout", source.path])
        },
        zipListing: { source in
            try runTool("/usr/bin/zipinfo", ["-1", source.path])
        }
    )

    @discardableResult
    private static func runTool(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "wimm-cli", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\((path as NSString).lastPathComponent) exited \(process.terminationStatus)"])
        }
        return String(decoding: data, as: UTF8.self)
    }
}
