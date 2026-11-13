import AppKit
import CryptoKit
import Foundation
import ImageIO
import Observation
import Photos
import UniformTypeIdentifiers
import WimmDomain
import WimmInfrastructure

/// Photos for the evening: today's shots from the Photos library (PhotoKit)
/// and pictures dropped from Finder. A photo put on the day becomes an
/// ordinary image note named by the time it was taken, not the time it was
/// added — the deliberate opposite of the iPhone share import, where adding
/// means "keep this" rather than "this happened then".
@MainActor @Observable
final class EveningPhotos {
    struct Candidate: Identifiable {
        let asset: PHAsset
        var id: String { asset.localIdentifier }
        var date: Date { asset.creationDate ?? .distantPast }
        var thumbnail: NSImage?
        var isAdded: Bool
    }

    enum Access: Equatable { case unknown, granted, denied }

    private(set) var access: Access = .unknown
    private(set) var candidates: [Candidate] = []
    private(set) var importing: Set<String> = []
    var errorMessage: String?

    @ObservationIgnored private let images = PHCachingImageManager()

    // MARK: - Library strip

    func load(day: Date) async {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard status == .authorized || status == .limited else { access = .denied; candidates = []; return }
        access = .granted
        let interval = EveningJournal.interval(for: day)
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@ AND mediaType == %d",
                                        interval.start as NSDate, interval.end as NSDate, PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        // One representative per burst is PhotoKit's default.
        let result = PHAsset.fetchAssets(with: options)
        let added = Self.addedAssetIDs(day: day)
        var list: [Candidate] = []
        result.enumerateObjects { asset, _, _ in
            guard !asset.mediaSubtypes.contains(.photoScreenshot) else { return }
            list.append(Candidate(asset: asset, thumbnail: nil, isAdded: added.contains(asset.localIdentifier)))
        }
        candidates = list
        for asset in list.map(\.asset) { requestThumbnail(asset) }
    }

    private func requestThumbnail(_ asset: PHAsset) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        images.requestImage(for: asset, targetSize: CGSize(width: 160, height: 160),
                            contentMode: .aspectFill, options: options) { [weak self] image, _ in
            let id = asset.localIdentifier
            Task { @MainActor in
                guard let self, let image, let index = self.candidates.firstIndex(where: { $0.id == id }) else { return }
                self.candidates[index].thumbnail = image
            }
        }
    }

    /// Copies the original out of the Photos library (downloading it from iCloud if needed).
    func add(_ candidate: Candidate, caption: String = "") async -> URL? {
        guard !candidate.isAdded, !importing.contains(candidate.id) else { return nil }
        importing.insert(candidate.id)
        defer { importing.remove(candidate.id) }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        options.deliveryMode = .highQualityFormat
        let asset = candidate.asset
        let loaded: (Data, String)? = await withCheckedContinuation { continuation in
            images.requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, _ in
                continuation.resume(returning: data.map { ($0, uti ?? UTType.jpeg.identifier) })
            }
        }
        guard let (data, uti) = loaded else { errorMessage = "Не удалось получить фото из библиотеки."; return nil }
        let ext = UTType(uti)?.preferredFilenameExtension ?? "jpg"
        do {
            let url = try Self.writeNote(data: data, extension: ext, date: candidate.date, caption: caption,
                                         origin: ["source": "studio-evening-photo", "assetId": candidate.id])
            if let index = candidates.firstIndex(where: { $0.id == candidate.id }) { candidates[index].isAdded = true }
            return url
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - Dropped files

    /// A file dropped on the day. Its own EXIF time wins; without one, the time it was dropped at.
    func addFile(_ source: URL, fallbackDate: Date) -> URL? {
        guard let data = try? Data(contentsOf: source) else { errorMessage = "Не удалось прочитать \(source.lastPathComponent)."; return nil }
        let date = Self.captureDate(of: source) ?? fallbackDate
        do {
            return try Self.writeNote(data: data, extension: source.pathExtension.lowercased(), date: date, caption: "",
                                      origin: ["source": "studio-evening-photo", "file": source.lastPathComponent])
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - Notes

    enum Failure: LocalizedError {
        case duplicate
        var errorDescription: String? { "Это фото уже добавлено." }
    }

    /// One image note: file named by the capture time, sidecar with origin and
    /// content hash, then on-device OCR in the background.
    static func writeNote(data: Data, extension ext: String, date: Date, caption: String,
                          origin: [String: Any]) throws -> URL {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let day = EveningJournal.day(containing: date)
        guard !addedHashes(day: day).contains(hash) else { throw Failure.duplicate }
        try FileStore.ensureDirectoryExists()
        try FileManager.default.createDirectory(at: FileStore.recordingsDirectory(), withIntermediateDirectories: true)
        let identity = RecordingIdentity(createdAt: date)
        let url = FileStore.newRecordingURL(identity: identity, extension: ext.isEmpty ? "jpg" : ext)
        try data.write(to: url, options: .atomic)
        identity.persist(for: url)
        var origin = origin
        origin["sha256"] = hash
        origin["addedAt"] = ISO8601.string(from: Date())
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        FileStore.upsertMetadata(for: url, updates: ["title": trimmed.isEmpty ? "Фото" : trimmed, "origin": origin])
        Task.detached(priority: .utility) { await recognizeText(in: url) }
        return url
    }

    /// Vision OCR on the device, saved the way a standalone document's OCR is.
    nonisolated static func recognizeText(in url: URL) async {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        let started = Date()
        guard let text = try? await VisionOCRProvider().performOCR(on: image),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await AttachmentRepository(metadataRepository: MetadataRepository()).saveDocumentOCR(
            for: url, text: text, provider: TextExtractionProvider.vision, model: "VNRecognizeText", startedAt: started)
    }

    /// `DateTimeOriginal` with `OffsetTimeOriginal` when present (iPhone writes it), else local time.
    nonisolated static func captureDate(of url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let stamp = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        return exifDate(stamp, offset: exif[kCGImagePropertyExifOffsetTimeOriginal] as? String)
    }

    nonisolated static func exifDate(_ stamp: String, offset: String?) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let offset, !offset.isEmpty {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXX"
            if let date = formatter.date(from: stamp + offset) { return date }
        }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter.date(from: stamp)
    }

    // MARK: - Already added

    /// Origins of the day's evening photos. Only image notes stamped inside the evening are read.
    private static func addedOrigins(day: Date) -> [[String: Any]] {
        let interval = EveningJournal.interval(for: day)
        let directory = FileStore.recordingsDirectory()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> [String: Any]? in
            guard name.hasPrefix("Wimm_"), !name.contains("_Attach_"), !name.hasSuffix(".json") else { return nil }
            let url = directory.appendingPathComponent(name)
            guard AttachmentType(fromExtension: url.pathExtension) == .image,
                  let date = FileStore.recordingDateFromFileName(url), interval.contains(date),
                  let data = try? Data(contentsOf: FileStore.metadataURL(forRecordingURL: url)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let origin = json["origin"] as? [String: Any],
                  origin["source"] as? String == "studio-evening-photo" else { return nil }
            return origin
        }
    }

    private static func addedAssetIDs(day: Date) -> Set<String> {
        Set(addedOrigins(day: day).compactMap { $0["assetId"] as? String })
    }

    private static func addedHashes(day: Date) -> Set<String> {
        Set(addedOrigins(day: day).compactMap { $0["sha256"] as? String })
    }
}
