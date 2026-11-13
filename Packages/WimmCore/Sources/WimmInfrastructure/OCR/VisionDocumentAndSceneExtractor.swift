import CoreGraphics
import Foundation
import Vision
import DataDetection

/// A single recognized text line with its normalized Vision bounding box
/// (origin at bottom-left, coordinates in `[0, 1]`).
public struct VisionTextLine: Sendable, Equatable {
    public let text: String
    public let boundingBox: CGRect

    public init(text: String, boundingBox: CGRect) {
        self.text = text
        self.boundingBox = boundingBox
    }
}

/// Visual classification and subject counts collected from on-device Vision requests.
public struct VisionSceneObservation: Sendable, Equatable, Codable {
    public struct Tag: Sendable, Equatable, Codable {
        public let identifier: String
        public let confidence: Float

        public init(identifier: String, confidence: Float) {
            self.identifier = identifier
            self.confidence = confidence
        }
    }

    public let tags: [Tag]
    public let faceCount: Int
    public let humanCount: Int
    public let animalCounts: [String: Int]

    public init(
        tags: [Tag] = [],
        faceCount: Int = 0,
        humanCount: Int = 0,
        animalCounts: [String: Int] = [:]
    ) {
        self.tags = tags
        self.faceCount = faceCount
        self.humanCount = humanCount
        self.animalCounts = animalCounts
    }
}

/// Local Vision pipeline that:
/// 1. Extracts document text with minimal, LLM-friendly Markdown structure
///    (headings `#`/`##`, paragraphs, bullet/numbered lists, and `| ... |` tables).
/// 2. Describes non-document images (and mixed photos with short inscriptions)
///    using on-device Vision scene/object classification and face/human/animal detection.
public enum VisionDocumentAndSceneExtractor {

    /// Performs structured document OCR and, when the image is a photo or has
    /// sparse text, prepends a compact `[scene: ...]` description.
    public static func extract(from image: CGImage) async throws -> String {
        try await analyze(image: image).text
    }

    /// Shared by Vision-only and MLX paths, so enabling a caption never discards
    /// native scene observations, barcode payloads or structured OCR matches.
    public static func analyze(image: CGImage) async throws -> VisionImageAnalysis {
        if min(image.width,image.height) < 8 {
            return VisionImageAnalysis(ocrText:"",scene:nil,sceneObservation:nil,codes:[],detectedData:[],
                isDenseDocument:false,documentEngine:"ImageIO dimensions only",issues:["image_too_small_for_recognition"])
        }
        let document = try await extractDocument(from: image)
        let dense = VisionSceneFormatter.isDenseDocument(wordCount: document.wordCount,
            textCoverage: document.textCoverage, hasStructuredTable: document.hasStructuredTable)
        var issues = document.issues
        var codes = document.codes
        // Structured recognition can miss a code on a sparse photo. The dedicated
        // detector is also the older-OS path; duplicate payloads collapse exactly.
        do {
            let request = VNDetectBarcodesRequest()
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            for observation in request.results ?? [] {
                if let payload = observation.payloadStringValue, !payload.isEmpty {
                    let code = VisionImageAnalysis.Code(symbology: observation.symbology.rawValue.replacingOccurrences(of: "VNBarcodeSymbology", with: "").lowercased(),
                        payload: payload, confidence: observation.confidence)
                    if !codes.contains(where: { $0.payload == payload && $0.symbology == code.symbology }) { codes.append(code) }
                }
            }
        } catch { issues.append("barcode_detection_failed") }
        let scene: VisionSceneObservation?
        if dense { scene = nil } else {
            let observation = observeSceneWithIssues(on: image)
            scene = observation.scene; issues += observation.issues
        }
        let data = document.data
        let sceneText = scene.flatMap { VisionSceneFormatter.describe($0, wordCount: document.wordCount,
            textCoverage: document.textCoverage, hasStructuredTable: document.hasStructuredTable) }
        var result = VisionImageAnalysis(ocrText: document.markdown.trimmingCharacters(in: .whitespacesAndNewlines),
            scene: sceneText, sceneObservation: scene, codes: codes, detectedData: data,
            isDenseDocument: dense, documentEngine: document.engine, issues: issues)
        result.layout = document.layout
        return result
    }

    // MARK: - Document Extraction

    private struct DocumentOutcome: Sendable {
        let markdown: String
        let wordCount: Int
        let textCoverage: CGFloat
        let hasStructuredTable: Bool
        var codes: [VisionImageAnalysis.Code] = []
        var data: [VisionImageAnalysis.Datum] = []
        var engine: String = "VNRecognizeTextRequest"
        var issues: [String] = []
        var layout: DocumentLayoutEvidence? = nil
    }

