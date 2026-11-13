import AppKit
import WimmDocumentUI
import SwiftUI
import WimmInfrastructure

/// Maps inline comment/reaction highlights and reaction emoji into an
/// `NSAttributedString` while translating displayed offsets back to base text.
struct StudioInlineMarks {
    struct Mark: Equatable {
        let thread: DocumentCommentThread
        let range: NSRange
        let isFocused: Bool
    }

    struct Shown {
        let thread: DocumentCommentThread
        let textRange: NSRange
        let badgeRange: NSRange?
    }

    let attributed: NSAttributedString
    let shown: [Shown]
    private let insertions: [(at: Int, length: Int)]

    static func isPlainReaction(_ thread: DocumentCommentThread) -> Bool {
        thread.isReaction && (thread.root.text ?? "").isEmpty && thread.root.reaction != nil
    }

    init(text: NSAttributedString, marks: [Mark], activeVoiceRange: NSRange?) {
        let styled = NSMutableAttributedString(attributedString: text)
        let length = styled.length
        let validMarks = marks.filter { NSMaxRange($0.range) <= length && $0.range.length > 0 }
        let gold = NSColor.systemYellow

        for mark in validMarks {
            let alpha: CGFloat = mark.isFocused ? 0.45 : (Self.isPlainReaction(mark.thread) ? 0.14 : 0.28)
            styled.addAttribute(.backgroundColor, value: gold.withAlphaComponent(alpha), range: mark.range)
        }
        if let voice = activeVoiceRange, NSMaxRange(voice) <= length, voice.length > 0 {
            styled.addAttribute(.backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.24), range: voice)
        }

        let badges = Dictionary(grouping: validMarks.filter { Self.isPlainReaction($0.thread) }) { NSMaxRange($0.range) }
        var insertions: [(at: Int, length: Int)] = []
        var badgeRanges: [String: NSRange] = [:]
        var shift = 0

        for at in badges.keys.sorted() {
            let font = (at > 0 ? styled.attribute(.font, at: at - 1 + shift, effectiveRange: nil) as? NSFont : nil)
                ?? NSFont.systemFont(ofSize: 16)
            let paragraph = at > 0 ? styled.attribute(.paragraphStyle, at: at - 1 + shift, effectiveRange: nil) : nil
            let run = NSMutableAttributedString(string: "\u{2009}", attributes: [.font: font])
            for mark in badges[at]! {
                let emoji = NSAttributedString(string: mark.thread.root.reaction ?? "", attributes: [
                    .font: NSFont.systemFont(ofSize: font.pointSize * 0.85),
                    .baselineOffset: font.pointSize * 0.08,
                ])
                badgeRanges[mark.thread.id] = NSRange(location: at + shift + run.length, length: emoji.length)
                run.append(emoji)
            }
            if let paragraph {
                run.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: run.length))
            }
            styled.insert(run, at: at + shift)
            insertions.append((at, run.length))
            shift += run.length
        }

        self.insertions = insertions
        self.attributed = styled

        func displayOffset(_ base: Int, isEnd: Bool) -> Int {
            base + insertions.filter { isEnd ? $0.at < base : $0.at <= base }.reduce(0) { $0 + $1.length }
        }

        self.shown = validMarks.map { mark in
            let start = displayOffset(mark.range.location, isEnd: false)
            let end = displayOffset(NSMaxRange(mark.range), isEnd: true)
            return Shown(
                thread: mark.thread,
                textRange: NSRange(location: start, length: max(0, end - start)),
                badgeRange: badgeRanges[mark.thread.id]
            )
        }
    }

    func baseOffset(_ displayed: Int) -> Int {
        var shift = 0
        for ins in insertions {
            let start = ins.at + shift
            if displayed < start { break }
            if displayed < start + ins.length { return ins.at }
            shift += ins.length
        }
        return displayed - shift
    }

    func displayRange(forBaseRange base: NSRange) -> NSRange {
        func displayOffset(_ offset: Int, isEnd: Bool) -> Int {
            offset + insertions.filter { isEnd ? $0.at < offset : $0.at <= offset }.reduce(0) { $0 + $1.length }
        }
        let start = displayOffset(base.location, isEnd: false)
        let end = displayOffset(NSMaxRange(base), isEnd: true)
        return NSRange(location: start, length: max(0, end - start))
    }

    func thread(at displayedIndex: Int) -> DocumentCommentThread? {
        if let hit = shown.first(where: { $0.badgeRange.map { NSLocationInRange(displayedIndex, $0) } == true }) {
            return hit.thread
        }
        return shown
            .filter { NSLocationInRange(displayedIndex, $0.textRange) }
            .min { $0.textRange.length < $1.textRange.length }?
            .thread
    }

    func displayRange(of threadID: String) -> NSRange? {
        guard let item = shown.first(where: { $0.thread.id == threadID }) else { return nil }
        return item.badgeRange.map { NSUnionRange(item.textRange, $0) } ?? item.textRange
    }
}

