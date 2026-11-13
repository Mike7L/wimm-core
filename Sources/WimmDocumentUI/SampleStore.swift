import Foundation

/// 16 kHz mono samples of the running recording, shared between the audio
/// thread (writer) and the main actor (live text, spoken comments).
///
/// Only what is still needed is kept: the stretch the live transcriber has
/// not read yet, and the stretch since the earliest open voice anchor. A long
/// recording with no anchor therefore holds a few seconds, not an hour.
public final class SampleStore: @unchecked Sendable {
    public init() {}

    public static let sampleRate = 16_000.0

    private let lock = NSLock()
    private var samples: [Float] = []
    /// Absolute index of `samples[0]` since the recording started.
    private var base = 0
    /// Absolute index up to which the live transcriber has taken samples.
    private var drained = 0
    /// Absolute index before which nobody needs samples any more.
    private var keepFrom = 0

    public func append(_ chunk: [Float]) {
        lock.lock(); defer { lock.unlock() }
        samples.append(contentsOf: chunk)
    }

    /// Absolute count of samples recorded so far.
    public var total: Int {
        lock.lock(); defer { lock.unlock() }
        return base + samples.count
    }

    /// New samples for the live transcriber since the previous call.
    public func takeForLive() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let end = base + samples.count
        defer { drained = end; trimLocked() }
        guard drained < end else { return [] }
        return Array(samples[(drained - base)...])
    }

    /// Samples in `[from, to)` (absolute), clipped to what is still held.
    public func slice(from: Int, to: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let start = max(from, base) - base
        let end = min(to, base + samples.count) - base
        guard end > start else { return [] }
        return Array(samples[start..<end])
    }

    /// Nothing before `index` will be asked for again (no open anchor starts earlier).
    public func release(before index: Int) {
        lock.lock(); defer { lock.unlock() }
        keepFrom = max(keepFrom, index)
        trimLocked()
    }

    private func trimLocked() {
        let cut = min(drained, keepFrom) - base
        guard cut > 16_000 else { return } // trim in ≥ 1 s steps
        samples.removeFirst(cut)
        base += cut
    }

    public static func seconds(_ samples: Int) -> Double { Double(samples) / sampleRate }
}
