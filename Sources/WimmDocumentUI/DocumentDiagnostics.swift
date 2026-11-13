import AppKit
import SwiftUI
import Observation

/// Counters describe work, not estimated allocations. Enabled only by the isolated profiler.
@MainActor public enum DocumentDiagnostics {
    public static let enabled = ProcessInfo.processInfo.environment["WIMM_DOCUMENT_PROFILE"] == "1"
    /// Reproducible reference algorithm, available only in the isolated profiler.
    public static let reference = enabled && ProcessInfo.processInfo.environment["WIMM_PROFILE_REFERENCE"] == "1"
    public static var liveTextViews = 0
    public static var peakTextViews = 0
    public static var renders = 0
    public static var renderHits = 0
    public static var measurements = 0
    public static var measurementHits = 0
    public static func viewCreated() { guard enabled else { return }; liveTextViews += 1; peakTextViews = max(peakTextViews, liveTextViews) }
    public static func viewDestroyed() { guard enabled else { return }; liveTextViews -= 1 }
    public static func rendered() { if enabled { renders += 1 } }
    public static func measured() { if enabled { measurements += 1 } }
    public static var counters: [String: Int] {
        ["live_text_views": liveTextViews, "peak_text_views": peakTextViews, "render_misses": renders,
         "render_hits": renderHits, "measurement_misses": measurements, "measurement_hits": measurementHits]
    }
    public static let control = Control()
    @Observable @MainActor public final class Control {
        public var documentLoaded = false
        public var expansion = 0
        public var scrollToEnd = false
        public init() {}
    }
}

/// Read-only blocks measure without reflowing their displayed TextKit container.
/// Only the current block and eight width results are retained.
@MainActor open class DocumentBlockTextView: NSTextView {
    private var measuringStorage: NSTextStorage?
    private var measuringLayout: NSLayoutManager?
    private var measuringContainer: NSTextContainer?
    private var sizes: [CGFloat: CGSize] = [:]

    public override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        DocumentDiagnostics.viewCreated()
    }
    public convenience init(blockText: Void) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer()
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
    }
    public required init?(coder: NSCoder) { super.init(coder: coder); DocumentDiagnostics.viewCreated() }
    deinit { MainActor.assumeIsolated { DocumentDiagnostics.viewDestroyed() } }

    /// Call after replacing text or its attributes, before asking SwiftUI to remeasure.
    public func invalidateBlockMeasurements() {
        sizes.removeAll(keepingCapacity: true)
        measuringStorage = nil; measuringLayout = nil; measuringContainer = nil
    }
    public func blockSize(for proposal: ProposedViewSize) -> CGSize? {
        let candidate = proposal.width ?? (bounds.width > 0 ? bounds.width : 640)
        guard candidate.isFinite, candidate > 0 else { return nil }
        let width = max(40, candidate)
        if DocumentDiagnostics.reference {
            guard let container = textContainer, let layout = layoutManager else { return nil }
            let currentWidth = bounds.width
            container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            layout.ensureLayout(for: container)
            let height = ceil(max(20, layout.usedRect(for: container).height))
            if currentWidth > 0, currentWidth != width {
                container.containerSize = NSSize(width: currentWidth, height: CGFloat.greatestFiniteMagnitude)
            }
            DocumentDiagnostics.measured()
            return CGSize(width: width, height: height)
        }
        if let cached = sizes[width] {
            if DocumentDiagnostics.enabled { DocumentDiagnostics.measurementHits += 1 }
            return cached
        }
        if measuringContainer == nil {
            let storage = NSTextStorage(attributedString: textStorage ?? NSAttributedString(string: string))
            let layout = NSLayoutManager()
            let container = NSTextContainer(containerSize: NSSize(width: width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = textContainer?.lineFragmentPadding ?? 0
            storage.addLayoutManager(layout); layout.addTextContainer(container)
            measuringStorage = storage; measuringLayout = layout; measuringContainer = container
        }
        guard let container = measuringContainer, let layout = measuringLayout else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let result = CGSize(width: width, height: ceil(max(20, layout.usedRect(for: container).height)))
        DocumentDiagnostics.measured()
        if sizes.count >= 8 { sizes.removeAll(keepingCapacity: true) }
        sizes[width] = result
        return result
    }
}
