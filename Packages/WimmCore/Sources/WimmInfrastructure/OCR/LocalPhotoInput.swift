import Foundation
import CoreGraphics
import ImageIO

public enum LocalPhotoInput {
    /// Apply EXIF orientation while decoding; OCR keeps more pixels than the caption model.
    public static func load(_ url: URL, maximumSide: Int = 4096, minimumSide: Int = 8) throws -> CGImage {
        guard url.isFileURL, maximumSide > 0, minimumSide > 0,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumSide
              ] as CFDictionary), image.width >= minimumSide, image.height >= minimumSide else {
            throw LocalPhotoModel.Failure.invalidImage
        }
        return image
    }
}
