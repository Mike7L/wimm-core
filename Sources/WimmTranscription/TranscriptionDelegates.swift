import Foundation

// MARK: - Transcription Delegates and Helpers

/// Handles progress calculation and smoothing for uploads
public actor ProgressCoordinator {
    private var postUploadTicker: Task<Void, Never>?
    private let onProgress: ((Double, Double?, TimeInterval) -> Void)?
    private let t0 = Date()
    private let totalEstimate: Double
    private let uploadWeight: Double = 0.65
    private let durationSeconds: Double
    
    public init(totalEstimate: Double, durationSeconds: Double, onProgress: ((Double, Double?, TimeInterval) -> Void)?) {
        self.totalEstimate = totalEstimate
        self.durationSeconds = durationSeconds
        self.onProgress = onProgress
    }
    
    public func update(sent: Int64, total: Int64) {
        guard total > 0 else { return }
        let uploadPct = min(1.0, max(0.0, Double(sent) / Double(total)))
        let elapsed = Date().timeIntervalSince(t0)
        let pct = min(0.95, uploadPct * uploadWeight)
        let eta = totalEstimate - elapsed
        onProgress?(pct, eta.isFinite ? max(0, eta) : nil, elapsed)
        
        if uploadPct >= 1.0 && postUploadTicker == nil {
            startTicker()
        }
    }
    
    private func startTicker() {
        postUploadTicker = Task {
            while !Task.isCancelled {
                let elapsed2 = Date().timeIntervalSince(t0)
                let sinceUpload = max(0, elapsed2)
                let procEst = max(2.0, durationSeconds * 0.6 + 2.0)
                let procPct = min(1.0, sinceUpload / procEst)
                let pct2 = min(0.95, uploadWeight + (1.0 - uploadWeight) * procPct * 0.9)
                let eta2 = totalEstimate - elapsed2
                onProgress?(pct2, eta2.isFinite ? max(0, eta2) : nil, elapsed2)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }
    
    public func finish() {
        postUploadTicker?.cancel()
        postUploadTicker = nil
        let elapsed = Date().timeIntervalSince(t0)
        onProgress?(1.0, 0, elapsed)
    }
    
    public func cancel() {
        postUploadTicker?.cancel()
        postUploadTicker = nil
    }
    
}

/// URLSession delegate to pipe upload progress to the coordinator
public final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    public let coordinator: ProgressCoordinator
    public init(coordinator: ProgressCoordinator) { self.coordinator = coordinator }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        Task { await coordinator.update(sent: totalBytesSent, total: totalBytesExpectedToSend) }
    }
}