    private static func extractDocument(from image: CGImage) async throws -> DocumentOutcome {
        var issues: [String] = []
        if #available(macOS 26.0, iOS 26.0, *) {
            do {
                let modern = try await extractStructuredDocument(from: image)
                if !modern.markdown.isEmpty || !modern.codes.isEmpty { return modern }
                issues.append("structured_document_empty_used_text_fallback")
            } catch { issues.append("structured_document_failed_used_text_fallback") }
        }
        var fallback = try extractGeometricDocument(from: image)
        fallback.issues = issues
        return fallback
    }

    @available(macOS 26.0, iOS 26.0, *)
    private static func extractStructuredDocument(from image: CGImage) async throws -> DocumentOutcome {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.automaticallyDetectLanguage = true
        request.textRecognitionOptions.useLanguageCorrection = true
        request.textRecognitionOptions.minimumTextHeightFraction = 0.0
        request.barcodeDetectionOptions.enabled = true

        let observations = try await request.perform(on: image)
        guard let doc = observations.first?.document else {
            return DocumentOutcome(markdown: "", wordCount: 0, textCoverage: 0, hasStructuredTable: false)
        }

        var result = formatRecognizedDocument(doc)
        result.engine = "RecognizeDocumentsRequest"
        collectStructuredData(doc, into: &result)
        result.layout = structuredLayout(doc,image:image)
        return result
    }

    @available(macOS 26.0, iOS 26.0, *)
    private static func structuredLayout(_ doc: DocumentObservation.Container, image: CGImage) -> DocumentLayoutEvidence {
        // Aggregate accessors only. Never descend into cell.content.tables: it can revisit the parent.
        let lines = doc.text.lines.enumerated().map { i, line in
            let candidates = line.topCandidates(2)
            return DocumentLayoutEvidence.Line(id:"line-\(i+1)",text:line.transcript,
                box:.init(line.boundingRegion.boundingBox.cgRect),confidence:candidates.first?.confidence,
                alternatives:candidates.dropFirst().map(\.string))
        }
        var blocks = doc.paragraphs.enumerated().map { i, p in
            DocumentLayoutEvidence.Block(id:"paragraph-\(i+1)",kind:"paragraph",text:p.transcript,box:.init(p.boundingRegion.boundingBox.cgRect))
        }
        for (i,list) in doc.lists.enumerated() {
            for (j,item) in list.items.enumerated() {
                blocks.append(.init(id:"list-\(i+1)-item-\(j+1)",kind:"list_item",text:item.content.text.transcript,
                    box:.init(item.content.boundingRegion.boundingBox.cgRect)))
            }
        }
        let tables = doc.tables.enumerated().map { i, table in
            var seen = Set<String>(), cells: [DocumentLayoutEvidence.Cell] = []
            for row in table.rows { for cell in row {
                let id = "table-\(i+1)-r\(cell.rowRange.lowerBound)-\(cell.rowRange.upperBound)-c\(cell.columnRange.lowerBound)-\(cell.columnRange.upperBound)"
                guard seen.insert(id).inserted else { continue }
                cells.append(.init(id:id,rowStart:cell.rowRange.lowerBound,rowEnd:cell.rowRange.upperBound,
                    columnStart:cell.columnRange.lowerBound,columnEnd:cell.columnRange.upperBound,
                    text:cell.content.text.transcript,box:.init(cell.content.boundingRegion.boundingBox.cgRect)))
            } }
            return DocumentLayoutEvidence.Table(id:"table-\(i+1)",box:.init(table.boundingRegion.boundingBox.cgRect),cells:cells)
        }
        return .init(imageWidth:image.width,imageHeight:image.height,rawText:doc.text.transcript,lines:lines,blocks:blocks,tables:tables)
    }

    @available(macOS 26.0, iOS 26.0, *)
    private static func collectStructuredData(_ container: DocumentObservation.Container, into result: inout DocumentOutcome) {
        for barcode in container.barcodes {
            if let payload = barcode.payloadString, !payload.isEmpty {
                let code = VisionImageAnalysis.Code(symbology: String(describing: barcode.symbology).lowercased(),
                    payload: payload, confidence: barcode.confidence)
                if !result.codes.contains(where: { $0.payload == payload && $0.symbology == code.symbology }) { result.codes.append(code) }
            }
        }
        let text = container.text.transcript
        // Bound expensive native scanning; omitted data is reported, never
        // interpreted as an absence of sensitive fields.
        if text.utf8.count > 32_768 {
            result.issues.append("structured_data_text_budget_exceeded")
            return
        }
        for value in container.text.detectedData {
            // Preserve the exact recognized spelling; do not persist normalized dates,
            // inferred years/timezones, geocoded addresses or generated tracking URLs.
            if let item = literalDatum(value.match, in: text), !result.data.contains(item) { result.data.append(item) }
        }

        // Container accessors expose aggregate observations. Descending again
        // through cell.content.tables can revisit the same table indefinitely.
        // Read the document's aggregate text/barcodes exactly once.
    }

    @available(macOS 26.0, iOS 26.0, *)
    private static func literalDatum(_ match: DataDetector.Match, in text: String) -> VisionImageAnalysis.Datum? {
        guard let range = match.range,
              (range.lowerBound == text.endIndex || text.indices.contains(range.lowerBound)),
              (range.upperBound == text.endIndex || text.indices.contains(range.upperBound)),
              range.lowerBound <= range.upperBound else { return nil }
        let raw = String(text[range])
        guard !raw.isEmpty else { return nil }
        let kind: String
        switch match.details {
        case .link: kind = "link"
        case .emailAddress: kind = "email"
        case .phoneNumber: kind = "phone"
        case .postalAddress: kind = "address"
        case .calendarEvent: kind = "date_or_time"
        case .moneyAmount: kind = "money"
        case .flightNumber: kind = "flight"
        case .shipmentTrackingNumber: kind = "tracking"
        case .measurement: kind = "measurement"
        case .paymentIdentifier: kind = "payment_identifier"
        @unknown default: kind = "other"
        }
        return VisionImageAnalysis.Datum(kind: kind, text: raw)
    }

    private static func extractGeometricDocument(from image: CGImage) throws -> DocumentOutcome {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if #available(macOS 13.0, iOS 16.0, *) {
            request.automaticallyDetectsLanguage = true
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        let observations = request.results ?? []
        let lines: [VisionTextLine] = observations.compactMap { obs in
            guard let top = obs.topCandidates(1).first else { return nil }
            let trimmed = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return VisionTextLine(text: trimmed, boundingBox: obs.boundingBox)
        }

        let result = VisionDocumentFormatter.formatLinesWithMetrics(lines)
        var outcome = DocumentOutcome(
            markdown: result.markdown,
            wordCount: result.wordCount,
            textCoverage: result.textCoverage,
            hasStructuredTable: result.hasStructuredTable
        )
        let raw = observations.enumerated().compactMap { i, obs -> DocumentLayoutEvidence.Line? in
            let candidates = obs.topCandidates(2)
            guard let best = candidates.first else { return nil }
            return .init(id:"line-\(i+1)",text:best.string,box:.init(obs.boundingBox),confidence:best.confidence,
                         alternatives:candidates.dropFirst().map(\.string))
        }
        outcome.layout = .init(imageWidth:image.width,imageHeight:image.height,
            rawText:raw.map(\.text).joined(separator:"\n"),lines:raw)
        return outcome
    }

    @available(macOS 26.0, iOS 26.0, *)
    private static func formatRecognizedDocument(
        _ doc: DocumentObservation.Container
    ) -> DocumentOutcome {
        struct PositionedBlock {
            enum Kind {
                case paragraph(String, isListItem: Bool)
                case list(String)
                case table(String)
            }
            var kind: Kind
            var box: CGRect
            var singleLineHeight: CGFloat
        }

        var blocks: [PositionedBlock] = []
        var claimedParagraphIndices = Set<Int>()
        var tableBoxes: [CGRect] = []
        var listBoxes: [CGRect] = []
        var hasStructuredTable = false

        let paragraphBoxes = doc.paragraphs.map { $0.boundingRegion.boundingBox.cgRect }

        // 1. Tables
        for table in doc.tables {
            let tableBox = table.boundingRegion.boundingBox.cgRect
            let maxRow = table.rows.flatMap { $0.map(\.rowRange.upperBound) }.max() ?? -1
            let maxCol = table.rows.flatMap { $0.map(\.columnRange.upperBound) }.max() ?? -1
            guard maxRow >= 0, maxCol >= 0 else { continue }

            var grid = Array(
                repeating: Array(repeating: "", count: maxCol + 1),
                count: maxRow + 1
            )
            var cellBoxes = Array(
                repeating: Array(repeating: CGRect.null, count: maxCol + 1),
                count: maxRow + 1
            )

            for row in table.rows {
                for cell in row {
                    let text = cell.content.text.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    let cellBox = cell.content.boundingRegion.boundingBox.cgRect
                    let r = cell.rowRange.lowerBound
                    let c = cell.columnRange.lowerBound
                    if r <= maxRow, c <= maxCol {
                        grid[r][c] = text
                        cellBoxes[r][c] = cellBox
                    }
                }
            }

            // Borderless tables sometimes leave a leading/header cell blank in
            // `table.rows` while keeping the text in `doc.paragraphs`. Recover any
            // unclaimed paragraph whose vertical center aligns with an empty cell.
            for r in 0...maxRow {
                for c in 0...maxCol where grid[r][c].isEmpty {
                    let cBox = cellBoxes[r][c]
                    guard !cBox.isNull else { continue }
                    let expandedX = cBox.insetBy(dx: -0.05, dy: -0.01)
                    for (pIdx, p) in doc.paragraphs.enumerated() where !claimedParagraphIndices.contains(pIdx) {
                        let pBox = paragraphBoxes[pIdx]
                        guard pBox.midY >= cBox.minY - 0.015,
                              pBox.midY <= cBox.maxY + 0.015,
                              expandedX.intersects(pBox)
                        else { continue }
                        let pText = p.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !pText.isEmpty {
                            grid[r][c] = pText
                            claimedParagraphIndices.insert(pIdx)
                            break
                        }
                    }
                }
            }

            let rendered = VisionDocumentFormatter.renderMarkdownTable(rows: grid)
            if !rendered.isEmpty {
                blocks.append(PositionedBlock(kind: .table(rendered), box: tableBox, singleLineHeight: tableBox.height))
                tableBoxes.append(tableBox)
                hasStructuredTable = true
            }
        }

        // 2. Lists
        for list in doc.lists {
            let listBox = list.boundingRegion.boundingBox.cgRect
            var renderedItems: [String] = []
            for (idx, item) in list.items.enumerated() {
                let rawText = item.content.text.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rawText.isEmpty else { continue }
                let marker = item.markerString.trimmingCharacters(in: .whitespacesAndNewlines)
                let stripped: String
                if !marker.isEmpty, rawText.hasPrefix(marker) {
                    stripped = String(rawText.dropFirst(marker.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    stripped = VisionDocumentFormatter.stripLeadingListMarker(rawText)
                }
                guard !stripped.isEmpty else { continue }
                if VisionDocumentFormatter.isNumberedMarker(marker) {
                    renderedItems.append("\(idx + 1). \(stripped)")
                } else {
                    renderedItems.append("- \(stripped)")
                }
            }
            if !renderedItems.isEmpty {
                blocks.append(
                    PositionedBlock(
                        kind: .list(renderedItems.joined(separator: "\n")),
                        box: listBox,
                        singleLineHeight: listBox.height / CGFloat(max(1, renderedItems.count))
                    )
                )
                listBoxes.append(listBox)
            }
        }

        // 3. Remaining paragraphs & headings
        let lineHeights: [CGFloat] = doc.paragraphs.compactMap { p in
            let box = p.boundingRegion.boundingBox.cgRect
            let lineCount = max(1, p.lines.count)
            let h = box.height / CGFloat(lineCount)
            return h > 0 ? h : nil
        }
        let medianLineHeight = VisionDocumentFormatter.median(lineHeights) ?? 0
        let titleTranscript = doc.title?.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleBox = doc.title?.boundingRegion.boundingBox.cgRect
        let totalParagraphCount = doc.paragraphs.count

        for (pIdx, paragraph) in doc.paragraphs.enumerated() {
            if claimedParagraphIndices.contains(pIdx) { continue }
            let box = paragraphBoxes[pIdx]
            if tableBoxes.contains(where: { VisionDocumentFormatter.isContained(box, inside: $0) }) {
                continue
            }
            if listBoxes.contains(where: { VisionDocumentFormatter.isContained(box, inside: $0) }) {
                continue
            }

            let raw = paragraph.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }

            let lineCount = max(1, paragraph.lines.count)
            let singleLineHeight = box.height / CGFloat(lineCount)

            if let normalizedList = VisionDocumentFormatter.normalizeListLineIfApplicable(raw) {
                blocks.append(
                    PositionedBlock(
                        kind: .paragraph(normalizedList, isListItem: true),
                        box: box,
                        singleLineHeight: singleLineHeight
                    )
                )
                continue
            }

            let isDocumentTitle: Bool = {
                guard totalParagraphCount >= 2 else { return false }
                if let titleBox, VisionDocumentFormatter.isContained(box, inside: titleBox, threshold: 0.65) {
                    return true
                }
                if let titleTranscript, !titleTranscript.isEmpty,
                   raw == titleTranscript || raw.hasPrefix(titleTranscript) {
                    return pIdx == 0
                }
                return false
            }()

            let formatted = VisionDocumentFormatter.formatParagraphOrHeading(
                text: raw,
                lineCount: lineCount,
                singleLineHeight: singleLineHeight,
                boxWidth: box.width,
                boxMaxY: box.maxY,
                medianLineHeight: medianLineHeight,
                totalBlockCount: totalParagraphCount,
                isDocumentTitle: isDocumentTitle
            )
            blocks.append(
                PositionedBlock(
                    kind: .paragraph(formatted, isListItem: false),
                    box: box,
                    singleLineHeight: singleLineHeight
                )
            )
        }

        // Sort top-to-bottom first, then partition into full-width bands vs
        // multi-column sections so side-by-side columns/coupons are read
        // column-by-column rather than interleaved line-by-line.
        blocks.sort { a, b in
            let verticalOverlap = min(a.box.maxY, b.box.maxY) - max(a.box.minY, b.box.minY)
            let minH = max(0.001, min(a.box.height, b.box.height))
            if verticalOverlap > 0.5 * minH {
                return a.box.minX < b.box.minX
            }
            return a.box.maxY > b.box.maxY
        }

        func mergeColumnBlocks(_ colBlocks: [PositionedBlock]) -> [PositionedBlock] {
            var merged: [PositionedBlock] = []
            for block in colBlocks {
                if let last = merged.last,
                   case .paragraph(let prevText, isListItem: false) = last.kind,
                   case .paragraph(let currText, isListItem: false) = block.kind,
                   !prevText.hasPrefix("#"),
                   !currText.hasPrefix("#")
                {
                    let verticalGap = last.box.minY - block.box.maxY
                    let leftDiff = abs(last.box.minX - block.box.minX)
                    let heightRatio = block.singleLineHeight / max(0.001, last.singleLineHeight)
                    if verticalGap >= -0.3 * medianLineHeight,
                       verticalGap <= 0.85 * medianLineHeight,
                       leftDiff <= 0.05,
                       (0.75...1.33).contains(heightRatio)
                    {
                        var updated = last
                        updated.kind = .paragraph(
                            VisionDocumentFormatter.joinWrappedLines(prevText, currText),
                            isListItem: false
                        )
                        updated.box = last.box.union(block.box)
                        merged[merged.count - 1] = updated
                        continue
                    }
                }
                merged.append(block)
            }
            return merged
        }

        func arrangeNarrowSlice(_ slice: [PositionedBlock]) -> [PositionedBlock] {
            guard slice.count > 1 else { return slice }
            struct ColumnCluster {
                var minX: CGFloat
                var maxX: CGFloat
                var items: [PositionedBlock]
            }
            var clusters: [ColumnCluster] = []
            for b in slice {
                if let idx = clusters.firstIndex(where: { c in
                    let overlap = min(c.maxX, b.box.maxX) - max(c.minX, b.box.minX)
                    return overlap > -0.02 || abs(c.minX - b.box.minX) <= 0.06
                }) {
                    clusters[idx].minX = min(clusters[idx].minX, b.box.minX)
                    clusters[idx].maxX = max(clusters[idx].maxX, b.box.maxX)
                    clusters[idx].items.append(b)
                } else {
                    clusters.append(ColumnCluster(minX: b.box.minX, maxX: b.box.maxX, items: [b]))
                }
            }
            guard clusters.count > 1 else {
                return mergeColumnBlocks(slice)
            }
            clusters.sort { $0.minX < $1.minX }
            var arranged: [PositionedBlock] = []
            for var cluster in clusters {
                cluster.items.sort { $0.box.maxY > $1.box.maxY }
                arranged.append(contentsOf: mergeColumnBlocks(cluster.items))
            }
            return arranged
        }

        var orderedBlocks: [PositionedBlock] = []
        var narrowBuffer: [PositionedBlock] = []
        for block in blocks {
            let isFullWidth: Bool
            switch block.kind {
            case .table, .list:
                isFullWidth = true
            case .paragraph:
                isFullWidth = block.box.width >= 0.40
            }
            if isFullWidth {
                if !narrowBuffer.isEmpty {
                    orderedBlocks.append(contentsOf: arrangeNarrowSlice(narrowBuffer))
                    narrowBuffer.removeAll()
                }
                orderedBlocks.append(block)
            } else {
                narrowBuffer.append(block)
            }
        }
        if !narrowBuffer.isEmpty {
            orderedBlocks.append(contentsOf: arrangeNarrowSlice(narrowBuffer))
        }
        orderedBlocks = mergeColumnBlocks(orderedBlocks)

        var output = ""
        var prevWasListItem = false
        for block in orderedBlocks {
            let text: String
            let isListItem: Bool
            switch block.kind {
            case .paragraph(let s, let listFlag):
                text = s
                isListItem = listFlag
            case .list(let s):
                text = s
                isListItem = true
            case .table(let s):
                text = s
                isListItem = false
            }
            if output.isEmpty {
                output = text
            } else if prevWasListItem && isListItem {
                output += "\n" + text
            } else {
                output += "\n\n" + text
            }
            prevWasListItem = isListItem
        }

        let coverage = VisionDocumentFormatter.totalArea(of: paragraphBoxes)
        let words = VisionDocumentFormatter.countWords(in: output)
        return DocumentOutcome(
            markdown: output,
            wordCount: words,
            textCoverage: coverage,
            hasStructuredTable: hasStructuredTable
        )
    }

    // MARK: - Scene Observation

    private static func observeSceneWithIssues(on image: CGImage) -> (scene: VisionSceneObservation, issues: [String]) {
        let classifyRequest = VNClassifyImageRequest()
        let faceRequest = VNDetectFaceRectanglesRequest()
        let humanRequest = VNDetectHumanRectanglesRequest()
        humanRequest.upperBodyOnly = true
        let animalRequest = VNRecognizeAnimalsRequest()

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        var issues: [String] = []
        for (name, request) in [("classification", classifyRequest as VNRequest), ("faces", faceRequest),
                                ("humans", humanRequest), ("animals", animalRequest)] {
            do { try handler.perform([request]) } catch { issues.append(name + "_failed") }
        }

        let tags: [VisionSceneObservation.Tag] = (classifyRequest.results ?? [])
            .filter { $0.confidence >= 0.15 }
            .map { VisionSceneObservation.Tag(identifier: $0.identifier, confidence: $0.confidence) }

        let faceCount = faceRequest.results?.count ?? 0
        let humanCount = humanRequest.results?.count ?? 0

        var animalCounts: [String: Int] = [:]
        for obs in animalRequest.results ?? [] {
            if let top = obs.labels.first, top.confidence >= 0.35 {
                let key = top.identifier.lowercased()
                animalCounts[key, default: 0] += 1
            }
        }

        return (VisionSceneObservation(tags: tags, faceCount: faceCount, humanCount: humanCount,
                                       animalCounts: animalCounts), issues)
    }
}