/// Self-sizing AppKit text view for a document block:
/// - 1 click selects the sentence under the pointer (unless clicking a thread or link);
/// - 2 clicks select the word under the pointer;
/// - dragging selects an arbitrary span;
/// - while recording is active, selecting any unit immediately attaches a voice anchor to it.
struct StudioBlockTextView: NSViewRepresentable {
    typealias Mark = StudioInlineMarks.Mark

    struct Actions {
        var isRecording: Bool
        var onPointVoice: (TextQuoteSelector) -> Void
        var onReact: (TextQuoteSelector, String) -> Void
        var onComment: (TextQuoteSelector, String) -> Void
        var onReply: (DocumentCommentThread, String) -> Void
        var onSetStatus: (DocumentCommentThread, DocumentCommentStatus) -> Void
        var onEditBlock: () -> Void
        var onOpenURL: (URL) -> Void
    }

    let text: NSAttributedString
    let marks: [Mark]
    let activeVoiceRange: NSRange?
    let actions: Actions

    func makeCoordinator() -> Coordinator { Coordinator(actions: actions) }

    func makeNSView(context: Context) -> CanvasTextView {
        let view = CanvasTextView(blockText: ())
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        view.delegate = context.coordinator
        view.actions = actions
        apply(to: view)
        return view
    }

    func updateNSView(_ view: CanvasTextView, context: Context) {
        context.coordinator.actions = actions
        view.actions = actions
        guard view.baseText != text || view.marks != marks || view.activeVoiceRange != activeVoiceRange else { return }
        apply(to: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: CanvasTextView, context: Context) -> CGSize? {
        view.blockSize(for: proposal)
    }

    private func apply(to view: CanvasTextView) {
        let selected = view.selectedRange()
        let inline = StudioInlineMarks(text: text, marks: marks, activeVoiceRange: activeVoiceRange)
        view.textStorage?.setAttributedString(inline.attributed)
        view.invalidateBlockMeasurements()
        view.baseText = text
        view.marks = marks
        view.activeVoiceRange = activeVoiceRange
        view.inline = inline
        if NSMaxRange(selected) <= inline.attributed.length {
            view.setSelectedRange(selected)
        }
        view.invalidateIntrinsicContentSize()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var actions: Actions
        init(actions: Actions) { self.actions = actions }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL { actions.onOpenURL(url) }
            else if let str = link as? String, let url = URL(string: str) { actions.onOpenURL(url) }
            return true
        }
    }

    final class CanvasTextView: DocumentBlockTextView {
        var actions: Actions?
        var baseText = NSAttributedString()
        var marks: [Mark] = []
        var activeVoiceRange: NSRange?
        var inline: StudioInlineMarks?

        private var reactionPopover: NSPopover?
        private var threadPopover: NSPopover?
        private var threadPopoverID: String?
        private var threadPopoverIsPinned = false
        private var hoverTimer: Timer?
        private var closeTimer: Timer?
        private var hoverArea: NSTrackingArea?

        override func layout() {
            super.layout()
            guard let container = textContainer, bounds.width > 0,
                  abs(container.size.width - bounds.width) > 0.5 else { return }
            container.containerSize = NSSize(width: bounds.width, height: .greatestFiniteMagnitude)
        }

        // MARK: - Sentence on 1 click, Word on 2 clicks, Drag for custom span

