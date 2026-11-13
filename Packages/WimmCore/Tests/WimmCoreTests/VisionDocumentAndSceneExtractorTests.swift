import CoreGraphics
import Foundation
import XCTest
@testable import WimmInfrastructure

#if canImport(AppKit)
import AppKit
#endif

final class VisionDocumentAndSceneExtractorTests: XCTestCase {

    // MARK: - Geometric Document Formatting

    func testFormatLines_HeadingsParagraphsAndLists() {
        let lines: [VisionTextLine] = [
            // Title (height 0.045 vs median 0.020 -> ratio 2.25 -> #)
            VisionTextLine(
                text: "Квартальный отчёт",
                boundingBox: CGRect(x: 0.08, y: 0.88, width: 0.50, height: 0.045)
            ),
            // Section heading (height 0.028 vs median 0.020 -> ratio 1.40 -> ##)
            VisionTextLine(
                text: "Основные итоги",
                boundingBox: CGRect(x: 0.08, y: 0.80, width: 0.35, height: 0.028)
            ),
            // Wrapped body paragraph (2 lines close together, gap = 0.008 <= 0.85 * 0.020)
            VisionTextLine(
                text: "Первая строка длинного абзаца с перено-",
                boundingBox: CGRect(x: 0.08, y: 0.73, width: 0.75, height: 0.020)
            ),
            VisionTextLine(
                text: "сом слова на следующую строку.",
                boundingBox: CGRect(x: 0.08, y: 0.702, width: 0.55, height: 0.020)
            ),
            // Second paragraph after vertical gap (gap = 0.042 > 0.85 * 0.020)
            VisionTextLine(
                text: "Отдельный второй абзац документа.",
                boundingBox: CGRect(x: 0.08, y: 0.64, width: 0.60, height: 0.020)
            ),
            // Bullet list items
            VisionTextLine(
                text: "• Проверить смету",
                boundingBox: CGRect(x: 0.10, y: 0.56, width: 0.40, height: 0.020)
            ),
            VisionTextLine(
                text: "• Согласовать договор",
                boundingBox: CGRect(x: 0.10, y: 0.53, width: 0.45, height: 0.020)
            ),
        ]

        let markdown = VisionDocumentFormatter.formatLines(lines)
        let expected = """
        # Квартальный отчёт

        ## Основные итоги

        Первая строка длинного абзаца с переносом слова на следующую строку.

        Отдельный второй абзац документа.

        - Проверить смету
        - Согласовать договор
        """
        XCTAssertEqual(markdown, expected)
    }

    func testFormatLines_MultiColumnRowsFormMarkdownTable() {
        let lines: [VisionTextLine] = [
            VisionTextLine(text: "Позиция", boundingBox: CGRect(x: 0.08, y: 0.80, width: 0.20, height: 0.022)),
            VisionTextLine(text: "Кол-во", boundingBox: CGRect(x: 0.45, y: 0.80, width: 0.12, height: 0.022)),
            VisionTextLine(text: "Сумма", boundingBox: CGRect(x: 0.72, y: 0.80, width: 0.15, height: 0.022)),

            VisionTextLine(text: "Ноутбук", boundingBox: CGRect(x: 0.08, y: 0.75, width: 0.20, height: 0.022)),
            VisionTextLine(text: "1", boundingBox: CGRect(x: 0.45, y: 0.75, width: 0.05, height: 0.022)),
            VisionTextLine(text: "2400 EUR", boundingBox: CGRect(x: 0.72, y: 0.75, width: 0.18, height: 0.022)),

            VisionTextLine(text: "Кабель USB-C", boundingBox: CGRect(x: 0.08, y: 0.70, width: 0.24, height: 0.022)),
            VisionTextLine(text: "2", boundingBox: CGRect(x: 0.45, y: 0.70, width: 0.05, height: 0.022)),
            VisionTextLine(text: "40 EUR", boundingBox: CGRect(x: 0.72, y: 0.70, width: 0.14, height: 0.022)),
        ]

        let metrics = VisionDocumentFormatter.formatLinesWithMetrics(lines)
        XCTAssertTrue(metrics.hasStructuredTable)
        let expected = """
        | Позиция | Кол-во | Сумма |
        | --- | --- | --- |
        | Ноутбук | 1 | 2400 EUR |
        | Кабель USB-C | 2 | 40 EUR |
        """
        XCTAssertEqual(metrics.markdown, expected)
    }

    // MARK: - Scene Description Formatting

