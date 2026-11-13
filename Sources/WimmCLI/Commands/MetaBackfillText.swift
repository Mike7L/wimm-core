import ArgumentParser
import Foundation
import WimmDomain
import WimmInfrastructure

struct MetaBackfillText: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "backfill-text",
        abstract: "Backfill document text into metadata (document.text) for notes missing analyzable text"
    )

    @Flag(name: .long, help: "Apply changes (default is dry-run)")
    var apply: Bool = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Only process notes without NoteCard")
    var onlyMissingNoteCard: Bool = true

    @Flag(name: .long, inversion: .prefixedNo, help: "Use Vision OCR fallback when native extraction is empty")
    var ocr: Bool = true

    @Option(name: .long, help: "Limit number of files to process")
    var limit: Int?

    @Option(name: .long, help: "Limit number of OCR pages per PDF")
    var maxPDFOCRPages: Int = 50

    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false

    mutating func run() async throws {
        let request = DocumentTextBackfillRequest(
            apply: apply,
            onlyMissingNoteCard: onlyMissingNoteCard,
            ocr: ocr,
            limit: limit,
            maxPDFOCRPages: max(1, maxPDFOCRPages)
        )
        let report = await DocumentTextBackfillService().run(request)

        if json {
            try printBackfillJSON(report)
            return
        }

        print("Backfill document text")
        print("Mode: \(apply ? "APPLY" : "DRY-RUN")")
        print("Scanned candidates: \(report.scanned)")
        print("Skipped (has NoteCard): \(report.skippedHasNoteCard)")
        print("Skipped (text exists): \(report.skippedHasTextAlready)")
        print("Extracted text: \(report.extracted)")
        print("Empty after extraction: \(report.emptyAfterExtraction)")
        print("Written: \(report.written)")

        if !report.providers.isEmpty {
            print("Providers:")
            for key in report.providers.keys.sorted() {
                print("- \(key): \(report.providers[key] ?? 0)")
            }
        }

        if !report.errors.isEmpty {
            print("Errors: \(report.errors.count)")
            for entry in report.errors.prefix(20) {
                print("- \(entry.file): \(entry.reason)")
            }
        }

        if !apply {
            print("Run with --apply to persist changes.")
        }
    }
}

private func printBackfillJSON<T: Encodable>(_ payload: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(payload)
    if let output = String(data: data, encoding: .utf8) {
        print(output)
    }
}