        override func mouseDown(with event: NSEvent) {
            let downPoint = event.locationInWindow

            if event.clickCount == 2 {
                if let baseIndex = baseCharacterIndex(at: event),
                   let wordBase = TextUnits.word(at: baseIndex, in: baseText.string),
                   let disp = inline?.displayRange(forBaseRange: wordBase) {
                    setSelectedRange(disp)
                    activateSelection()
                    return
                }
                super.mouseDown(with: event)
                if selectionAnchor != nil { activateSelection() }
                return
            }

            // Let NSTextView run its drag loop so manual drag selections work naturally.
            super.mouseDown(with: event)

            let upPoint = window?.mouseLocationOutsideOfEventStream ?? downPoint
            let dragged = hypot(upPoint.x - downPoint.x, upPoint.y - downPoint.y) > 3

            if dragged, selectionAnchor != nil {
                activateSelection()
                return
            }

            // Single click without drag:
            // 1. Existing thread / reaction badge opens its thread popover.
            if let thread = thread(at: event) {
                showThread(thread, pinned: true)
                return
            }
            // 2. Link clicks are handled by the delegate.
            if let dispIndex = displayedCharacterIndex(at: event),
               dispIndex < (textStorage?.length ?? 0),
               textStorage?.attribute(.link, at: dispIndex, effectiveRange: nil) != nil {
                return
            }
            // 3. Otherwise, select the whole sentence under the click!
            if let baseIndex = baseCharacterIndex(at: event),
               let sentenceBase = TextUnits.sentence(at: baseIndex, in: baseText.string),
               let disp = inline?.displayRange(forBaseRange: sentenceBase) {
                setSelectedRange(disp)
                activateSelection()
            }
        }

        private func activateSelection() {
            guard let selector = selectionAnchor else { return }
            if actions?.isRecording == true {
                actions?.onPointVoice(selector)
            }
            showReactionBar(nil)
        }

        // MARK: - Character hit-testing

        private func displayedCharacterIndex(at event: NSEvent) -> Int? {
            guard let layoutManager, let textContainer else { return nil }
            var pt = convert(event.locationInWindow, from: nil)
            pt.x -= textContainerOrigin.x
            pt.y -= textContainerOrigin.y
            let glyph = layoutManager.glyphIndex(for: pt, in: textContainer)
            guard glyph < layoutManager.numberOfGlyphs,
                  layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
                      .insetBy(dx: -2, dy: -3).contains(pt) else { return nil }
            return layoutManager.characterIndexForGlyph(at: glyph)
        }

        private func baseCharacterIndex(at event: NSEvent) -> Int? {
            guard let disp = displayedCharacterIndex(at: event) else { return nil }
            return inline?.baseOffset(disp) ?? disp
        }

        private func thread(at event: NSEvent) -> DocumentCommentThread? {
            guard let disp = displayedCharacterIndex(at: event) else { return nil }
            return inline?.thread(at: disp)
        }

        // MARK: - Hovering threads

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverArea { removeTrackingArea(hoverArea) }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            hoverArea = area
        }

