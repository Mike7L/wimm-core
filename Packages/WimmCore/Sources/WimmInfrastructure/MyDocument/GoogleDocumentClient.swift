import Foundation

public enum MyDocumentError: LocalizedError {
    case invalidDocument, missingAuthorization, invalidResponse, requestFailed(Int), emptyResult
    public var errorDescription: String? {
        switch self {
        case .invalidDocument: return NSLocalizedString("myDocument.error.invalidDocument", value: "Enter a Google Docs document URL.", comment: "")
        case .missingAuthorization: return NSLocalizedString("myDocument.error.authorization", value: "Connect your Google account again.", comment: "")
        case .invalidResponse: return NSLocalizedString("myDocument.error.response", value: "Google returned an unreadable response.", comment: "")
        case .requestFailed(let code): return String(format: NSLocalizedString("myDocument.error.request", value: "Google request failed (%ld). Retry or reconnect your account.", comment: ""), code)
        case .emptyResult: return NSLocalizedString("myDocument.error.emptyResult", value: "The local model returned no text. The source remains in the queue.", comment: "")
        }
    }
}

/// Appends only; never replaces the user's document. A durable entry marker lets
/// the caller reconcile a lost response before retrying an ambiguous write.
public struct GoogleDocumentClient: Sendable {
    private let send: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    public init(session: URLSession = .shared) { send = { try await session.data(for: $0) } }
    init(send: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) { self.send = send }

    public static func documentID(from raw: String) throws -> String {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host == "docs.google.com" else {
            throw MyDocumentError.invalidDocument
        }
        let parts = url.pathComponents
        guard let d = parts.firstIndex(of: "d"), d > 0, parts[d - 1] == "document",
              parts.count > d + 1 else { throw MyDocumentError.invalidDocument }
        let id = parts[d + 1]
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw MyDocumentError.invalidDocument
        }
        return id
    }

    public func append(documentID: String, text: String, marker: String, accessToken: String) async throws {
        // Get all tabs so a receipt moved by the user still prevents a duplicate.
        let url = URL(string: "https://docs.googleapis.com/v1/documents/\(documentID)?includeTabsContent=true")!
        let data = try await request(url: url, accessToken: accessToken)
        guard let doc = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let revision = doc["revisionId"] as? String else { throw MyDocumentError.invalidResponse }
        let content = Self.textContent(doc)
        if content.contains(marker) { return }
        if marker.hasPrefix("[WIMM: ") {
            let legacyPrefix = "[Mem" + "ario: "
            let legacyMarker = legacyPrefix + marker.dropFirst("[WIMM: ".count)
            if content.contains(legacyMarker) { return }
        }
        guard let first = (doc["tabs"] as? [[String: Any]])?.first,
              let properties = first["tabProperties"] as? [String: Any],
              let tabID = properties["tabId"] as? String else { throw MyDocumentError.invalidResponse }
        let body: [String: Any] = [
            "writeControl": ["requiredRevisionId": revision],
            "requests": [["insertText": [
                "endOfSegmentLocation": ["tabId": tabID],
                "text": "\n\(text)\n\(marker)\n"
            ]]]
        ]
        // A concurrent edit rejects this request. The next attempt rereads the
        // revision and checks the marker; it never blindly repeats a POST.
        _ = try await request(
            url: URL(string: "https://docs.googleapis.com/v1/documents/\(documentID):batchUpdate")!,
            accessToken: accessToken, body: JSONSerialization.data(withJSONObject: body)
        )
    }

    private static func textContent(_ value: Any) -> String {
        if let dict = value as? [String: Any] {
            if let run = dict["textRun"] as? [String: Any], let content = run["content"] as? String { return content }
            return dict.values.map(textContent).joined()
        }
        if let array = value as? [Any] { return array.map(textContent).joined() }
        return ""
    }

    private func request(url: URL, accessToken: String, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 45
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await send(request)
        guard let response = response as? HTTPURLResponse else { throw MyDocumentError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw MyDocumentError.requestFailed(response.statusCode) }
        return data
    }
}
