import SwiftUI
import AppKit

/// Editor shared by both panes: AppKit NSTextView plus a line-number ruler.
/// NSTextView instead of SwiftUI TextEditor because line numbers can only be accurate
/// when computed from NSTextView's line fragments.
final class EditorHandle {
    weak var textView: NSTextView?
    var selection: NSRange {
        textView?.selectedRange() ?? NSRange(location: 0, length: 0)
    }
    func replaceAll(with s: String) {
        guard let tv = textView else { return }
        let full = NSRange(location: 0, length: (tv.string as NSString).length)
        tv.insertText(s, replacementRange: full)
        tv.setSelectedRange(NSRange(location: (s as NSString).length, length: 0))
    }
    func insertText(_ s: String) {
        guard let tv = textView else { return }
        tv.insertText(s, replacementRange: tv.selectedRange())
    }
    func focus() { textView?.window?.makeFirstResponder(textView) }
}

struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var editable: Bool = true
    var fontSize: CGFloat = 15
    var lineHeightMultiple: CGFloat = 1.7
    var placeholder: String = ""
    var handle: EditorHandle? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        /// External text that arrived while an IME composition was in flight (for example the
        /// model's answer): hold it until the composition is committed, because overwriting the
        /// whole text mid-composition swallows the pinyin and the characters around it.
        var pendingText: String?
        /// Last text this editor pushed upward. It separates "the binding is just my own old
        /// value" from "something outside really wrote new content" — during composition the
        /// former must not be recorded as pending, or the commit would overwrite what was typed.
        var lastSynced: String?

        init(_ parent: CodeEditor) { self.parent = parent }

        func textDidChange(_ note: Notification) {
            guard let tv = note.object as? NSTextView else { return }
            // Do not push upward while the IME has marked text: the parent would see uncommitted
            // pinyin, and state plus requests would pick up intermediate values like "nihao".
            // The commit itself posts another notification.
            if !tv.hasMarkedText() {
                // Apply external text that was queued during the composition (the user asked for
                // the model result by pressing a button, so it wins).
                if let pending = pendingText {
                    pendingText = nil
                    if pending != tv.string {
                        parent.writeExternal(pending, to: tv)
                        lastSynced = pending
                        return
                    }
                }
                if parent.text != tv.string { parent.text = tv.string }
                lastSynced = tv.string
            }
            tv.needsDisplay = true      // the placeholder has to be redrawn when the text empties or fills
            if let scroll = tv.enclosingScrollView {
                scroll.verticalRulerView?.needsDisplay = true
            }
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.bg

        let tv = PlaceholderTextView()
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isEditable = editable
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.insertionPointColor = Theme.accent
        tv.textColor = Theme.fg
        tv.font = typography().font
        tv.defaultParagraphStyle = typography().paragraph
        tv.textContainerInset = NSSize(width: 14, height: 14)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.delegate = context.coordinator
        tv.placeholder = placeholder
        tv.string = text
        context.coordinator.lastSynced = text
        applyTypography(to: tv)
        scroll.documentView = tv

        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        scroll.verticalRulerView = LineNumberRulerView(textView: tv)

        handle?.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.isEditable != editable { tv.isEditable = editable }
        if let p = tv as? PlaceholderTextView, p.placeholder != placeholder {
            p.placeholder = placeholder
            p.needsDisplay = true
        }
        if tv.string != text {
            if tv.hasMarkedText() {
                // Never overwrite the whole text during an IME composition (marked text): the
                // binding does not contain the uncommitted pinyin, so writing it deletes the
                // pinyin plus the characters typed right before it — the user sees "typing pinyin
                // deletes my other characters". Only when the binding is not this editor's own
                // old value did something external really write, so queue it for after the commit.
                if text != context.coordinator.lastSynced {
                    context.coordinator.pendingText = text
                }
            } else {
                writeExternal(text, to: tv)
                context.coordinator.lastSynced = text
            }
        }
        handle?.textView = tv
    }

    /// Write external text into the editor. Only legal when no composition is in flight and the
    /// binding really differs.
    func writeExternal(_ newText: String, to tv: NSTextView) {
        let sel = tv.selectedRange()
        tv.string = newText
        applyTypography(to: tv)
        let len = (newText as NSString).length
        tv.setSelectedRange(NSRange(location: min(sel.location, len), length: 0))
        tv.needsDisplay = true
        tv.enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    private func typography() -> (font: NSFont, paragraph: NSParagraphStyle) {
        let font = NSFont.systemFont(ofSize: fontSize)
        // Fixed line height: with lineHeightMultiple both the line fragments and the caret get
        // stretched, so centre-aligned line numbers no longer match the text baseline and the
        // caret looks oversized.
        let lineHeight = ceil(font.ascender - font.descender + font.leading) + 2
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = lineHeight
        p.maximumLineHeight = lineHeight
        p.lineSpacing = 0
        return (font, p)
    }

    private func applyTypography(to tv: NSTextView) {
        let t = typography()
        tv.font = t.font
        tv.defaultParagraphStyle = t.paragraph
        tv.typingAttributes = [
            .font: t.font,
            .foregroundColor: Theme.fg,
            .paragraphStyle: t.paragraph,
        ]
        if let storage = tv.textStorage, storage.length > 0 {
            storage.addAttributes(
                [.font: t.font, .foregroundColor: Theme.fg, .paragraphStyle: t.paragraph],
                range: NSRange(location: 0, length: storage.length)
            )
        }
    }
}