        override func mouseMoved(with event: NSEvent) {
            super.mouseMoved(with: event)
            guard let thread = thread(at: event) else {
                hoverTimer?.invalidate(); hoverTimer = nil
                scheduleHoverClose()
                return
            }
            closeTimer?.invalidate()
            guard threadPopoverID != thread.id || threadPopover?.isShown != true else { return }
            hoverTimer?.invalidate()
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.showThread(thread, pinned: false) }
            }
        }

        override func mouseExited(with event: NSEvent) {
            super.mouseExited(with: event)
            hoverTimer?.invalidate(); hoverTimer = nil
            scheduleHoverClose()
        }

        private func scheduleHoverClose() {
            guard threadPopover?.isShown == true, !threadPopoverIsPinned else { return }
            closeTimer?.invalidate()
            closeTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let pop = self.threadPopover, !self.threadPopoverIsPinned else { return }
                    if let frame = pop.contentViewController?.view.window?.frame, frame.contains(NSEvent.mouseLocation) { return }
                    pop.close()
                }
            }
        }

        func showThread(_ thread: DocumentCommentThread, pinned: Bool) {
            guard let inline, let range = inline.displayRange(of: thread.id),
                  let layoutManager, let textContainer else { return }
            hoverTimer?.invalidate(); closeTimer?.invalidate()
            if threadPopoverID == thread.id, let threadPopover, threadPopover.isShown {
                threadPopoverIsPinned = threadPopoverIsPinned || pinned
                return
            }
            threadPopover?.close()
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            rect.origin.x += textContainerOrigin.x
            rect.origin.y += textContainerOrigin.y

            let pop = NSPopover()
            pop.behavior = .transient
            pop.animates = false
            let close = { [weak pop] () -> Void in pop?.close() }
            let host = NSHostingController(rootView: StudioThreadPopover(
                thread: thread,
                onReply: { [weak self] text in self?.actions?.onReply(thread, text); close() },
                onSetStatus: { [weak self] status in self?.actions?.onSetStatus(thread, status); close() },
                onHover: { [weak self] inside in if !inside { self?.scheduleHoverClose() } else { self?.closeTimer?.invalidate() } },
                onEngage: { [weak self] in self?.threadPopoverIsPinned = true },
                onOpenSource: { [weak self] url in close(); self?.actions?.onOpenURL(url) }
            ))
            host.sizingOptions = [.preferredContentSize]
            pop.contentViewController = host
            pop.show(relativeTo: rect, of: self, preferredEdge: .maxY)
            threadPopover = pop
            threadPopoverID = thread.id
            threadPopoverIsPinned = pinned
        }

        // MARK: - Selection anchor & Reaction bar

        var selectionAnchor: TextQuoteSelector? {
            let sel = selectedRange()
            guard sel.length > 0, NSMaxRange(sel) <= (string as NSString).length else { return nil }
            let base = baseText.string as NSString
            let start = inline?.baseOffset(sel.location) ?? sel.location
            let end = inline?.baseOffset(NSMaxRange(sel)) ?? NSMaxRange(sel)
            let range = NSRange(location: start, length: max(0, min(end, base.length) - start))
            guard range.length > 0,
                  !base.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return TextQuoteSelector(selecting: range, in: base as String)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .option],
               event.charactersIgnoringModifiers?.lowercased() == "m",
               window?.firstResponder === self, selectionAnchor != nil {
                activateSelection()
                return true
            }
            return super.performKeyEquivalent(with: event)
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = (super.menu(for: event)?.copy() as? NSMenu) ?? NSMenu()
            var index = 0
            func insert(_ item: NSMenuItem) { menu.insertItem(item, at: index); index += 1 }
            if selectionAnchor != nil {
                let react = NSMenuItem(title: "React / Comment…", action: #selector(showReactionBar(_:)), keyEquivalent: "m")
                react.keyEquivalentModifierMask = [.command, .option]
                react.target = self
                insert(react)
                insert(.separator())
            }
            let edit = NSMenuItem(title: "Edit Paragraph…", action: #selector(editParagraph(_:)), keyEquivalent: "")
            edit.target = self
            insert(edit)
            insert(.separator())
            return menu
        }

        @objc private func editParagraph(_ sender: Any?) {
            reactionPopover?.close()
            actions?.onEditBlock()
        }

        @objc func showReactionBar(_ sender: Any?) {
            guard let selector = selectionAnchor, let layoutManager, let textContainer else { return }
            threadPopover?.close()
            let glyphs = layoutManager.glyphRange(forCharacterRange: selectedRange(), actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            rect.origin.x += textContainerOrigin.x
            rect.origin.y += textContainerOrigin.y
            reactionPopover?.close()

            let pop = NSPopover()
            pop.behavior = .transient
            pop.animates = false
            let close = { [weak pop] () -> Void in pop?.close() }
            let host = NSHostingController(rootView: StudioReactionBar(
                isVoiceListening: actions?.isRecording == true,
                onReact: { [weak self] emoji in self?.actions?.onReact(selector, emoji); close() },
                onComment: { [weak self] text in self?.actions?.onComment(selector, text); close() },
                onEditBlock: { [weak self] in close(); self?.actions?.onEditBlock() },
                onCancel: close
            ))
            host.sizingOptions = [.preferredContentSize]
            pop.contentViewController = host
            pop.show(relativeTo: rect, of: self, preferredEdge: .minY)
            reactionPopover = pop
        }
    }
}