// MARK: - Pure Document Layout Formatter

public enum VisionDocumentFormatter {
    public struct FormattedMetrics: Sendable, Equatable {
        public let markdown: String
        public let wordCount: Int
        public let textCoverage: CGFloat
        public let hasStructuredTable: Bool
    }

    /// Formats recognized text lines with normalized Vision bounding boxes into
    /// minimal Markdown (headings `#`/`##`, paragraphs, bullet/numbered lists,
    /// and Markdown tables `| col | col |`).
    public static func formatLines(_ lines: [VisionTextLine]) -> String {
        formatLinesWithMetrics(lines).markdown
    }

    public static func formatLinesWithMetrics(_ lines: [VisionTextLine]) -> FormattedMetrics {
        let validLines = lines.compactMap { line -> VisionTextLine? in
            let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return VisionTextLine(text: trimmed, boundingBox: line.boundingBox)
        }
        guard !validLines.isEmpty else {
            return FormattedMetrics(markdown: "", wordCount: 0, textCoverage: 0, hasStructuredTable: false)
        }

        let sorted = validLines.sorted { a, b in
            if abs(a.boundingBox.midY - b.boundingBox.midY) <= 0.5 * min(a.boundingBox.height, b.boundingBox.height) {
                return a.boundingBox.minX < b.boundingBox.minX
            }
            return a.boundingBox.midY > b.boundingBox.midY
        }

        // Group horizontally aligned items into visual rows.
        struct VisualRow {
            var segments: [VisionTextLine]
            var minY: CGFloat
            var maxY: CGFloat
            var midY: CGFloat { (minY + maxY) * 0.5 }
            var height: CGFloat { maxY - minY }
            var minX: CGFloat { segments.map(\.boundingBox.minX).min() ?? 0 }
        }

        var rows: [VisualRow] = []
        for line in sorted {
            if let lastIdx = rows.indices.last {
                let row = rows[lastIdx]
                let tolerance = 0.55 * min(row.height, line.boundingBox.height)
                if abs(row.midY - line.boundingBox.midY) <= tolerance {
                    rows[lastIdx].segments.append(line)
                    rows[lastIdx].minY = min(row.minY, line.boundingBox.minY)
                    rows[lastIdx].maxY = max(row.maxY, line.boundingBox.maxY)
                    rows[lastIdx].segments.sort { $0.boundingBox.minX < $1.boundingBox.minX }
                    continue
                }
            }
            rows.append(
                VisualRow(
                    segments: [line],
                    minY: line.boundingBox.minY,
                    maxY: line.boundingBox.maxY
                )
            )
        }

        // Merge horizontally adjacent segments within a row that have a tiny gap.
        for idx in rows.indices where rows[idx].segments.count > 1 {
            var merged: [VisionTextLine] = []
            for seg in rows[idx].segments {
                if let prev = merged.last,
                   seg.boundingBox.minX - prev.boundingBox.maxX <= max(0.02, 0.6 * min(prev.boundingBox.height, seg.boundingBox.height))
                {
                    let unionBox = prev.boundingBox.union(seg.boundingBox)
                    merged[merged.count - 1] = VisionTextLine(
                        text: prev.text + " " + seg.text,
                        boundingBox: unionBox
                    )
                } else {
                    merged.append(seg)
                }
            }
            rows[idx].segments = merged
        }

        let medianHeight = median(validLines.map(\.boundingBox.height)) ?? 0.02
        var blocks: [(text: String, isList: Bool)] = []
        var hasStructuredTable = false

        var rIdx = 0
        while rIdx < rows.count {
            // Check for consecutive multi-column rows that form a table.
            if rows[rIdx].segments.count >= 2 {
                var tableEnd = rIdx
                while tableEnd + 1 < rows.count, rows[tableEnd + 1].segments.count >= 2 {
                    let gapY = rows[tableEnd].minY - rows[tableEnd + 1].maxY
                    if gapY <= 2.2 * medianHeight {
                        tableEnd += 1
                    } else {
                        break
                    }
                }

                if tableEnd > rIdx {
                    let tableRows = rows[rIdx...tableEnd]
                    let grid = alignColumnsToGrid(tableRows.map(\.segments))
                    let rendered = renderMarkdownTable(rows: grid)
                    if !rendered.isEmpty {
                        blocks.append((rendered, false))
                        hasStructuredTable = true
                        rIdx = tableEnd + 1
                        continue
                    }
                } else {
                    // Single multi-column row (e.g. "Total: | $40.00")
                    let joined = rows[rIdx].segments.map(\.text).joined(separator: " | ")
                    blocks.append((joined, false))
                    rIdx += 1
                    continue
                }
            }

            let row = rows[rIdx]
            let rawText = row.segments.map(\.text).joined(separator: " ")

            if let listLine = normalizeListLineIfApplicable(rawText) {
                blocks.append((listLine, true))
                rIdx += 1
                continue
            }

            let formattedHeading = formatParagraphOrHeading(
                text: rawText,
                lineCount: 1,
                singleLineHeight: row.height,
                medianLineHeight: medianHeight,
                totalBlockCount: rows.count,
                isDocumentTitle: rIdx == 0 && rows.count >= 2 && row.height >= 1.45 * medianHeight
            )

            if formattedHeading.hasPrefix("#") {
                blocks.append((formattedHeading, false))
                rIdx += 1
                continue
            }

            // Accumulate consecutive body lines into a single paragraph when vertical
            // spacing is normal line leading and left margins match.
            var paragraphText = rawText
            var prevRow = row
            while rIdx + 1 < rows.count {
                let nextRow = rows[rIdx + 1]
                guard nextRow.segments.count == 1 else { break }
                let nextText = nextRow.segments[0].text
                if normalizeListLineIfApplicable(nextText) != nil { break }
                let nextHeading = formatParagraphOrHeading(
                    text: nextText,
                    lineCount: 1,
                    singleLineHeight: nextRow.height,
                    medianLineHeight: medianHeight,
                    totalBlockCount: rows.count,
                    isDocumentTitle: false
                )
                if nextHeading.hasPrefix("#") { break }

                let verticalGap = prevRow.minY - nextRow.maxY
                let leftDiff = abs(prevRow.minX - nextRow.minX)
                let heightRatio = nextRow.height / max(0.001, prevRow.height)
                guard verticalGap <= 0.85 * medianHeight,
                      leftDiff <= 0.06,
                      (0.75...1.33).contains(heightRatio)
                else { break }

                paragraphText = joinWrappedLines(paragraphText, nextText)
                prevRow = nextRow
                rIdx += 1
            }

            blocks.append((paragraphText, false))
            rIdx += 1
        }

        var output = ""
        var prevWasList = false
        for block in blocks {
            if output.isEmpty {
                output = block.text
            } else if prevWasList && block.isList {
                output += "\n" + block.text
            } else {
                output += "\n\n" + block.text
            }
            prevWasList = block.isList
        }

        let coverage = totalArea(of: validLines.map(\.boundingBox))
        let wordCount = countWords(in: output)
        return FormattedMetrics(
            markdown: output,
            wordCount: wordCount,
            textCoverage: coverage,
            hasStructuredTable: hasStructuredTable
        )
    }