/// NSTextView that draws its own placeholder with the same font and insets as the text, so
/// the placeholder can never drift away from the caret or the first baseline.
final class PlaceholderTextView: NSTextView {
    var placeholder: String = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty, let container = textContainer else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 15),
            .foregroundColor: Theme.dim2,
            .paragraphStyle: defaultParagraphStyle ?? NSParagraphStyle.default,
        ]
        let inset = textContainerInset
        let padding = container.lineFragmentPadding
        let rect = NSRect(
            x: inset.width + padding,
            y: inset.height,
            width: max(0, bounds.width - inset.width * 2 - padding),
            height: max(0, bounds.height - inset.height * 2)
        )
        (placeholder as NSString).draw(in: rect, withAttributes: attrs)
    }
}

/// Line-number gutter: drawn from the layout manager's line fragments, follows scrolling and wrapping.
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
        .foregroundColor: Theme.gutter,
    ]

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 46
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        // Draw only to the scroll view's real height: bounds can be taller than the visible area,
        // and using bounds.height paints the divider up into the title bar.
        let visibleHeight = min(bounds.height, enclosingScrollView?.contentSize.height ?? bounds.height)
        Theme.panel.setFill()
        NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: visibleHeight).fill()
        Theme.border.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: visibleHeight).fill()

        guard let tv = textView,
              let lm = tv.layoutManager,
              let container = tv.textContainer else { return }

        let visible = tv.visibleRect
        let glyphRange = lm.glyphRange(forBoundingRect: visible, in: container)
        let ns = tv.string as NSString

        let startChar = lm.characterIndexForGlyph(at: glyphRange.location)
        var lineNo = 1
        if startChar > 0 {
            for i in 0..<min(startChar, ns.length) where ns.character(at: i) == 0x0A { lineNo += 1 }
        }

        lm.enumerateLineFragments(forGlyphRange: glyphRange) { fragRect, _, _, fragGlyphRange, _ in
            let charRange = lm.characterRange(forGlyphRange: fragGlyphRange, actualGlyphRange: nil)
            let y = fragRect.minY + tv.textContainerInset.height
            let label = "\(lineNo)" as NSString
            let size = label.size(withAttributes: self.attrs)
            // CJK glyphs sit a touch lower than the Latin baseline; nudge the number 2.5pt to line up.
            let drawY = y + (fragRect.height - size.height) / 2 + 2.5
            label.draw(at: NSPoint(x: self.ruleThickness - size.width - 9, y: drawY), withAttributes: self.attrs)

            if charRange.length > 0, charRange.location < ns.length {
                let len = min(charRange.length, ns.length - charRange.location)
                let sub = ns.substring(with: NSRange(location: charRange.location, length: len))
                lineNo += sub.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
            }
        }
    }
}
