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

/// A plain-text Markdown editor. Checklist items ("- [ ] ", "- [x] ") show a round checkbox you
/// can click, Return carries a list on to the next line, and ticked items are struck through.
struct NoteEditor: NSViewRepresentable {
    let noteID: NotesStore.Note.ID?
    let text: String
    let handle: NoteEditorHandle
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
        textView.insertionPointColor = .white
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
        textView.setText(text)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NoteTextView else { return }
        handle.textView = textView
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
    private static let font = NSFont.systemFont(ofSize: 11.5)
    private static let headingFont = NSFont.systemFont(ofSize: 12.5, weight: .bold)
    private static let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
    private static let dim = NSColor.white.withAlphaComponent(0.36)
    /// For the hidden "- [ ] ": small, so the text starts just past the checkbox, and monospaced, so
    /// "[x]" takes as much room as "[ ]" and ticked items line up with the rest.
    private static let markerFont = NSFont.monospacedSystemFont(ofSize: 6, weight: .regular)

    /// The "- [ ]" of each checklist item, and whether it's ticked.
    private var boxes: [(range: NSRange, checked: Bool)] = []

    /// The notch never activates the app, so the first click has to count.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
        storage.setAttributes(Self.base, range: NSRange(location: 0, length: text.length))
        var location = 0
        while location < text.length {
            var start = 0, end = 0, contentsEnd = 0
            text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            let line = NoteLine(text.substring(with: NSRange(location: start, length: contentsEnd - start)))
            let marker = NSRange(location: start + (line.indent as NSString).length, length: (line.marker as NSString).length)
            let content = NSRange(location: NSMaxRange(marker), length: contentsEnd - NSMaxRange(marker))
            switch line.kind {
            case .checklist(let checked):
                storage.addAttributes([.foregroundColor: NSColor.clear, .font: Self.markerFont], range: marker)
                boxes.append((NSRange(location: marker.location, length: min(5, marker.length)), checked))
                if checked {
                    storage.addAttributes([.foregroundColor: Self.dim, .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                           .strikethroughColor: Self.dim], range: content)
                }
            case .heading:
                storage.addAttribute(.font, value: Self.headingFont, range: NSRange(location: start, length: contentsEnd - start))
                storage.addAttribute(.foregroundColor, value: Self.dim, range: marker)
            case .bullet:
                storage.addAttribute(.foregroundColor, value: Self.dim, range: marker)
            case .text:
                break
            }
            location = end
        }
        storage.endEditing()
        self.boxes = boxes
        typingAttributes = Self.base
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

    /// Where a checkbox goes: from the start of its marker, as tall as its line.
    private func rect(for range: NSRange) -> NSRect {
        // Boxes can be a step behind the text while an input method is composing.
        guard let layoutManager, let textContainer, NSMaxRange(range) <= (string as NSString).length else { return .zero }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let marker = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        let line = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        return NSRect(x: marker.minX + textContainerOrigin.x, y: line.minY + textContainerOrigin.y,
                      width: max(marker.width, 13), height: line.height)
    }

    private func drawCheckbox(checked: Bool, in rect: NSRect) {
        // A dark tick on a yellow disc, like Notes; an empty ring otherwise.
        let colors = checked ? [NSColor.black, NSColor.systemYellow] : [NSColor.white.withAlphaComponent(0.5)]
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: colors))
        guard let image = NSImage(systemSymbolName: checked ? "checkmark.circle.fill" : "circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let size = image.size
        let origin = NSPoint(x: rect.minX, y: (rect.midY - size.height / 2).rounded())
        image.draw(in: NSRect(origin: origin, size: size), from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: nil)
    }
}