    // MARK: - Table & Text Helpers

    public static func renderMarkdownTable(rows: [[String]]) -> String {
        let cleanedRows = rows.map { row in
            row.map { cell in
                cell.replacingOccurrences(of: "\r\n", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "|", with: "\\|")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }.filter { row in
            row.contains { !$0.isEmpty }
        }

        guard let maxCols = cleanedRows.map(\.count).max(), maxCols > 0, !cleanedRows.isEmpty else {
            return ""
        }

        let nonEmptyCols = (0..<maxCols).filter { col in
            cleanedRows.contains { row in col < row.count && !row[col].isEmpty }
        }
        guard !nonEmptyCols.isEmpty else { return "" }

        func formatRow(_ cells: [String]) -> String {
            "| " + cells.joined(separator: " | ") + " |"
        }

        let projectedRows: [[String]] = cleanedRows.map { row in
            nonEmptyCols.map { col in col < row.count ? row[col] : "" }
        }

        var lines: [String] = []
        lines.append(formatRow(projectedRows[0]))
        lines.append(formatRow(Array(repeating: "---", count: nonEmptyCols.count)))
        for row in projectedRows.dropFirst() {
            lines.append(formatRow(row))
        }
        return lines.joined(separator: "\n")
    }

    private static func alignColumnsToGrid(_ rowSegments: [[VisionTextLine]]) -> [[String]] {
        // Cluster segment minX values into column anchors.
        var anchors: [CGFloat] = []
        let allSegments = rowSegments.flatMap { $0 }.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
        for seg in allSegments {
            let x = seg.boundingBox.minX
            if let idx = anchors.firstIndex(where: { abs($0 - x) <= 0.08 }) {
                anchors[idx] = (anchors[idx] + x) * 0.5
            } else {
                anchors.append(x)
            }
        }
        anchors.sort()
        guard !anchors.isEmpty else { return [] }

        return rowSegments.map { segments in
            var row = Array(repeating: "", count: anchors.count)
            for seg in segments {
                let x = seg.boundingBox.minX
                let bestCol = anchors.enumerated().min {
                    abs($0.element - x) < abs($1.element - x)
                }?.offset ?? 0
                if row[bestCol].isEmpty {
                    row[bestCol] = seg.text
                } else {
                    row[bestCol] += " " + seg.text
                }
            }
            return row
        }
    }

    fileprivate static func formatParagraphOrHeading(
        text: String,
        lineCount: Int,
        singleLineHeight: CGFloat,
        boxWidth: CGFloat = 0.5,
        boxMaxY: CGFloat = 0.8,
        medianLineHeight: CGFloat,
        totalBlockCount: Int,
        isDocumentTitle: Bool
    ) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !singleLine.hasPrefix("#") else { return singleLine }

        let letterCount = singleLine.filter(\.isLetter).count
        // Vertical margin print (height > width) or tiny 1-3 letter scribbles are never headings.
        let hasHorizontalShape = boxWidth >= 2.2 * singleLineHeight && boxWidth >= 0.12
        let canBeHeading = lineCount <= 2
            && letterCount >= 5
            && singleLine.count <= 90
            && hasHorizontalShape
            && !singleLine.hasSuffix(".")
            && !singleLine.hasSuffix(";")
            && !singleLine.hasSuffix(",")

        if isDocumentTitle && canBeHeading {
            return "# \(singleLine)"
        }

        guard totalBlockCount >= 3, medianLineHeight > 0, canBeHeading else {
            return text
        }

        let ratio = singleLineHeight / medianLineHeight
        if ratio >= 1.60 && boxMaxY >= 0.72 {
            return "# \(singleLine)"
        } else if ratio >= 1.32 {
            return "## \(singleLine)"
        }
        return text
    }

