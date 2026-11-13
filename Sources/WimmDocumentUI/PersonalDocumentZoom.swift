import CoreGraphics

/// Text zoom of the personal document: fixed steps for ⌘+ / ⌘−, any value in
/// range for a pinch. The reading column widens with the text, so a zoomed
/// line keeps roughly the same number of words.
public enum PersonalDocumentZoom {
    public static let steps: [Double] = [0.8, 0.9, 1, 1.1, 1.25, 1.4, 1.6, 1.8, 2]
    public static var range: ClosedRange<Double> { steps.first!...steps.last! }

    public static func clamped(_ scale: Double) -> Double { min(max(scale, range.lowerBound), range.upperBound) }

    /// The next step above `scale`; a pinch can leave it between steps.
    public static func zoomedIn(_ scale: Double) -> Double { steps.first { $0 > scale + 0.001 } ?? range.upperBound }
    public static func zoomedOut(_ scale: Double) -> Double { steps.last { $0 < scale - 0.001 } ?? range.lowerBound }

    public static func percent(_ scale: Double) -> String { "\(Int((scale * 100).rounded()))%" }
}
