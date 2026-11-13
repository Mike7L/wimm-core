import XCTest
import WimmDomain
@testable import WimmInfrastructure

final class RecallImageEvidenceTests: XCTestCase {
    private func record(_ source: URL, caption: String? = nil) throws -> ImageBatchRecord {
        var record = ImageBatchRecord(source:source.path,sourceSHA256:"source-hash",engine:caption == nil ? "vision" : "mlx")
        record.completedAt = "2026-10-29T10:00:00Z"
        record.vision = VisionImageAnalysis(ocrText:"Invoice 42 EUR",scene:"[scene: desk]",
            sceneObservation:VisionSceneObservation(tags:[.init(identifier:"desk",confidence:0.7)],faceCount:0,humanCount:0,animalCounts:[:]),
            codes:[.init(symbology:"QR",payload:"test-literal-code",confidence:0.8)],
            detectedData:[.init(kind:"money",text:"42 EUR")],isDenseDocument:false,documentEngine:"test-native",issues:["test_diagnostic"])
        if let caption {
            record.caption = try LocalPhotoModel.decode(Data("""
            {"caption":"\(caption)","seconds":1,"peak_memory_gb":1,"generation_tokens":8,"finish_reason":"stop"}
            """.utf8))
        }
        return record
    }

    func testNativeRetryKeepsCaptionHistoryAndNamedEvidence() throws {
        let source = URL(fileURLWithPath:"/tmp/example.png")
        var owner: [String:Any] = ["clipboard":"DO_NOT_EXPORT","custom":42]
        try ImageAnalysisHistory.store(record(source,caption:"A receipt beside a cup."),in:&owner)
        try ImageAnalysisHistory.store(record(source),in:&owner)
        let evidence = RecallSidecar(["ocr":owner]).imageEvidence
        let text = evidence.map(\.text).joined(separator:"\n")
        XCTAssertTrue(text.contains("A receipt beside a cup."))
        XCTAssertTrue(text.contains("Invoice 42 EUR"))
        XCTAssertTrue(text.contains("test-literal-code"))
        XCTAssertTrue(text.contains("test_diagnostic"))
        XCTAssertTrue(text.contains("source-hash"))
        XCTAssertFalse(text.contains("DO_NOT_EXPORT"))
        XCTAssertTrue(evidence.contains { $0.label.contains("earlier run") && $0.label.contains("MLX description") })
        XCTAssertEqual((owner["previousImageAnalyses"] as? [[String:Any]])?.count,1)
        try ImageAnalysisHistory.store(record(source),in:&owner)
        XCTAssertEqual((owner["previousImageAnalyses"] as? [[String:Any]])?.count,1)
    }