    fileprivate static func normalizeListLineIfApplicable(_ text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        var normalizedLines: [String] = []
        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let bulletItem = matchBulletPrefix(trimmed) {
                normalizedLines.append("- \(bulletItem)")
            } else if let numberedItem = matchNumberedPrefix(trimmed) {
                normalizedLines.append(numberedItem)
            } else {
                return nil
            }
        }
        return normalizedLines.isEmpty ? nil : normalizedLines.joined(separator: "\n")
    }

    fileprivate static func stripLeadingListMarker(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let bullet = matchBulletPrefix(trimmed) { return bullet }
        if let (_, rest) = parseNumberedPrefix(trimmed) { return rest }
        return trimmed
    }

    fileprivate static func isNumberedMarker(_ marker: String) -> Bool {
        let trimmed = marker.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return false }
        return first.isNumber
    }

    private static func matchBulletPrefix(_ line: String) -> String? {
        let bullets = ["•", "·", "▪", "◦", "‣", "⁃", "-", "–", "—", "*"]
        for b in bullets {
            if line.hasPrefix(b + " ") || line.hasPrefix(b + "\t") {
                let rest = line.dropFirst(b.count).trimmingCharacters(in: .whitespaces)
                return rest.isEmpty ? nil : rest
            }
        }
        if let first = line.first, ["•", "·", "▪", "◦", "‣", "⁃"].contains(String(first)) {
            let rest = line.dropFirst().trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : rest
        }
        return nil
    }

    private static func matchNumberedPrefix(_ line: String) -> String? {
        guard let (num, rest) = parseNumberedPrefix(line) else { return nil }
        return "\(num). \(rest)"
    }

    private static func parseNumberedPrefix(_ line: String) -> (Int, String)? {
        var digits = ""
        var idx = line.startIndex
        while idx < line.endIndex, line[idx].isNumber, digits.count <= 3 {
            digits.append(line[idx])
            idx = line.index(after: idx)
        }
        guard !digits.isEmpty, let num = Int(digits), idx < line.endIndex else { return nil }
        let punct = line[idx]
        guard punct == "." || punct == ")" else { return nil }
        let afterPunct = line.index(after: idx)
        guard afterPunct < line.endIndex, line[afterPunct].isWhitespace else { return nil }
        let rest = line[afterPunct...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        return (num, rest)
    }

    fileprivate static func joinWrappedLines(_ first: String, _ second: String) -> String {
        if first.hasSuffix("-"),
           first.count >= 2,
           first[first.index(first.endIndex, offsetBy: -2)].isLetter,
           let nextFirst = second.first,
           nextFirst.isLowercase
        {
            return String(first.dropLast()) + second
        }
        return first + " " + second
    }

    fileprivate static func isContained(_ inner: CGRect, inside outer: CGRect, threshold: CGFloat = 0.55) -> Bool {
        let intersection = inner.intersection(outer)
        guard !intersection.isNull else { return false }
        let innerArea = max(0.00001, inner.width * inner.height)
        let overlapArea = intersection.width * intersection.height
        if overlapArea / innerArea >= threshold { return true }
        return outer.contains(CGPoint(x: inner.midX, y: inner.midY))
    }

    fileprivate static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) * 0.5
        }
        return sorted[mid]
    }

    fileprivate static func totalArea(of boxes: [CGRect]) -> CGFloat {
        let sum = boxes.reduce(CGFloat(0)) { acc, box in
            acc + max(0, box.width) * max(0, box.height)
        }
        return min(1.0, sum)
    }

    fileprivate static func countWords(in text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.filter { token in
            token.contains { $0.isLetter || $0.isNumber }
        }.count
    }
}

