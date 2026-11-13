import CoreGraphics

/// The Wimm reading page, shared by both desktop document windows.
public enum DocumentReadingLayout {
    public static let bodyFontSize: CGFloat = 14
    public static let outlineIndent: CGFloat = 24
    public static func headingSize(_ level: Int) -> CGFloat {
        [30, 24, 20, 18, 17, 17][min(max(level, 1), 6) - 1]
    }
    public static func headingSpacing(_ level: Int) -> CGFloat {
        level == 2 ? 14 : 0
    }
    public static let columnWidth: CGFloat = 640
    public static let blockSpacing: CGFloat = 14
    public static let horizontalPadding: CGFloat = 40
    public static let verticalPadding: CGFloat = 32
    public static let toolbarHeight: CGFloat = 52
}
