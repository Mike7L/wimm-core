import Foundation
import WimmDomain
#if canImport(AVFoundation)
@preconcurrency import AVFoundation
import AudioToolbox
#endif

/// Адаптер для транскрипции аудио через Google Gemini API (batch, inline_data).
/// Предпочитает _mini.m4a (16 kHz/24 kbps) рядом с оригиналом — если есть, используем его.
public struct GeminiTranscriptionAdapter: FileTranscriptionPort {
    private let apiKey: String
    private let modelName: String
    private let session: URLSession

    // MARK: - Request/Response types

    private struct GenerateRequest: Encodable {
        struct Content: Encodable {
            struct Part: Encodable {
                var text: String? = nil
                var inline_data: InlineData? = nil
                var file_data: FileData? = nil
            }
            struct InlineData: Encodable {
                let mime_type: String
                let data: String
            }
            struct FileData: Encodable {
                let mime_type: String
                let file_uri: String
            }
            let parts: [Part]
        }
        let contents: [Content]
    }

    private struct UploadedFile: Decodable {
        let name: String
        let uri: String
        let mimeType: String
        let state: String?
    }

    private struct UploadResponse: Decodable {
        let file: UploadedFile
    }

    // MARK: - Constants

    // Single source of truth: the shared transcription prompt (incl. the
    // [[NO_SPEECH]] sentinel) lives in transcription_standard_prompt.txt, loaded
    // via PromptLoader so a prompt edit propagates to every transcription path.
    private static var transcribePrompt: String {
        PromptLoader.load("transcription_standard_prompt", variables: ["lang_hint": ""])
    }