// MARK: - Scene Description Formatter

public enum VisionSceneFormatter {
    /// Classification labels that only indicate a text document or page rather
    /// than a real-world scene or subject.
    private static let pureDocumentTags: Set<String> = [
        "document", "printed_page", "screenshot", "receipt",
        "handwriting", "newspaper", "checkbook", "text"
    ]

    /// Broad hypernyms omitted when more specific scene/object tags or explicit
    /// subject counts are present.
    private static let umbrellaTags: Set<String> = [
        "structure", "material", "matter", "liquid", "container",
        "machine", "plant", "adult", "people", "person",
        "animal", "mammal", "canine", "feline", "vertebrate"
    ]

    /// True when the extracted text alone shows the image is a dense text document
    /// (so scene classification is unnecessary).
    public static func isDenseDocument(
        wordCount: Int,
        textCoverage: CGFloat,
        hasStructuredTable: Bool
    ) -> Bool {
        wordCount >= 35 || hasStructuredTable || textCoverage >= 0.16
    }

    /// Produces a compact `[scene: ...]` line when the image is a non-document
    /// photo or a mixed scene with short inscriptions, or returns `nil` when the
    /// image is a document or blank.
    public static func describe(
        _ observation: VisionSceneObservation,
        wordCount: Int,
        textCoverage: CGFloat = 0,
        hasStructuredTable: Bool = false
    ) -> String? {
        if isDenseDocument(
            wordCount: wordCount,
            textCoverage: textCoverage,
            hasStructuredTable: hasStructuredTable
        ) {
            return nil
        }

        let peopleCount = max(observation.faceCount, observation.humanCount)
        let hasAnimals = !observation.animalCounts.isEmpty
        let hasSubjects = peopleCount > 0 || hasAnimals

        // When there is already extracted text (1..<35 words) and the classifier's
        // strongest signal is a document/page with no people, animals, or strong
        // non-document objects, treat it as a short document/slide without a scene tag.
        let topDocConfidence = observation.tags
            .filter { pureDocumentTags.contains($0.identifier) }
            .map(\.confidence)
            .max() ?? 0
        let topSceneConfidence = observation.tags
            .filter { !pureDocumentTags.contains($0.identifier) && !umbrellaTags.contains($0.identifier) }
            .map(\.confidence)
            .max() ?? 0

        if wordCount > 0 && !hasSubjects {
            if topDocConfidence >= 0.40 && topSceneConfidence < 0.35 {
                return nil
            }
            if topSceneConfidence < 0.22 {
                return nil
            }
        }

        let minTagConfidence: Float = wordCount == 0 ? 0.18 : 0.22
        let candidateTags = observation.tags
            .filter { $0.confidence >= minTagConfidence && !pureDocumentTags.contains($0.identifier) }
            .sorted {
                if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
                return $0.identifier < $1.identifier
            }

        let selectedTags = selectDistinctTags(
            from: candidateTags,
            hasPeople: peopleCount > 0,
            animalKeys: Set(observation.animalCounts.keys)
        )

        var subjectParts: [String] = []
        if peopleCount == 1 {
            subjectParts.append(observation.faceCount == 1 ? "1 person (1 face)" : "1 person")
        } else if peopleCount > 1 {
            if observation.faceCount > 0 {
                let faceWord = observation.faceCount == 1 ? "face" : "faces"
                subjectParts.append("\(peopleCount) people (\(observation.faceCount) \(faceWord))")
            } else {
                subjectParts.append("\(peopleCount) people")
            }
        }

        for animal in observation.animalCounts.keys.sorted() {
            guard let count = observation.animalCounts[animal], count > 0 else { continue }
            let noun = count == 1 ? animal : "\(animal)s"
            subjectParts.append("\(count) \(noun)")
        }

        guard !selectedTags.isEmpty || !subjectParts.isEmpty else {
            return nil
        }

        let tagString = selectedTags.joined(separator: ", ")
        let subjectString = subjectParts.joined(separator: ", ")
        switch (!tagString.isEmpty, !subjectString.isEmpty) {
        case (true, true):
            return "[scene: \(tagString) | \(subjectString)]"
        case (true, false):
            return "[scene: \(tagString)]"
        case (false, true):
            return "[scene: \(subjectString)]"
        case (false, false):
            return nil
        }
    }

