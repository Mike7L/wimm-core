import Foundation

public struct GeminiModel: Identifiable, Decodable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let displayName: String
    public let modelDescription: String?
    public let supportedGenerationMethods: [String]

    private enum CodingKeys: String, CodingKey {
        case name
        case displayName
        case description
        case supportedGenerationMethods
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        id = name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? id
        modelDescription = try container.decodeIfPresent(String.self, forKey: .description)
        supportedGenerationMethods = try container.decodeIfPresent(
            [String].self,
            forKey: .supportedGenerationMethods
        ) ?? []
    }
}

private struct GeminiModelsEnvelope: Decodable {
    let models: [GeminiModel]
    let nextPageToken: String?
}

/// Fetches the model catalog visible to the user's current Gemini API key.
public actor GeminiModelsAPI {
    public static let shared = GeminiModelsAPI()

    private var cached: [GeminiModel] = []
    private var cachedForKey: String?
    private var lastFetch: Date?
    private let ttl: TimeInterval = 10 * 60

    public static func fetch(forceReload: Bool = false) async throws -> [GeminiModel] {
        try await shared.fetchInternal(forceReload: forceReload)
    }

    private func fetchInternal(forceReload: Bool) async throws -> [GeminiModel] {
        let key = await APIKeyRotator.shared.currentKey()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw NSError(
                domain: "GeminiModelsAPI",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Gemini API key is not configured"]
            )
        }

        if !forceReload,
           cachedForKey == key,
           let lastFetch,
           Date().timeIntervalSince(lastFetch) < ttl,
           !cached.isEmpty
        {
            return cached
        }

        var allModels: [GeminiModel] = []
        var pageToken: String?

        repeat {
            var components = URLComponents(
                string: "https://generativelanguage.googleapis.com/v1beta/models"
            )!
            var queryItems = [
                URLQueryItem(name: "key", value: key),
                URLQueryItem(name: "pageSize", value: "1000"),
            ]
            if let pageToken, !pageToken.isEmpty {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            components.queryItems = queryItems

            var request = URLRequest(url: components.url!)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                throw NSError(
                    domain: ErrorDomain.badStatus,
                    code: code,
                    userInfo: [NSLocalizedDescriptionKey: body]
                )
            }

            let envelope = try JSONDecoder().decode(GeminiModelsEnvelope.self, from: data)
            allModels.append(contentsOf: envelope.models)
            pageToken = envelope.nextPageToken
        } while pageToken?.isEmpty == false

        let available = allModels
            .filter { model in
                model.id.hasPrefix("gemini-")
                    && model.supportedGenerationMethods.contains("generateContent")
            }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedDescending }

        cached = available
        cachedForKey = key
        lastFetch = Date()
        return available
    }
}