    /// Shared session re-used across ad-hoc adapter instances (e.g. GeminiLiveTranscriptionAdapter).
    /// Callers that need testability should inject their own session via init.
    public static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 1_800
        return URLSession(configuration: config)
    }()

    // MARK: - Init

    public init(
        apiKey: String,
        modelName: String = DefaultModels.gemini,
        session: URLSession = GeminiTranscriptionAdapter.defaultSession
    ) {
        self.apiKey = apiKey
        self.modelName = modelName
        self.session = session
    }

    // MARK: - FileTranscriptionPort

    public func transcribeFile(at fileURL: URL) async throws -> String {
        try PrivateMode.refuseCloudAudio(provider: "gemini")
        // Direct adapter callers may pass an original recording, while the app-level
        // transcription service passes an already prepared _micro tier. Never
        // derive from the latter: doing so creates redundant _micro_mini files.
        let uploadURL = await Self.preparedUploadURL(for: fileURL)
        let fileData = try Data(contentsOf: uploadURL)
        let audioSeconds = await Self.audioDurationSeconds(of: uploadURL)
        // A freshly encoded copy lands in the temp dir and is throwaway once read;
        // a reused _micro sidecar or the input itself must survive.
        let tmpDir = FileManager.default.temporaryDirectory.standardizedFileURL.path
        if uploadURL != fileURL, uploadURL.standardizedFileURL.path.hasPrefix(tmpDir) {
            try? FileManager.default.removeItem(at: uploadURL)
        }
        let mimeType = Self.mimeType(for: uploadURL)
        let usesFilesAPI = fileData.count > TranscriptionCfg.inlineDataMaxBytes

        // Cost accounting: this path talks to the API directly, so it has to open
        // and close its own log pair — nothing upstream does it. Audio is the most
        // expensive modality in the product, so an unlogged call here is the
        // biggest possible blind spot.
        let cost = TranscriptionCostLog(
            model: modelName,
            noteFile: fileURL.lastPathComponent,
            audioSeconds: audioSeconds,
            uploadBytes: fileData.count,
            uploadMode: usesFilesAPI ? "files_api" : "inline",
            prompt: Self.transcribePrompt
        )

        do {
            let result: (text: String, usage: TokenUsage?)
            if usesFilesAPI {
                let uploaded = try await uploadFile(
                    data: fileData,
                    fileName: uploadURL.lastPathComponent,
                    mimeType: mimeType
                )
                do {
                    result = try await generateContent(parts: [
                        .init(text: Self.transcribePrompt),
                        .init(file_data: .init(mime_type: uploaded.mimeType, file_uri: uploaded.uri)),
                    ])
                    await deleteUploadedFile(named: uploaded.name)
                } catch {
                    await deleteUploadedFile(named: uploaded.name)
                    throw error
                }
            } else {
                result = try await generateContent(parts: [
                    .init(text: Self.transcribePrompt),
                    .init(inline_data: .init(mime_type: mimeType, data: fileData.base64EncodedString())),
                ])
            }
            cost.finish(text: result.text, usage: result.usage)
            return result.text
        } catch {
            cost.fail(error)
            throw error
        }
    }

    private func generateContent(
        parts: [GenerateRequest.Content.Part]
    ) async throws -> (text: String, usage: TokenUsage?) {
        guard let url = URL(string:
            "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):generateContent?key=\(apiKey)")
        else { throw adapterError(code: -1, message: "Invalid API URL") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = GenerateRequest(contents: [.init(parts: parts)])
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data, operation: "generateContent")

        // Audio lands in usageMetadata.promptTokensDetails, which is the whole
        // point of decoding the shared envelope here rather than just the text.
        let geminiResponse = try JSONDecoder().decode(GeminiResponse.self, from: data)
        let text = geminiResponse.firstCandidateText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw NSError(
                domain: ErrorDomain.noText,
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Gemini returned an empty transcription"]
            )
        }
        return (text, geminiResponse.usageMetadata?.tokenUsage)
    }

    private func uploadFile(data: Data, fileName: String, mimeType: String) async throws -> UploadedFile {
        guard let startURL = URL(string: "https://generativelanguage.googleapis.com/upload/v1beta/files") else {
            throw adapterError(code: -1, message: "Invalid Files API URL")
        }

        var start = URLRequest(url: startURL)
        start.httpMethod = "POST"
        start.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue(String(data.count), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        start.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        start.httpBody = try JSONSerialization.data(withJSONObject: ["file": ["display_name": fileName]])

        let (startData, startResponse) = try await session.data(for: start)
        try validate(response: startResponse, data: startData, operation: "Files API start")
        guard let http = startResponse as? HTTPURLResponse,
              let uploadURLString = http.value(forHTTPHeaderField: "X-Goog-Upload-URL"),
              let uploadURL = URL(string: uploadURLString)
        else { throw adapterError(code: -2, message: "Files API did not return an upload URL") }

        var upload = URLRequest(url: uploadURL)
        upload.httpMethod = "POST"
        upload.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        upload.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        upload.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        upload.httpBody = data

        let (uploadData, uploadResponse) = try await session.data(for: upload)
        try validate(response: uploadResponse, data: uploadData, operation: "Files API upload")
        let uploaded = try JSONDecoder().decode(UploadResponse.self, from: uploadData).file
        return try await waitUntilActive(uploaded)
    }

    private func waitUntilActive(_ uploaded: UploadedFile) async throws -> UploadedFile {
        var file = uploaded
        for _ in 0..<120 {
            switch file.state?.uppercased() {
            case nil, "ACTIVE": return file
            case "FAILED": throw adapterError(code: -3, message: "Gemini failed to process uploaded audio")
            default: break
            }
            try await Task.sleep(for: .milliseconds(500))
            guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/\(file.name)") else {
                throw adapterError(code: -1, message: "Invalid uploaded-file URL")
            }
            var request = URLRequest(url: url)
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            let (data, response) = try await session.data(for: request)
            try validate(response: response, data: data, operation: "Files API status")
            file = try JSONDecoder().decode(UploadedFile.self, from: data)
        }
        throw adapterError(code: -4, message: "Timed out waiting for Gemini to process uploaded audio")
    }

    private func deleteUploadedFile(named name: String) async {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/\(name)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        _ = try? await session.data(for: request)
    }

    private func validate(response: URLResponse, data: Data, operation: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw adapterError(code: -5, message: "\(operation) returned a non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown"
            throw adapterError(code: http.statusCode, message: "\(operation) error: \(body)")
        }
    }

    private func adapterError(code: Int, message: String) -> NSError {
        NSError(domain: "GeminiTranscriptionAdapter", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - Helpers

    /// Returns the file to upload: derived files (a legacy `_micro`, or the app
    /// layer's throwaway `MicroAudio` copy) pass through untouched; an original is
    /// downsampled (16 kHz, mono, 12 kbps AAC) into a THROWAWAY temp file — never a
    /// persistent sidecar. Falls back to the original URL if encoding is unavailable
    /// or fails.
    static func preparedUploadURL(for fileURL: URL) async -> URL {
        if FileStore.isDerivedAudioFile(fileURL) { return fileURL }
#if canImport(AVFoundation)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        do { return try await reencodeToMini(source: fileURL, destination: tmp) } catch {}
#endif
        return fileURL
    }

#if canImport(AVFoundation)
    /// Re-encodes audio to 16 kHz, mono, 12 kbps AAC and writes to `destination`.
    private static func reencodeToMini(source: URL, destination: URL) async throws -> URL {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return source }

        let pcmSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let aacSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 12_000,
        ]

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: pcmSettings)
        reader.add(readerOutput)

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".m4a")
        let writer = try AVAssetWriter(outputURL: tmpURL, fileType: .m4a)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
        writer.add(writerInput)

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            throw NSError(domain: "GeminiTranscriptionAdapter", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "AVAssetReader failed to start"])
        }

        let encoding = MiniEncoding(reader: reader, output: readerOutput, writer: writer, input: writerInput)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "wimm.mini.encode")
            encoding.input.requestMediaDataWhenReady(on: queue) {
                while encoding.input.isReadyForMoreMediaData {
                    if let sample = encoding.output.copyNextSampleBuffer() {
                        encoding.input.append(sample)
                    } else {
                        encoding.input.markAsFinished()
                        encoding.writer.finishWriting {
                            if let err = encoding.writer.error { cont.resume(throwing: err) }
                            else { cont.resume() }
                        }
                        return
                    }
                }
            }
        }

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tmpURL, to: destination)
        return destination
    }

    // After setup, only the serial encoding queue uses these objects.
    // The completion reads writer.error after the writer finishes.
    private struct MiniEncoding: @unchecked Sendable {
        let reader: AVAssetReader // Keeps the reader alive through completion.
        let output: AVAssetReaderTrackOutput
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
    }
#endif

    /// Duration of what is actually uploaded — the denominator for "$ per minute
    /// of speech". Best-effort: an unreadable asset just means the cost record
    /// carries tokens without a rate.
    static func audioDurationSeconds(of fileURL: URL) async -> Double? {
#if canImport(AVFoundation)
        let asset = AVURLAsset(url: fileURL)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : nil
#else
        return nil
#endif
    }

    private static func mimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "m4a":  return "audio/mp4"
        case "aac":  return "audio/aac"
        case "mp3":  return "audio/mp3"
        case "wav":  return "audio/wav"
        case "flac": return "audio/flac"
        default:     return "audio/mp4"
        }
    }
}