    func testSceneFormatter_DescribesPhotoWithoutTextAndPrunesRedundantTags() {
        let obs = VisionSceneObservation(
            tags: [
                .init(identifier: "outdoor", confidence: 0.82),
                .init(identifier: "wine_bottle", confidence: 0.64),
                .init(identifier: "bottle", confidence: 0.64),
                .init(identifier: "wine", confidence: 0.60),
                .init(identifier: "container", confidence: 0.58),
                .init(identifier: "liquid", confidence: 0.55),
                .init(identifier: "table", confidence: 0.48),
                .init(identifier: "people", confidence: 0.45),
                .init(identifier: "dog", confidence: 0.42),
                .init(identifier: "animal", confidence: 0.42),
            ],
            faceCount: 1,
            humanCount: 2,
            animalCounts: ["dog": 1]
        )

        let description = VisionSceneFormatter.describe(obs, wordCount: 0)
        XCTAssertEqual(
            description,
            "[scene: outdoor, wine bottle, table | 2 people (1 face), 1 dog]"
        )

        // Scene descriptions must not trigger false-positive pseudonym suspects.
        let suspects = PseudonymSuspects.find(inMasked: description ?? "")
        XCTAssertEqual(suspects, [])
    }

    func testSceneFormatter_MixedPhotoWithSmallInscriptionKeepsScene() {
        let obs = VisionSceneObservation(
            tags: [
                .init(identifier: "street_sign", confidence: 0.71),
                .init(identifier: "sign", confidence: 0.71),
                .init(identifier: "outdoor", confidence: 0.55),
                .init(identifier: "building", confidence: 0.40),
                .init(identifier: "structure", confidence: 0.40),
            ],
            faceCount: 0,
            humanCount: 0,
            animalCounts: [:]
        )

        let description = VisionSceneFormatter.describe(obs, wordCount: 4, textCoverage: 0.03)
        XCTAssertEqual(description, "[scene: street sign, outdoor, building]")
    }

    func testSceneFormatter_PureDocumentReturnsNil() {
        let shortDocObs = VisionSceneObservation(
            tags: [
                .init(identifier: "document", confidence: 0.62),
                .init(identifier: "printed_page", confidence: 0.62),
            ]
        )
        XCTAssertNil(VisionSceneFormatter.describe(shortDocObs, wordCount: 10, textCoverage: 0.08))

        // Dense document even with illustration tags skips scene description.
        let illustratedDocObs = VisionSceneObservation(
            tags: [
                .init(identifier: "document", confidence: 0.45),
                .init(identifier: "wine_bottle", confidence: 0.30),
            ]
        )
        XCTAssertNil(VisionSceneFormatter.describe(illustratedDocObs, wordCount: 60, textCoverage: 0.25))
    }

    // MARK: - End-to-End VisionOCRProvider Rendering Test

    #if canImport(AppKit)
    func testVisionOCRProvider_ExtractsFormattedDocumentWithTableAndList() async throws {
        let width = 800
        let height = 900
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: width, height: height))

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 32),
            .foregroundColor: NSColor.black,
        ]
        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16),
            .foregroundColor: NSColor.black,
        ]

        ("Invoice #2026-42" as NSString).draw(at: NSPoint(x: 50, y: 820), withAttributes: titleAttrs)
        ("Customer: Acme Corp\nDate: 2026-10-27" as NSString).draw(
            at: NSPoint(x: 50, y: 740), withAttributes: bodyAttrs)

        let tableTop = 680.0
        let rowH = 40.0
        let colX = [50.0, 350.0, 500.0, 650.0]
        let rows = [
            ["Item", "Qty", "Price"],
            ["MacBook Pro", "1", "$2400"],
            ["USB-C Cable", "2", "$40"],
        ]
        NSColor.black.setStroke()
        for r in 0...rows.count {
            let y = tableTop - Double(r) * rowH
            let p = NSBezierPath()
            p.move(to: NSPoint(x: colX.first!, y: y))
            p.line(to: NSPoint(x: colX.last!, y: y))
            p.stroke()
        }
        for x in colX {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: x, y: tableTop))
            p.line(to: NSPoint(x: x, y: tableTop - Double(rows.count) * rowH))
            p.stroke()
        }
        for (rIdx, row) in rows.enumerated() {
            let y = tableTop - Double(rIdx + 1) * rowH + 10
            for (cIdx, cell) in row.enumerated() {
                (cell as NSString).draw(
                    at: NSPoint(x: colX[cIdx] + 10, y: y), withAttributes: bodyAttrs)
            }
        }

        ("Notes:\n• Payment due within 14 days\n• Wire transfer preferred" as NSString).draw(
            in: NSRect(x: 50, y: 380, width: 600, height: 120), withAttributes: bodyAttrs)

        image.unlockFocus()
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))

        let provider = VisionOCRProvider()
        let result = try await provider.performOCR(on: cgImage)

        XCTAssertTrue(result.contains("# Invoice #2026-42"), "Expected Markdown H1 title, got:\n\(result)")
        XCTAssertTrue(result.contains("| Item | Qty | Price |"), "Expected Markdown table header, got:\n\(result)")
        XCTAssertTrue(result.contains("| MacBook Pro | 1 | $2400 |"), "Expected table row, got:\n\(result)")
        XCTAssertTrue(result.contains("- Payment due within 14 days"), "Expected normalized bullet list, got:\n\(result)")
        XCTAssertFalse(result.contains("[scene:"), "Document should not include a scene header:\n\(result)")
    }
    #endif
}