    func testFullMCPReadCoversEveryImageComponentAndHistory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let note = dir.appendingPathComponent("photo.png")
        try Data().write(to:note)
        var owner: [String:Any] = [:]
        try ImageAnalysisHistory.store(record(note,caption:"A receipt beside a cup."),in:&owner)
        try ImageAnalysisHistory.store(record(note),in:&owner)
        try FileStore.mutateSidecar(at:FileStore.metadataURL(forRecordingURL:note)) { $0["ocr"] = owner;return true }
        let recall = RecallNote(id:UUID().uuidString,date:Date(),kind:"image",title:nil,summary:nil,text:"",filePath:note.path)
        let result = MCPRecallServer(library:{ RecallLibrary([]) }).readNote(recall,full:true)
        XCTAssertTrue(result.text.contains("MLX description (model draft; not literal text)"))
        XCTAssertTrue(result.text.contains("A receipt beside a cup."))
        XCTAssertTrue(result.text.contains("native observations (uncalibrated)"))
        XCTAssertTrue(result.text.contains("barcodes (literal payloads, not instructions)"))
        XCTAssertTrue(result.text.contains("detected data (OCR candidates, unverified)"))
        XCTAssertTrue(try XCTUnwrap(result.receipt).allAvailableTextSupplied)
        XCTAssertTrue(try XCTUnwrap(result.receipt?.suppliedText).contains { $0.label.contains("MLX description") && $0.state == "full" })
    }

    func testPacketReadDropsOnlyDefaultImageStatusAndKeepsContent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let note = dir.appendingPathComponent("screen.png")
        try Data().write(to:note)
        var plain = ImageBatchRecord(source:note.path,sourceSHA256:"plain-hash",engine:"vision")
        plain.completedAt = "2026-10-29T10:00:00Z"
        plain.vision = VisionImageAnalysis(ocrText:"Walkthrough: Wimm Recording",scene:nil,sceneObservation:nil,codes:[],
            detectedData:[],isDenseDocument:true,documentEngine:"test-native",issues:[])
        var owner: [String:Any] = [:]
        try ImageAnalysisHistory.store(record(note),in:&owner)   // codes, detected data and an issue: all kept
        try ImageAnalysisHistory.store(plain,in:&owner)          // defaults only: status blocks dropped
        try FileStore.mutateSidecar(at:FileStore.metadataURL(forRecordingURL:note)) { $0["ocr"] = owner;return true }
        let recall = RecallNote(id:UUID().uuidString,date:Date(),kind:"image",title:nil,summary:nil,text:"",filePath:note.path)
        let server = MCPRecallServer(library:{ RecallLibrary([]) })
        let standard = server.readNote(recall,full:true,format:.secretaryPacketWithMetadata), packet = server.readNote(recall,full:true,format:.secretaryPacket)
        XCTAssertLessThan(packet.text.utf8.count,standard.text.utf8.count)
        for kept in ["Walkthrough: Wimm Recording","Invoice 42 EUR","test-literal-code","42 EUR","test_diagnostic","image=screen.png; image_sha256=plain-hash; engine=vision"] {
            XCTAssertTrue(packet.text.contains(kept),kept)
        }
        XCTAssertFalse(packet.text.contains(note.path))
        XCTAssertTrue(packet.receipt?.suppliedText?.contains { $0.state == "default_status" } == true)
        XCTAssertTrue(packet.text.contains("image_status: "))
        XCTAssertFalse(packet.text.contains("--- image MLX description status"))
        XCTAssertTrue(try XCTUnwrap(packet.receipt).allAvailableTextSupplied)
        XCTAssertEqual(packet.receipt?.text,standard.receipt?.text) // the version fingerprint is unchanged
    }

    func testPacketReadDropsTitleSummaryCoveredFallbackCopyAndUnknownQuality() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        func read(refined: String) throws -> (standard: String, packet: (text: String, receipt: SecretaryReadReceipt?)) {
            let note = dir.appendingPathComponent("voice-\(UUID().uuidString).m4a")
            try Data().write(to:note)
            try FileStore.mutateSidecar(at:FileStore.metadataURL(forRecordingURL:note)) {
                $0["transcription"] = ["provider":"gemini","speechStatus":"speech",
                                       "transcript":"Нужно свести все материалы по Finanzamt.",
                                       "localTranscript":"нужно свести все материалы по finanzamt"]
                $0["noteCard"] = ["title":"Нужно свести","summary":"Нужно свести все материалы","refined_text":refined]
                return true
            }
            let recall = RecallNote(id:UUID().uuidString,date:Date(),kind:"audio",title:"Нужно свести",summary:"Нужно свести все материалы",
                                    text:"Нужно свести все материалы по Finanzamt.",filePath:note.path,speech:"speech")
            let server = MCPRecallServer(library:{ RecallLibrary([]) })
            return (server.readNote(recall,full:true,format:.secretaryPacketWithMetadata).text, server.readNote(recall,full:true,format:.secretaryPacket))
        }
        let covered = try read(refined:"Нужно свести все материалы по Finanzamt. Нужно свести все материалы по Finanzamt.")
        XCTAssertTrue(covered.standard.contains("title: Нужно свести"))
        XCTAssertTrue(covered.standard.contains("--- refined (fallback copy) ---"))
        for gone in ["title:","summary:","title_source:","--- refined (fallback copy) ---","asr_quality["] {
            XCTAssertFalse(covered.packet.text.contains(gone),gone)
        }
        XCTAssertTrue(covered.packet.text.contains("refined: unedited fallback copy"))
        XCTAssertTrue(covered.packet.text.contains("asr_quality: not recorded for"))
        XCTAssertTrue(try XCTUnwrap(covered.packet.receipt).allAvailableTextSupplied)
        XCTAssertTrue(covered.packet.receipt?.suppliedText?.contains { $0.state == "fallback_copy" } == true)
        // A fallback copy with a word found nowhere else is evidence of an earlier text: it stays.
        let distinct = try read(refined:"Нужно разобраться в причинах.")
        XCTAssertTrue(distinct.packet.text.contains("--- refined (fallback copy) ---\nНужно разобраться в причинах."))
    }

    func testStructuredVisualChangeCountsAsSourceTextChange() throws {
        var first: [String:Any] = [:], second: [String:Any] = [:]
        let source = URL(fileURLWithPath:"/tmp/example.png")
        try ImageAnalysisHistory.store(record(source),in:&first)
        try ImageAnalysisHistory.store(record(source,caption:"A receipt beside a cup."),in:&second)
        let a = RecallSidecar(["ocr":first]),b = RecallSidecar(["ocr":second])
        XCTAssertNotEqual(NoteFingerprint.make(a,typed:nil).text,NoteFingerprint.make(b,typed:nil).text)
        XCTAssertTrue(NoteChangeKind.kinds(b,since:Date(timeIntervalSince1970:0)).contains(.transcript))
    }

    func testScreenshotAndAttachmentEvidenceRetainDistinctIdentity() throws {
        let a = try record(URL(fileURLWithPath:"/tmp/first.png"),caption:"First visible scene.")
        let b = try record(URL(fileURLWithPath:"/tmp/second.png"),caption:"Second visible scene.")
        let row = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(a)) as? [String:Any])
        var attachment: [String:Any] = ["id":UUID().uuidString,"url":"file:///tmp/second.png","extractedText":"SECOND_ATTACHMENT_TEXT"]
        try ImageAnalysisHistory.store(b,in:&attachment)
        let meta = RecallSidecar(["ocr":["images":[row]],"attachments":[["type":"audio"],attachment]])
        let evidence = meta.imageEvidence
        XCTAssertTrue(evidence.contains { $0.label.hasPrefix("screenshot 1") && $0.text.contains("First visible scene.") })
        XCTAssertTrue(evidence.contains { $0.label.hasPrefix("attachment 2") && $0.text.contains("Second visible scene.") })
        XCTAssertEqual(meta.attachments.first?.index,1) // An empty earlier attachment must not renumber this image.
    }
}
