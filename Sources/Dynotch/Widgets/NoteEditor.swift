import AppKit
import SwiftUI

/// Gives the Notes header's buttons the text view they act on.
@MainActor
final class NoteEditorHandle {
    fileprivate weak var textView: NoteTextView?

    /// Turns the lines around the cursor into checklist items, or back into plain lines.
    func toggleChecklist() {
        textView?.toggleChecklist()
    }
}

/// How large a note's text is drawn: small in a widget, a page's size with the first line as its
/// title in Notes.
struct NoteStyle: Equatable {
    /// The text's point size.
    var size: CGFloat
    /// The first line's size, as the note's title, or nil to draw it like the rest.
    var titleSize: CGFloat?
    /// Room after each line, which spaces a checklist out into rows.
    var lineGap: CGFloat
    /// A checkbox's side.
    var box: CGFloat

    static let card = NoteStyle(size: 12.5, titleSize: nil, lineGap: 3, box: 12)
    static let page = NoteStyle(size: 13.5, titleSize: 18, lineGap: 10, box: 15)
}

/// A plain-text Markdown editor. Checklist items ("- [ ] ", "- [x] ") show a square checkbox you
/// can click, Return carries a list on to the next line, and ticked items are struck through.
struct NoteEditor: NSViewRepresentable {
    let noteID: NotesStore.Note.ID?
    let text: String
    let handle: NoteEditorHandle
    var style: NoteStyle = .card
    let onChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NoteTextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        let scrollView = NoteScrollView()
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = textView

        handle.textView = textView
        context.coordinator.noteID = noteID
        textView.follow(context.environment.notchTheme, style: style)
        textView.setText(text)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NoteTextView else { return }
        handle.textView = textView
        textView.follow(context.environment.notchTheme, style: style)
        context.coordinator.onChange = onChange
        if context.coordinator.noteID != noteID {
            context.coordinator.noteID = noteID
            context.coordinator.undo.removeAllActions()
            textView.setText(text)
        } else if textView.string != text, !textView.hasMarkedText() {
            // Changed on disk, by another app or another Mac.
            textView.setText(text, keepingSelection: true)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onChange: (String) -> Void
        var noteID: NotesStore.Note.ID?
        /// Each note's edits undo on their own, apart from the notch's other text fields.
        let undo = UndoManager()

        init(onChange: @escaping (String) -> Void) {
            self.onChange = onChange
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NoteTextView else { return }
            textView.restyle()
            onChange(textView.string)
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            undo
        }
    }
}

/// Keeps the text view as wide as the visible area, so lines wrap to fit.
private final class NoteScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let documentView, documentView.frame.width != contentSize.width else { return }
        documentView.setFrameSize(NSSize(width: contentSize.width, height: documentView.frame.height))
    }
}

final class NoteTextView: NSTextView {
    private var style = NoteStyle.card
    private var bodyFont = NSFont.systemFont(ofSize: NoteStyle.card.size)
    private var headingFont = NSFont.systemFont(ofSize: NoteStyle.card.size + 1, weight: .bold)
    private var base: [NSAttributedString.Key: Any] = [:]
    /// For the hidden "- [ ] ": small, so the text starts just past the checkbox, and monospaced, so
    /// "[x]" takes as much room as "[ ]" and ticked items line up with the rest.
    private var markerFont = NSFont.monospacedSystemFont(ofSize: 6, weight: .regular)

    /// The text, in the theme's primary.
    private var ink = NSColor.labelColor
    /// Ticked items: the theme's secondary, struck through.
    private var done = NSColor.secondaryLabelColor
    /// List markers: the theme's tertiary.
    private var dim = NSColor.tertiaryLabelColor
    private var accent = NSColor.controlAccentColor
    private var onAccent = NSColor.white
    private var boxRadius: CGFloat = 2
    /// The theme and the style the colors and fonts were last set from.
    private var theme: NotchTheme?

    /// The "- [ ]" of each checklist item, and whether it's ticked.
    private var boxes: [(range: NSRange, checked: Bool)] = []