    private static func selectDistinctTags(
        from candidates: [VisionSceneObservation.Tag],
        hasPeople: Bool,
        animalKeys: Set<String>
    ) -> [String] {
        let nonUmbrella = candidates.filter { tag in
            let id = tag.identifier.lowercased()
            if umbrellaTags.contains(id) { return false }
            if hasPeople && (id == "people" || id == "adult" || id == "person") { return false }
            if animalKeys.contains(id) { return false }
            if id == "sign" && candidates.contains(where: { $0.identifier != "sign" && $0.confidence >= 0.22 }) {
                return false
            }
            return true
        }

        let pool = nonUmbrella.isEmpty
            ? candidates.filter { tag in
                let id = tag.identifier.lowercased()
                if hasPeople && (id == "people" || id == "adult" || id == "person") { return false }
                if animalKeys.contains(id) { return false }
                return true
            }
            : nonUmbrella

        let formattedPool: [(words: Set<String>, display: String)] = pool.map { tag in
            let display = tag.identifier
                .lowercased()
                .replacingOccurrences(of: "_", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let words = Set(display.split(separator: " ").map(String.init))
            return (words, display)
        }

        // Drop single-word component tags when a more specific compound tag in the
        // top candidates already includes that word (e.g. drop "wine" and "bottle"
        // when "wine bottle" is present).
        var result: [String] = []
        var seenDisplays = Set<String>()
        let topSlice = formattedPool.prefix(10)
        for (idx, item) in topSlice.enumerated() {
            guard !item.display.isEmpty, !seenDisplays.contains(item.display) else { continue }
            let isRedundantSubset = topSlice.enumerated().contains { otherIdx, other in
                guard otherIdx != idx, other.words.count > item.words.count else { return false }
                return item.words.isSubset(of: other.words)
            }
            if isRedundantSubset { continue }
            seenDisplays.insert(item.display)
            result.append(item.display)
            if result.count >= 6 { break }
        }

        return result
    }
}
