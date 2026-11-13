import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import WimmDomain
#if os(macOS)
import Darwin
#endif

/// Explicit bulk mode: one model for at most 32 images, then the child exits.
/// Normal app calls still release the model after every photo.
public enum LocalPhotoBatch {
    public struct Item: Sendable {
        public let id: String
        public let image: URL
        public init(id: String, image: URL) { self.id = id; self.image = image }
    }
    public static func describe(_ items: [Item],
        receive: @escaping @Sendable (String, LocalPhotoModel.Caption?, String?) async throws -> Void) async throws {
        #if os(macOS) && arch(arm64)
        guard !StoragePaths.isTestProcess else { throw LocalPhotoModel.Failure.testProcess }
        guard (1...32).contains(items.count), Set(items.map(\.id)).count == items.count,
              LocalPhotoModel.isReady else { throw LocalPhotoModel.Failure.notInstalled }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wimm-photo-batch-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:folder) }
        var inputs: [[String:String]] = []
        for (index,item) in items.enumerated() {
            let image = try LocalPhotoModel.resized(LocalPhotoInput.load(item.image,maximumSide:1024))
            let file = folder.appendingPathComponent("input_\(index).png")
            guard let destination = CGImageDestinationCreateWithURL(file as CFURL,UTType.png.identifier as CFString,1,nil) else { throw LocalPhotoModel.Failure.invalidImage }
            CGImageDestinationAddImage(destination,image,nil)
            guard CGImageDestinationFinalize(destination) else { throw LocalPhotoModel.Failure.invalidImage }
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
            inputs.append(["id":item.id,"image":file.path])
        }
        let manifest = folder.appendingPathComponent("requests.json")
        try JSONSerialization.data(withJSONObject:inputs).write(to:manifest)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:manifest.path)
        try await LocalInferenceScheduler.shared.withPermit(priority:.background) {
            guard let worker = LocalPhotoModel.workerURL else { throw LocalPhotoModel.Failure.notInstalled }
            let child = Process(), output = Pipe()
            child.executableURL = LocalPhotoModel.pythonURL
            child.arguments = [worker.path,"--model",LocalPhotoModel.modelURL.path,"--batch-manifest",manifest.path]
            child.environment = ["HOME":NSHomeDirectory(),"PATH":"/usr/bin:/bin","TMPDIR":folder.path,
                "HF_HUB_OFFLINE":"1","TRANSFORMERS_OFFLINE":"1","TOKENIZERS_PARALLELISM":"false","PYTHONDONTWRITEBYTECODE":"1"]
            child.standardOutput = output; child.standardError = FileHandle.nullDevice; child.standardInput = FileHandle.nullDevice
            try Task.checkCancellation(); try child.run()
            // Only the child owns the writer. Keeping the parent's copy open can
            // leave AsyncBytes waiting forever after the worker has exited.
            try output.fileHandleForWriting.close()
            let deadline = Task.detached {
                do { try await Task.sleep(for:.seconds(90 * items.count)) } catch { return }
                if child.isRunning { kill(child.processIdentifier,SIGKILL) }
            }
            defer { deadline.cancel(); if child.isRunning { child.terminate() } }
            var pending = Set(items.map(\.id))
            try await withTaskCancellationHandler {
                for try await line in output.fileHandleForReading.bytes.lines {
                    guard line.utf8.count <= 16_384,
                          let data = line.data(using:.utf8),
                          let value = try JSONSerialization.jsonObject(with:data) as? [String:Any],
                          let id = value["id"] as? String, pending.remove(id) != nil else { throw LocalPhotoModel.Failure.invalidResponse }
                    if let result = value["result"] as? [String:Any] {
                        let caption = try LocalPhotoModel.decode(JSONSerialization.data(withJSONObject:result))
                        try await receive(id,caption,nil)
                    } else { try await receive(id,nil,"Local caption rejected: " + (value["error"] as? String ?? "unknown")) }
                    if pending.isEmpty { break }
                }
                await Task.detached { child.waitUntilExit() }.value
                try Task.checkCancellation()
            } onCancel: { if child.isRunning { kill(child.processIdentifier,SIGKILL) } }
            guard child.terminationStatus == 0, pending.isEmpty else { throw LocalPhotoModel.Failure.inferenceFailed }
        }
        #else
        throw LocalPhotoModel.Failure.unsupported
        #endif
    }
}