    /// The notch never activates the app, so the first click has to count.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Takes its colors from the notch's theme, the insertion point in the accent, and its sizes from
    /// `style`. Restyles only when either changed.
    func follow(_ theme: NotchTheme, style: NoteStyle) {
        guard theme != self.theme || style != self.style || base.isEmpty else { return }
        self.theme = theme
        self.style = style
        ink = NSColor(theme.primary)
        done = NSColor(theme.secondary)
        dim = NSColor(theme.tertiary)
        accent = NSColor(theme.accent)
        onAccent = NSColor(theme.onAccent)
        boxRadius = min(theme.radius * 0.8, style.box / 2 - 2)
        insertionPointColor = accent
        bodyFont = NSFont.systemFont(ofSize: style.size)
        headingFont = NSFont.systemFont(ofSize: style.size + 1, weight: .bold)
        markerFont = NSFont.monospacedSystemFont(ofSize: (style.box + 7) / 3.6, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = style.lineGap
        base = [.font: bodyFont, .foregroundColor: ink, .paragraphStyle: paragraph]
        restyle()
    }

    func setText(_ text: String, keepingSelection: Bool = false) {
        let selection = selectedRange()
        let scrolled = enclosingScrollView?.contentView.bounds.origin ?? .zero
        string = text
        restyle()
        let length = (text as NSString).length
        setSelectedRange(keepingSelection ? NSRange(location: min(selection.location, length), length: 0)
                                          : NSRange(location: length, length: 0))
        // A note opens at its top; one that changed on disk stays where it was.
        scroll(keepingSelection ? scrolled : .zero)
    }

    /// Styles the Markdown: hidden checklist markers with a checkbox drawn in their place, ticked
    /// items struck through, bold headings and dimmed bullets.
    func restyle() {
        guard let storage = textStorage, !hasMarkedText() else { return }
        let text = storage.string as NSString
        var boxes: [(range: NSRange, checked: Bool)] = []
        storage.beginEditing()
        storage.setAttributes(base, range: NSRange(location: 0, length: text.length))
        var location = 0
        while location < text.length {
            var start = 0, end = 0, contentsEnd = 0
            text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            let line = NoteLine(text.substring(with: NSRange(location: start, length: contentsEnd - start)))
            let marker = NSRange(location: start + (line.indent as NSString).length, length: (line.marker as NSString).length)
            let content = NSRange(location: NSMaxRange(marker), length: contentsEnd - NSMaxRange(marker))
            let whole = NSRange(location: start, length: contentsEnd - start)
            switch line.kind {
            case .checklist(let checked):
                storage.addAttributes([.foregroundColor: NSColor.clear, .font: markerFont], range: marker)
                boxes.append((NSRange(location: marker.location, length: min(5, marker.length)), checked))
                if checked {
                    storage.addAttributes([.foregroundColor: done, .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                           .strikethroughColor: done], range: content)
                }
            case .heading where start == 0 && style.titleSize != nil:
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: style.titleSize!, weight: .semibold), range: whole)
                storage.addAttribute(.foregroundColor, value: dim, range: marker)
            case .heading:
                storage.addAttribute(.font, value: headingFont, range: whole)
                storage.addAttribute(.foregroundColor, value: dim, range: marker)
            case .bullet:
                storage.addAttribute(.foregroundColor, value: dim, range: marker)
            case .text:
                // The note's first line is its title, drawn as one on a page.
                if start == 0, let titleSize = style.titleSize {
                    storage.addAttribute(.font, value: NSFont.systemFont(ofSize: titleSize, weight: .semibold), range: whole)
                }
            }
            location = end
        }
        storage.endEditing()
        self.boxes = boxes
        typingAttributes = base
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for box in boxes {
            let rect = self.rect(for: box.range)
            guard rect.intersects(dirtyRect) else { continue }
            drawCheckbox(checked: box.checked, in: rect)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let box = boxes.first(where: { rect(for: $0.range).insetBy(dx: -3, dy: -2).contains(point) }) {
            toggle(box.range)
            return
        }
        super.mouseDown(with: event)
    }

