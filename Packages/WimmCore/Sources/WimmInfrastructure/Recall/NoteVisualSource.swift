import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PDFKit
import WimmDomain
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

enum NoteVisualSource {
    struct Asset {
        let url: URL
        let role: String
    }
    static func assets(for note: URL) -> [Asset] {
        guard FileManager.default.fileExists(atPath:note.path) else { return [] }
        let meta = RecallSidecar.load(forRecordingURL:note)?.sidecar.dict ?? [:]
        var assets: [Asset] = [], seen = Set<String>()
        func add(_ url: URL, _ role: String) {
            guard LibraryImageInventory.isImage(url) || url.pathExtension.lowercased() == "pdf" else { return }
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            guard seen.insert(canonical.path).inserted else { return }
            assets.append(.init(url:canonical,role:role))
        }
        add(note,"primary")
        for (i,item) in NoteAttachmentMedia.items(in:meta).enumerated() { add(item.url,"attachment \(i+1)") }
        for target in LibraryImageInventory.targets(for:note) { add(URL(fileURLWithPath:target.image),target.kind.rawValue) }
        return assets
    }

    static func raster(_ url: URL, page: Int) throws -> CGImage {
        if url.pathExtension.lowercased() == "pdf" {
            guard let pdf = PDFDocument(url:url), (1...max(1,pdf.pageCount)).contains(page), let sheet = pdf.page(at:page-1) else { throw CocoaError(.fileReadCorruptFile) }
            let bounds = sheet.bounds(for:.mediaBox)
            let scale = min(3,2048 / max(bounds.width,bounds.height))
            let thumbnail = sheet.thumbnail(of:CGSize(width:bounds.width*scale,height:bounds.height*scale),for:.mediaBox)
            #if canImport(AppKit)
            guard let image = thumbnail.cgImage(forProposedRect:nil,context:nil,hints:nil) else { throw CocoaError(.fileReadCorruptFile) }
            return image
            #elseif canImport(UIKit)
            guard let image = thumbnail.cgImage else { throw CocoaError(.fileReadCorruptFile) }
            return image
            #else
            throw CocoaError(.featureUnsupported)
            #endif
        }
        guard page == 1 else { throw CocoaError(.fileReadInvalidFileName) }
        return try LocalPhotoInput.load(url,minimumSide:1)
    }

    static func export(_ asset: Asset, page: Int, crop: CGRect?) throws -> (data: Data, receipt: [String:Any]) {
        let hash = try ImageBatchRecord.hash(asset.url)
        var image = try raster(asset.url,page:page)
        if let crop {
            guard [crop.minX,crop.minY,crop.width,crop.height].allSatisfy(\.isFinite),
                  crop.minX >= 0,crop.minY >= 0,crop.width > 0,crop.height > 0,crop.maxX <= 1.000001,crop.maxY <= 1.000001 else { throw CocoaError(.fileReadInvalidFileName) }
            let pixels = CGRect(x:crop.minX*CGFloat(image.width),y:(1-crop.maxY)*CGFloat(image.height),
                                width:crop.width*CGFloat(image.width),height:crop.height*CGFloat(image.height)).integral
                .intersection(CGRect(x:0,y:0,width:image.width,height:image.height))
            guard let clipped = image.cropping(to:pixels) else { throw CocoaError(.fileReadCorruptFile) }
            image = clipped
        }
        let scale = min(1,1600/CGFloat(max(image.width,image.height)))
        if scale < 1 {
            guard let context = CGContext(data:nil,width:max(1,Int(CGFloat(image.width)*scale)),height:max(1,Int(CGFloat(image.height)*scale)),bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else { throw CocoaError(.fileReadUnknown) }
            context.interpolationQuality = .high
            context.draw(image,in:CGRect(x:0,y:0,width:context.width,height:context.height))
            guard let resized = context.makeImage() else { throw CocoaError(.fileReadUnknown) };image = resized
        }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes,UTType.jpeg.identifier as CFString,1,nil) else { throw CocoaError(.fileReadUnknown) }
        CGImageDestinationAddImage(destination,image,[kCGImageDestinationLossyCompressionQuality:0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination),bytes.length <= 10*1024*1024,
              try ImageBatchRecord.hash(asset.url) == hash else { throw CocoaError(.fileReadUnknown) }
        var receipt: [String:Any] = ["source":asset.url.path,"sourceSHA256":hash,"page":page,
            "width":image.width,"height":image.height,"status":"image_bytes_supplied; not proof of understanding or factual accuracy",
            "coordinateSystem":"normalized-bottom-left-on-oriented-raster",
            "versionCheck":"Compare sourceSHA256 with the extraction; mismatch means stale extracted evidence"]
        if let crop { receipt["crop"] = ["x":crop.minX,"y":crop.minY,"width":crop.width,"height":crop.height] }
        return (bytes as Data,receipt)
    }
}
