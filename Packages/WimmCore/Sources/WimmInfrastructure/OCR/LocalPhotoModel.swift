import Foundation
import WimmDomain
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#if os(macOS)
import Darwin
#endif

/// Offline MLX captioning, deliberately separate from literal OCR. Each process exits after
/// one image so this optional feature cannot leave a model resident beside live ASR.
public enum LocalPhotoModel {
    public static let identifier = "local/mlx-community/Qwen3.5-0.8B-4bit"
    public static let provider = "on-device"
    public static let maximumImageSide = 1024

    /// SwiftPM's generated accessor checks the app root, whereas a signed macOS
    /// app embeds resources under Contents/Resources. Prefer that shipped copy.
    static var workerURL: URL? { workerURL(in:.main) }
    static func workerURL(in bundle: Bundle) -> URL? {
        if let url = bundle.url(forResource:"WimmCore_WimmInfrastructure",withExtension:"bundle"),
           let resource = Bundle(url:url)?.url(forResource:"mlx_photo_worker",withExtension:"py") { return resource }
        return Bundle.module.url(forResource:"mlx_photo_worker",withExtension:"py")
    }

    public struct Caption: Codable, Sendable {
        public let caption: String
        public let seconds: Double
        public let peakMemoryGB: Double
        public let generationTokens: Int
        public let finishReason: String
        public let loadSeconds: Double?
        public let promptMode: String?
        public var promptVersion: String? = nil
        public var runtimeVersions: [String:String]? = nil
        public var modelConfigSHA256: String? = nil
        enum CodingKeys: String, CodingKey {
            case caption, seconds
            case loadSeconds = "load_seconds", promptMode = "prompt_mode"
            case peakMemoryGB = "peak_memory_gb", generationTokens = "generation_tokens", finishReason = "finish_reason"
            case promptVersion = "prompt_version", runtimeVersions = "runtime_versions", modelConfigSHA256 = "model_config_sha256"
        }
    }

    #if os(macOS)
    public static var pythonURL: URL {
        if let value = ProcessInfo.processInfo.environment["WIMM_MLX_VISION_PYTHON"] {
            return URL(fileURLWithPath: value)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/wimm/runtime/qwen35-vision/bin/python")
    }

    public static var modelURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/wimm/models/Qwen3.5-0.8B-4bit")
    }
    #endif

    public static var isReady: Bool {
        #if os(macOS) && arch(arm64)
        return FileManager.default.isExecutableFile(atPath: pythonURL.path)
            && ["config.json", "model.safetensors", "tokenizer.json", "preprocessor_config.json"].allSatisfy {
                FileManager.default.fileExists(atPath: modelURL.appendingPathComponent($0).path)
            }
        #else
        return false
        #endif
    }

    public static func describe(image: CGImage) async throws -> Caption {
        #if os(macOS) && arch(arm64)
        guard !StoragePaths.isTestProcess else { throw Failure.testProcess }
        guard isReady else { throw Failure.notInstalled }
        // Bound both visual token count and the temporary raster before starting Python.
        let bounded = try resized(image)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wimm-photo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.png")
        guard let destination = CGImageDestinationCreateWithURL(input as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.invalidImage
        }
        CGImageDestinationAddImage(destination, bounded, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.invalidImage }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.path)
        return try await LocalInferenceScheduler.shared.withPermit(priority: .background) {
            try await self.run(image: input, directory: directory)
        }
        #else
        throw Failure.unsupported
        #endif
    }

    /// Only a successful, bounded model response can become a persisted caption.
    static func decode(_ data: Data) throws -> Caption {
        guard data.count <= 16_384 else { throw Failure.invalidResponse }
        let result = try JSONDecoder().decode(Caption.self, from: data)
        guard result.finishReason == "stop", !result.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              result.caption.count <= 2000, result.seconds.isFinite, result.seconds >= 0,
              result.peakMemoryGB.isFinite, result.peakMemoryGB >= 0,
              (1...128).contains(result.generationTokens) else { throw Failure.invalidResponse }
        return result
    }

    static func resized(_ image: CGImage) throws -> CGImage {
        let scale = min(1, Double(maximumImageSide) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw Failure.invalidImage }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let output = context.makeImage() else { throw Failure.invalidImage }
        return output
    }

    #if os(macOS)
    private static func run(image: URL, directory: URL) async throws -> Caption {
        guard let worker = workerURL else { throw Failure.notInstalled }
        let output = directory.appendingPathComponent("response.json")
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = pythonURL
        process.arguments = [worker.path, "--model", modelURL.path, "--image", image.path]
        process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "TMPDIR": directory.path,
                               "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1",
                               "TOKENIZERS_PARALLELISM": "false", "PYTHONDONTWRITEBYTECODE": "1"]
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try Task.checkCancellation()
        try process.run()
        let deadline = Task.detached {
            do { try await Task.sleep(for: .seconds(90)) } catch { return }
            if process.isRunning { process.terminate() }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        defer { deadline.cancel() }
        try await withTaskCancellationHandler {
            await Task.detached { process.waitUntilExit() }.value
            try Task.checkCancellation()
        } onCancel: {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        guard process.terminationStatus == 0 else { throw Failure.inferenceFailed }
        guard let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16_384 else {
            throw Failure.invalidResponse
        }
        return try decode(Data(contentsOf: output))
    }
    #endif

    public enum Failure: LocalizedError {
        case notInstalled, unsupported, invalidImage, invalidResponse, inferenceFailed, testProcess
        public var errorDescription: String? {
            switch self {
            case .testProcess: return "Real photo models are disabled in test processes."
            case .notInstalled: return "Local photo model is not installed. Run scripts/setup_local_vision.sh."
            case .unsupported: return "Local MLX photos require an Apple Silicon Mac."
            case .invalidImage: return "Cannot prepare image for the local photo model."
            case .invalidResponse: return "Local photo model returned an incomplete or invalid caption."
            case .inferenceFailed: return "Local photo inference failed or exceeded 90 seconds."
            }
        }
    }
}

/// Vision preserves literal text; Qwen adds a short, explicitly labelled draft caption.
/// Dense documents skip the VLM. Failed captions fail this engine rather than silently
/// changing providers or sending an image to a cloud service.
public struct LocalPhotoOCRProvider: OCRProvider {
    public init() {}
    public struct Extraction: Sendable {
        public let text: String
        public let ocrText: String
        public let caption: LocalPhotoModel.Caption?
        public let isDenseDocument: Bool
        public let vision: VisionImageAnalysis
    }
    public func performOCR(on image: CGImage) async throws -> String {
        try await extract(image: image).text
    }
    public func extract(image: CGImage, forceCaption: Bool = false) async throws -> Extraction {
        let document = try await VisionDocumentAndSceneExtractor.analyze(image: image)
        if document.isDenseDocument && !forceCaption {
            return Extraction(text: document.text, ocrText: document.ocrText, caption: nil, isDenseDocument: true, vision: document)
        }
        let result = try await LocalPhotoModel.describe(image: image)
        return Extraction(text: Self.combine(caption: result.caption, text: document.text),
                          ocrText: document.ocrText, caption: result, isDenseDocument: document.isDenseDocument, vision: document)
    }
    public static func combine(caption: String, text: String) -> String {
        let description = "[image description (local MLX, draft): \(caption)]"
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? description : description + "\n\n" + text
    }
}
