import AppKit
import WimmDocumentUI
import Foundation

/// Studio uses Wimm's typography and inline-note rendering. Tables/code have
/// their own shared SwiftUI view; the plain fallback supplies anchor text only.
@MainActor enum BlockRenderer {
    struct Style: Equatable {
        var scale: CGFloat = 1
        var text: NSColor = .labelColor
        var secondary: NSColor = .secondaryLabelColor
        var link: NSColor = .linkColor
    }

    static func render(_ markdown: String, baseURL: URL?, style: Style) -> NSAttributedString {
        PersonalDocumentRendering.attributed(markdown, baseURL: baseURL,
            style: .init(scale: style.scale, text: style.text, secondary: style.secondary, link: style.link))
            ?? NSAttributedString(string: markdown, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12.5 * style.scale, weight: .regular),
                .foregroundColor: style.secondary,
            ])
    }
}
