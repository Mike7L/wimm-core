import XCTest
import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import WimmDomain
@testable import WimmInfrastructure

final class DocumentVisualEvidenceTests: XCTestCase {
    private func folder() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true);return path
    }
    private func image(_ url: URL) throws {
        // Explicit top-to-bottom pixels: red upper half, blue lower half.
        var bytes = [UInt8](repeating:0,count:100*100*4)
        for y in 0..<100 { for x in 0..<100 { let i=(y*100+x)*4;bytes[i+(y<50 ? 0 : 2)]=255;bytes[i+3]=255 } }
        let provider = try XCTUnwrap(CGDataProvider(data:Data(bytes) as CFData))
        let raster = try XCTUnwrap(CGImage(width:100,height:100,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:400,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil))
        CGImageDestinationAddImage(dest,raster,nil);XCTAssertTrue(CGImageDestinationFinalize(dest))
    }
    func testVisualCropUsesBottomLeftCoordinatesAndDoesNotModifyOriginal() throws {
        let dir = try folder();defer { try? FileManager.default.removeItem(at:dir) }
        let url=dir.appendingPathComponent("image.png");try image(url)
        let before=try ImageBatchRecord.hash(url)
        let result=try NoteVisualSource.export(.init(url:url,role:"primary"),page:1,crop:CGRect(x:0,y:0,width:1,height:0.5))
        let source=try XCTUnwrap(CGImageSourceCreateWithData(result.data as CFData,nil))
        let decoded=try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
        let context=try XCTUnwrap(CGContext(data:nil,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(decoded,in:CGRect(x:0,y:0,width:1,height:1))
        let pixel=try XCTUnwrap(context.data).assumingMemoryBound(to:UInt8.self)
        XCTAssertGreaterThan(pixel[2],220);XCTAssertLessThan(pixel[0],30)
        XCTAssertEqual(try ImageBatchRecord.hash(url),before)
        XCTAssertThrowsError(try NoteVisualSource.export(.init(url:url,role:"primary"),page:2,crop:nil))
        XCTAssertThrowsError(try NoteVisualSource.export(.init(url:url,role:"primary"),page:1,crop:CGRect(x:-0.1,y:0,width:1,height:1)))
    }
    func testMCPReturnsActualImageAndRefusesPrivateOrUnownedSource() async throws {
        let dir=try folder();defer { try? FileManager.default.removeItem(at:dir) }
        let url=dir.appendingPathComponent("image.png");try image(url)
        let note=RecallNote(id:"visual-note",date:Date(),kind:"image",title:nil,summary:nil,text:"",filePath:url.path)
        let server=MCPRecallServer(isPrivate:{false},library:{RecallLibrary([note])})
        let reply=await server.callTool(name:"get_note_image",arguments:["id":"visual-note","image_index":1])
        let content=try XCTUnwrap(reply["content"] as? [[String:Any]])
        XCTAssertEqual(content.last?["type"] as? String,"image")
        XCTAssertFalse((content.last?["data"] as? String ?? "").isEmpty)
        let invalid=await server.callTool(name:"get_note_image",arguments:["id":"visual-note","image_index":2])
        XCTAssertEqual(invalid["isError"] as? Bool,true)
        let privateServer=MCPRecallServer(isPrivate:{true},library:{RecallLibrary([note])})
        let refused=await privateServer.callTool(name:"get_note_image",arguments:["id":"visual-note","image_index":1])
        XCTAssertEqual(refused["isError"] as? Bool,true)
    }
    func testPDFFailureAndHistoryStayPageBound() throws {
        var doc:[String:Any]=[:]
        try DocumentPageEvidence.store([.init(page:1,text:"FIRST",provider:"pdfkit"),.init(page:2,text:"",provider:"vision",error:"ocr_failed")],sourceSHA256:"hash1",in:&doc)
        try DocumentPageEvidence.store([.init(page:1,text:"NEW FIRST",provider:"pdfkit"),.init(page:2,text:"SECOND",provider:"vision")],sourceSHA256:"hash1",in:&doc)
        let blocks=RecallSidecar(["document":doc]).imageEvidence
        XCTAssertTrue(blocks.contains { $0.label=="document page 2 text" && $0.text=="SECOND" })
        XCTAssertTrue(blocks.contains { $0.label=="document earlier run 1 page 2 unavailable content" && $0.text=="ocr_failed" })
        XCTAssertTrue(blocks.contains { $0.label=="document earlier run 1 page 1 text" && $0.text=="FIRST" })
    }
    func testLegacyCaptionDoesNotAcquireCurrentModelIdentity() throws {
        var record=ImageBatchRecord(source:"legacy.png",sourceSHA256:nil,engine:"mlx")
        record.caption=try LocalPhotoModel.decode(Data(#"{"caption":"A test object.","seconds":1,"peak_memory_gb":1,"generation_tokens":3,"finish_reason":"stop"}"#.utf8))
        XCTAssertTrue(record.model.contains("legacy"));XCTAssertFalse(record.model.contains(LocalPhotoModel.identifier))
        record.stampCaptionRun()
        XCTAssertEqual(record.modelSnapshot?.maxTokens,128)
        XCTAssertEqual(record.modelSnapshot?.identifier,LocalPhotoModel.identifier)
    }
}