    /// Carries a checklist or bulleted list on to the next line. Return on an empty item ends the list.
    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let selection = selectedRange()
        var start = 0, contentsEnd = 0
        text.getLineStart(&start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: selection.location, length: 0))
        let line = NoteLine(text.substring(with: NSRange(location: start, length: contentsEnd - start)))
        let contentStart = start + ((line.indent + line.marker) as NSString).length
        guard line.kind != .text, line.kind != .heading, selection.location >= contentStart else {
            super.insertNewline(sender)
            return
        }
        if line.content.trimmingCharacters(in: .whitespaces).isEmpty, selection.length == 0 {
            replace(NSRange(location: start, length: contentsEnd - start), with: "")
            return
        }
        let marker = line.kind == .bullet ? line.marker : String(line.marker.prefix(2)) + "[ ] "
        insertText("\n" + line.indent + marker, replacementRange: selection)
    }

    func toggleChecklist() {
        let text = string as NSString
        let range = text.lineRange(for: selectedRange())
        var lines: [String] = []
        text.substring(with: range).enumerateLines { line, _ in lines.append(line) }
        if lines.isEmpty { lines = [""] }
        let parsed = lines.map { NoteLine($0) }
        let allChecklist = parsed.allSatisfy {
            if case .checklist = $0.kind { return true }
            return false
        }
        let replaced = parsed.map { line -> String in
            if allChecklist { return line.indent + line.content }
            if case .checklist = line.kind { return line.indent + line.marker + line.content }
            return line.indent + "- [ ] " + line.content
        }
        let trailingNewline = range.length > 0 && text.substring(with: range).hasSuffix("\n")
        let replacement = replaced.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        replace(range, with: replacement)
        // The cursor goes to the end of the first line, ready to type.
        let firstLine = (replaced.first ?? "") as NSString
        setSelectedRange(NSRange(location: range.location + firstLine.length, length: 0))
        window?.makeKey()
        window?.makeFirstResponder(self)
    }

    // MARK: Private

    private func toggle(_ box: NSRange) {
        // "- [ ]": the mark sits between the brackets.
        let mark = NSRange(location: box.location + 3, length: 1)
        let ticked = (string as NSString).substring(with: mark) != " "
        replace(mark, with: ticked ? " " : "x")
    }

    /// An edit that can be undone and reaches the delegate, like typing.
    private func replace(_ range: NSRange, with text: String) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
    }

    /// The checkbox: a square at the start of its marker, centred on the line's capitals.
    private func rect(for range: NSRange) -> NSRect {
        // Boxes can be a step behind the text while an input method is composing.
        guard let layoutManager, NSMaxRange(range) <= (string as NSString).length else { return .zero }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let start = layoutManager.location(forGlyphAt: glyphs.location)
        // The baseline, down from the top of the line in this flipped view.
        let baseline = line.minY + start.y + textContainerOrigin.y
        let side = style.box
        let midY = baseline - bodyFont.capHeight / 2
        return NSRect(x: (line.minX + start.x + textContainerOrigin.x).rounded(), y: (midY - side / 2).rounded(),
                      width: side, height: side)
    }

    /// An empty square in the secondary text color, or a tick on the accent once it's done.
    private func drawCheckbox(checked: Bool, in rect: NSRect) {
        if checked {
            let shape = NSBezierPath(roundedRect: rect, xRadius: boxRadius, yRadius: boxRadius)
            accent.setFill()
            shape.fill()
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: rect.minX + rect.width * 0.26, y: rect.minY + rect.height * 0.52))
            tick.line(to: NSPoint(x: rect.minX + rect.width * 0.43, y: rect.minY + rect.height * 0.69))
            tick.line(to: NSPoint(x: rect.minX + rect.width * 0.75, y: rect.minY + rect.height * 0.33))
            tick.lineWidth = max(1.5, rect.width * 0.12)
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            onAccent.setStroke()
            tick.stroke()
        } else {
            let inset = rect.insetBy(dx: 0.75, dy: 0.75)
            let shape = NSBezierPath(roundedRect: inset, xRadius: max(0, boxRadius - 0.75), yRadius: max(0, boxRadius - 0.75))
            shape.lineWidth = 1.5
            done.setStroke()
            shape.stroke()
        }
    }
}
