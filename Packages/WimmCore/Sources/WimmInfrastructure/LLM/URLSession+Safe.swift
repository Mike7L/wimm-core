import Foundation

extension URLSession {
    /// A safe alternative to `data(for:delegate:)` that avoids known crashes in the Foundation async wrapper
    /// by using the callback-based `dataTask` wrapped in a continuation.
    ///
    /// - Parameters:
    ///   - request: The URLRequest to perform.
    /// - Returns: A tuple containing the data and response.
    /// - Throws: Any error encountered during the request.
    public func dataSafe(for request: URLRequest) async throws -> (Data, URLResponse) {
        return try await withCheckedThrowingContinuation { continuation in
            let task = self.dataTask(with: request) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data = data, let response = response else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                continuation.resume(returning: (data, response))
            }
            task.resume()
        }
    }
}
