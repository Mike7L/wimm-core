import XCTest
import CoreGraphics
import WimmDomain
@testable import WimmInfrastructure

final class ImageBatchStoreTests: XCTestCase {
    func testMultipleScreenshotsKeepVoiceAndUnknownMetadata() throws {
        let folder = try fixture(), note = folder.appendingPathComponent("voice.m4a")
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: note)
        let a = folder.appendingPathComponent("voice_screen1.png"), b = folder.appendingPathComponent("voice_screen3.png")
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: note)) {
            $0["transcription"] = ["transcript":"Original voice", "quality":["score":0.8]]
            $0["ocr"] = ["text":"Earlier screenshot OCR"]
            $0["syncId"] = "KEEP"; $0["noteCard"] = ["title":"KEEP"]; return true
        }
        let ta = LibraryImageInventory.Target(note: note.path, image: a.path, kind: .screenshot, attachmentID: nil)
        let tb = LibraryImageInventory.Target(note: note.path, image: b.path, kind: .screenshot, attachmentID: nil)
        XCTAssertEqual(try ImageBatchStore.apply([(ta,record(a,"First screen")),(tb,record(b,"Third screen"))], to: note),2)
        var meta = try read(note), ocr = try XCTUnwrap(meta["ocr"] as? [String:Any])
        XCTAssertEqual((meta["transcription"] as? [String:Any])?["transcript"] as? String,"Original voice")
        XCTAssertEqual(meta["syncId"] as? String,"KEEP")
        XCTAssertEqual((meta["noteCard"] as? [String:Any])?["title"] as? String,"KEEP")
        let text = try XCTUnwrap(ocr["text"] as? String)
        XCTAssertTrue(text.contains("First screen")); XCTAssertTrue(text.contains("Third screen"))
        XCTAssertEqual((ocr["images"] as? [[String:Any]])?.count,2)
        XCTAssertTrue(((ocr["previousRuns"] as? [[String:Any]]) ?? []).contains { $0["text"] as? String == "Earlier screenshot OCR" })
        _ = try ImageBatchStore.apply([(tb,record(b,""))],to:note)
        meta = try read(note); ocr = try XCTUnwrap(meta["ocr"] as? [String:Any])
        XCTAssertTrue((ocr["text"] as? String ?? "").contains("Third screen"))
    }
    func testAttachmentUpdatePreservesHistoryAndOriginalTextNote() throws {
        let folder = try fixture(), note = folder.appendingPathComponent("note.txt"), image = folder.appendingPathComponent("photo.png"), id = UUID()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("User text".utf8).write(to: note)
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: note)) {
            $0["attachments"] = [["id":id.uuidString,"url":image.absoluteString,"type":"image","extractedText":"Old OCR","custom":42]]; return true
        }
        let target = LibraryImageInventory.Target(note: note.path,image:image.path,kind:.attachment,attachmentID:id)
        _ = try ImageBatchStore.apply([(target,record(image,"New OCR"))],to:note)
        let rows = try XCTUnwrap(try read(note)["attachments"] as? [[String:Any]])
        XCTAssertEqual(rows[0]["custom"] as? Int,42)
        XCTAssertEqual(rows[0]["extractedText"] as? String,"New OCR")
        XCTAssertTrue(((rows[0]["previousRuns"] as? [[String:Any]]) ?? []).contains { $0["text"] as? String == "Old OCR" })
        XCTAssertEqual(try String(contentsOf:note,encoding:.utf8),"User text")
    }
    func testStandaloneArchivesOldRunAndDoesNotBorrowConfidence() throws {
        let folder = try fixture(), note = folder.appendingPathComponent("photo.png")
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to:note)
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: note)) {
            $0["transcription"] = ["transcript":"Old image OCR","confidence":0.9,"quality":["old":true],"provider":"gemini","custom":"KEEP"]
            $0["ocr"] = ["text":"Old image OCR"]; $0["refinedText"] = "User refinement"; return true
        }
        let target = LibraryImageInventory.Target(note:note.path,image:note.path,kind:.standalone,attachmentID:nil)
        _ = try ImageBatchStore.apply([(target,record(note,"New image OCR"))],to:note)
        let meta = try read(note), transcription = try XCTUnwrap(meta["transcription"] as? [String:Any])
        XCTAssertEqual(transcription["transcript"] as? String,"New image OCR")
        XCTAssertNil(transcription["confidence"]); XCTAssertNil(transcription["quality"])
        XCTAssertEqual(transcription["custom"] as? String,"KEEP")
        XCTAssertEqual(meta["refinedText"] as? String,"User refinement")
        XCTAssertTrue(((transcription["previousRuns"] as? [[String:Any]]) ?? []).contains { $0["transcript"] as? String == "Old image OCR" })
    }
    func testInventoryIncludesScreenGapsAndLegacyAttachments() async throws {
        let dir = FileStore.recordingsDirectory(), token = "TEST-"+UUID().uuidString
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let names = [token+".m4a",token+"_screen1.png",token+"_screen3.heic",token+"_Attach_photo.jpg"]
        let files = names.map { dir.appendingPathComponent($0) }
        defer { for file in files { try? FileManager.default.removeItem(at:file) } }
        for file in files { try Data().write(to:file) }
        let inventory = await LibraryImageInventory.scan(), own = inventory.targets.filter { $0.note.map { URL(fileURLWithPath:$0).lastPathComponent == files[0].lastPathComponent } ?? false }
        XCTAssertEqual(Set(own.map(\.image)),Set(files.dropFirst().map { $0.resolvingSymlinksInPath().path }), "Actual owned fixture targets: \(inventory.targets.filter { $0.image.contains(token) })")
        XCTAssertEqual(own.filter { $0.kind == .screenshot }.count,2)
        XCTAssertEqual(own.filter { $0.kind == .attachment }.count,1)
    }
    func testStandaloneCannotOverwriteAudio() throws {
        let folder = try fixture(), note = folder.appendingPathComponent("voice.m4a")
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: note)
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: note)) { $0["transcription"] = ["transcript":"Voice stays"]; return true }
        let target = LibraryImageInventory.Target(note: note.path, image: note.path, kind: .standalone, attachmentID: nil)
        XCTAssertThrowsError(try ImageBatchStore.apply([(target,record(note,"Wrong image text"))],to:note))
        XCTAssertEqual((try read(note)["transcription"] as? [String:Any])?["transcript"] as? String,"Voice stays")
    }
    #if os(macOS)
    func testCLIApplyBacksUpAndResumesWithoutRewriting() throws {
        let binary = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/WimmCLI")
        guard FileManager.default.isExecutableFile(atPath:binary.path) else { throw XCTSkip("CLI not built") }
        let folder = try fixture(), library = folder.appendingPathComponent("library"), run = folder.appendingPathComponent("run")
        defer { try? FileManager.default.removeItem(at:folder) }
        try FileManager.default.createDirectory(at:library,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:run.appendingPathComponent("results"),withIntermediateDirectories:true)
        let note = library.appendingPathComponent("photo.png")
        try Data("image fixture".utf8).write(to:note)
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL:note)) { $0["custom"] = "KEEP"; $0["ocr"] = ["text":"Old OCR"]; return true }
        let original = try Data(contentsOf:FileStore.metadataURL(forRecordingURL:note))
        let target = LibraryImageInventory.Target(note:note.path,image:note.path,kind:.standalone,attachmentID:nil)
        let inventory = LibraryImageInventory.Inventory(targets:[target],notes:1,excludedPreviews:0,missingAttachments:0)
        try JSONEncoder().encode(inventory).write(to:run.appendingPathComponent("manifest.json"))
        var result = ImageBatchRecord(source:note.path,sourceSHA256:try ImageBatchRecord.hash(note),engine:"vision")
        result.vision = record(note,"New OCR").vision
        try JSONEncoder().encode(result).write(to:run.appendingPathComponent("results/"+ImageBatchRecord.id(for:note.path)+".json"))
        func launch() throws {
            let child = Process(); child.executableURL = binary
            child.arguments = ["photos","apply-results","--run",run.path,"--apply"]
            var env = ProcessInfo.processInfo.environment; env["WIMM_BASE_DIR"] = library.path; env["WIMM_TEST_MODE"] = "1"
            child.environment = env; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
            try child.run(); child.waitUntilExit(); XCTAssertEqual(child.terminationStatus,0)
        }
        try launch()
        XCTAssertEqual((try read(note)["ocr"] as? [String:Any])?["text"] as? String,"New OCR")
        let backups = try FileManager.default.contentsOfDirectory(at:run.appendingPathComponent("sidecar-backups"),includingPropertiesForKeys:nil)
        XCTAssertEqual(backups.count,1); XCTAssertEqual(try Data(contentsOf:backups[0]),original)
        let saved = try Data(contentsOf:FileStore.metadataURL(forRecordingURL:note))
        try launch(); XCTAssertEqual(try Data(contentsOf:FileStore.metadataURL(forRecordingURL:note)),saved)
    }
    #endif
    func testImageAnchorWithSurvivingMicroNeverReplacesVoice() throws {
        let folder = try fixture(), note = folder.appendingPathComponent("lost-audio.heic")
        defer { try? FileManager.default.removeItem(at:folder) }
        try Data().write(to:note); try Data().write(to:FileStore.microURL(forRecordingURL:note))
        try FileStore.mutateSidecar(at:FileStore.metadataURL(forRecordingURL:note)) {
            $0["transcription"] = ["transcript":"Only surviving voice transcript","provider":"gemini"]
            $0["ocr"] = ["source":"screenshot","text":"Previous screen text"]; return true
        }
        let target = LibraryImageInventory.Target(note:note.path,image:note.path,kind:.standalone,attachmentID:nil)
        _ = try ImageBatchStore.apply([(target,record(note,"New screen OCR"))],to:note)
        let meta = try read(note)
        XCTAssertEqual((meta["transcription"] as? [String:Any])?["transcript"] as? String,"Only surviving voice transcript")
        XCTAssertEqual((meta["ocr"] as? [String:Any])?["text"] as? String,"New screen OCR")
    }
    func testUnclassifiedExistingImageBodyIsPreserved() throws {
        let folder = try fixture(), note = folder.appendingPathComponent("photo.png")
        defer { try? FileManager.default.removeItem(at:folder) }
        try Data().write(to:note)
        try FileStore.mutateSidecar(at:FileStore.metadataURL(forRecordingURL:note)) { $0["transcription"] = ["transcript":"User edited body"]; return true }
        let target = LibraryImageInventory.Target(note:note.path,image:note.path,kind:.standalone,attachmentID:nil)
        _ = try ImageBatchStore.apply([(target,record(note,"New OCR"))],to:note)
        XCTAssertEqual((try read(note)["transcription"] as? [String:Any])?["transcript"] as? String,"User edited body")
    }
    func testTinyImageIsAnExplicitSkippedCheck() async throws {
        let context = try XCTUnwrap(CGContext(data:nil,width:5,height:42,bitsPerComponent:8,bytesPerRow:20,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue))
        let analysis = try await VisionDocumentAndSceneExtractor.analyze(image:XCTUnwrap(context.makeImage()))
        XCTAssertTrue(analysis.issues.contains("image_too_small_for_recognition"))
        XCTAssertNil(analysis.sceneObservation);XCTAssertTrue(analysis.ocrText.isEmpty)
        var result = ImageBatchRecord(source:"tiny.gif",sourceSHA256:"test",engine:"mlx")
        result.vision = analysis
        XCTAssertTrue(result.isComplete) // Complete disposition, not a healthy semantic detector result.
        XCTAssertNil(result.caption)
    }
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true); return url
    }
    private func read(_ note:URL) throws -> [String:Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:FileStore.metadataURL(forRecordingURL:note))) as? [String:Any])
    }
    private func record(_ image:URL,_ text:String) -> ImageBatchRecord {
        var result = ImageBatchRecord(source:image.path,sourceSHA256:"test",engine:"vision")
        result.vision = VisionImageAnalysis(ocrText:text,scene:nil,sceneObservation:nil,codes:[],detectedData:[],isDenseDocument:true,documentEngine:"test",issues:[])
        return result
    }
}
