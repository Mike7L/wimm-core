import Foundation

public protocol GeminiLiveTransport: Sendable {
    func connect(request: URLRequest) async throws -> AsyncThrowingStream<Data, Error>
    func send(_ data: Data) async throws
    func close()
}

public struct RecordedGeminiLiveMessage: Sendable {
    public let payload: Data
    public let delayNanoseconds: UInt64

    public init(payload: Data, delayNanoseconds: UInt64 = 0) {
        self.payload = payload
        self.delayNanoseconds = delayNanoseconds
    }
}

public final class URLSessionGeminiLiveTransport: @unchecked Sendable {
    private let session: URLSession
    private let stateQueue = DispatchQueue(label: "wimm.gemini-live.transport.state")
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?

    public init(session: URLSession = URLSession(configuration: .default)) {
        self.session = session
    }
}

extension URLSessionGeminiLiveTransport: GeminiLiveTransport {
    public func connect(request: URLRequest) async throws -> AsyncThrowingStream<Data, Error> {
        let socket = session.webSocketTask(with: request)
        socket.resume()

        return AsyncThrowingStream { continuation in
            stateQueue.sync {
                self.socket = socket
                self.continuation = continuation
            }
            self.receiveTask = Task { [weak self] in
                await self?.receiveLoop()
            }
        }
    }

    public func send(_ data: Data) async throws {
        guard let socket = stateQueue.sync(execute: { self.socket }) else {
            throw NSError(
                domain: "URLSessionGeminiLiveTransport",
                code: 2101,
                userInfo: [NSLocalizedDescriptionKey: "Gemini Live socket is not connected"]
            )
        }
        try await socket.send(.data(data))
    }

    public func close() {
        stateQueue.sync {
            self.receiveTask?.cancel()
            self.receiveTask = nil
            self.continuation?.finish()
            self.continuation = nil
            self.socket?.cancel(with: .goingAway, reason: nil)
            self.socket = nil
        }
    }

    private func receiveLoop() async {
        while let socket = stateQueue.sync(execute: { self.socket }) {
            do {
                let message = try await socket.receive()
                switch message {
                case .data(let data):
                    _ = stateQueue.sync { self.continuation?.yield(data) }
                case .string(let string):
                    _ = stateQueue.sync { self.continuation?.yield(Data(string.utf8)) }
                @unknown default:
                    break
                }
            } catch {
                stateQueue.sync {
                    self.continuation?.finish(throwing: error)
                    self.continuation = nil
                    self.socket = nil
                    self.receiveTask = nil
                }
                break
            }
        }
    }
}

public final class RecordedGeminiLiveTransport: @unchecked Sendable {
    private let messages: [RecordedGeminiLiveMessage]
    private let stateQueue = DispatchQueue(label: "wimm.gemini-live.recorded-transport.state")
    private var producerTask: Task<Void, Never>?
    private var sentPayloads: [Data] = []

    public init(messages: [RecordedGeminiLiveMessage]) {
        self.messages = messages
    }

    public convenience init(jsonObjects: [[String: Any]]) throws {
        let messages = try jsonObjects.map { object in
            let data = try JSONSerialization.data(withJSONObject: object, options: [])
            return RecordedGeminiLiveMessage(payload: data)
        }
        self.init(messages: messages)
    }

    public convenience init(fileURL: URL) throws {
        let data = try Data(contentsOf: fileURL)
        let json = try JSONSerialization.jsonObject(with: data)

        if let objects = json as? [[String: Any]] {
            let messages = try objects.map { object -> RecordedGeminiLiveMessage in
                if let payload = object["payload"] as? [String: Any] {
                    let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [])
                    let delayMs = (object["delayMs"] as? NSNumber)?.uint64Value ?? 0
                    return RecordedGeminiLiveMessage(payload: payloadData, delayNanoseconds: delayMs * 1_000_000)
                }
                let payloadData = try JSONSerialization.data(withJSONObject: object, options: [])
                return RecordedGeminiLiveMessage(payload: payloadData)
            }
            self.init(messages: messages)
            return
        }

        throw NSError(
            domain: "RecordedGeminiLiveTransport",
            code: 2102,
            userInfo: [NSLocalizedDescriptionKey: "Unsupported recorded Gemini Live scenario format"]
        )
    }

    public var sentPayloadsSnapshot: [Data] {
        stateQueue.sync { sentPayloads }
    }
}

extension RecordedGeminiLiveTransport: GeminiLiveTransport {
    public func connect(request _: URLRequest) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            producerTask?.cancel()
            producerTask = Task {
                do {
                    for message in messages {
                        if Task.isCancelled { break }
                        if message.delayNanoseconds > 0 {
                            try await Task.sleep(nanoseconds: message.delayNanoseconds)
                        }
                        continuation.yield(message.payload)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func send(_ data: Data) async throws {
        stateQueue.sync {
            sentPayloads.append(data)
        }
    }

    public func close() {
        producerTask?.cancel()
        producerTask = nil
    }
}
