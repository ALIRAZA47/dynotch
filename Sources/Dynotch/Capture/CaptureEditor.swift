import AppKit
import SwiftUI

/// A capture being taken: the frozen displays, the region selected on one of them, the tool in
/// hand and the marks made so far. The overlays hand it the mouse and keyboard and draw what it
/// holds. Points are the display's own, with the origin at its top-left corner.
@MainActor
final class CaptureEditor: ObservableObject {
    /// What becomes of the finished capture.
    enum Finish: Equatable {
        case copy, save, copyAndSave, addToTray, pin, copyText, record

        init(_ action: CaptureAction) {
            switch action {
            case .copy: self = .copy
            case .save: self = .save
            case .copyAndSave: self = .copyAndSave
            }
        }
    }

    /// A corner or an edge of the selection that can be dragged.
    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        func point(in rect: CGRect) -> CGPoint {
            switch self {
            case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
            case .top: CGPoint(x: rect.midX, y: rect.minY)
            case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
            case .right: CGPoint(x: rect.maxX, y: rect.midY)
            case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
            case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
            case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
            case .left: CGPoint(x: rect.minX, y: rect.midY)
            }
        }

        var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
        var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
        var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
        var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }

        /// AppKit has no public diagonal resize cursor, so the corners keep the crosshair.
        var cursor: NSCursor {
            switch self {
            case .top, .bottom: .resizeUpDown
            case .left, .right: .resizeLeftRight
            default: .crosshair
            }
        }
    }

    /// What a click would select, shown before it does: the window under the pointer, or with
    /// ⌥ held the display it's on.
    struct Hover: Equatable {
        let display: CGDirectDisplayID
        /// Nil is the whole display.
        let window: CaptureWindow?
    }

    private enum Drag {
        /// `wholeDisplay` is ⌥ being held at the press, for if this turns out to be a click.
        case selecting(start: CGPoint, wholeDisplay: Bool)
        case moving(grip: CGPoint)
        case resizing(Handle, original: CGRect)
        case drawing(start: CGPoint)
    }

    static let handleSize: CGFloat = 8
    /// A press that travels less than this is a click: it selects the window under it, or the whole display.
    private static let clickSlop: CGFloat = 3

    let displays: [CaptureDisplay]
    /// The theme's accent, for the outline, the handles and the selected tool.
    let accent: Color
    let document = AnnotationDocument()

    /// The display the selection is on.
    @Published private(set) var activeDisplay: CGDirectDisplayID?
    @Published private(set) var selection: CGRect? {
        didSet { if selection != nil { setHover(nil) } }
    }
    /// The region being dragged out, before it becomes the selection.
    @Published private(set) var rubberBand: CGRect?
    /// Nil over the bare desktop, and once there's a selection or a drag. Change it through
    /// `setHover`: every overlay's view reads the editor, so it mustn't publish on each mouse move.
    @Published private(set) var hover: Hover?
    /// Nil is the selection tool: dragging inside the selection moves it.
    @Published var tool: AnnotationTool?
    @Published var color: AnnotationColor = .red
    @Published var width: CGFloat = 4 {
        didSet { if let draft, case .text = draft.kind { self.draft?.width = width } }
    }
    /// The mark being made, until the mouse goes up or, for text, Return.
    @Published private(set) var draft: Annotation?
    /// The text being typed. `draft` holds the text mark's place meanwhile.
    @Published var editingText = "" {
        didSet { if case .text(let origin, _)? = draft?.kind { draft?.kind = .text(origin: origin, string: editingText) } }
    }
    @Published private(set) var isEditingText = false

    var onFinish: ((Finish) -> Void)?
    var onCancel: (() -> Void)?

    private var drag: Drag?
    /// Where the pointer last was, so ⌥ can change the highlight without the pointer moving.
    private var pointer: (point: CGPoint, display: CGDirectDisplayID)?
    /// Whether ⌥ is asking for the whole display rather than the window.
    private var wantsWholeDisplay = false
    /// Frames SwiftUI handles itself, in the active display's points: the text field, while it's up.
    private var chromeFrames: [String: CGRect] = [:]

    init(displays: [CaptureDisplay], accent: Color) {
        self.displays = displays
        self.accent = accent
    }

    var hasSelection: Bool { selection != nil }
    var hoveredWindow: CaptureWindow? { hover?.window }
    var hoveredDisplay: CGDirectDisplayID? { hover?.display }

    func display(_ id: CGDirectDisplayID) -> CaptureDisplay? {
        displays.first { $0.id == id }
    }

    /// The marks to draw: the ones made, plus the one being made unless it's text, which the field shows.
    var visibleDraft: Annotation? {
        isEditingText ? nil : draft
    }

    // MARK: Mouse

    /// `wholeDisplay` is ⌥ being held, which makes a click select the display rather than the window.
    func mouseDown(at point: CGPoint, on displayID: CGDirectDisplayID, wholeDisplay: Bool = false) {
        guard let display = display(displayID) else { return }
        if isEditingText { commitText() }
        if activeDisplay == displayID, let selection {
            if let handle = handle(at: point, in: selection) {
                drag = .resizing(handle, original: selection)
                return
            }
            if let tool {
                if tool.placesOnClick {
                    place(tool, at: point)
                } else {
                    drag = .drawing(start: point)
                    draft = Annotation(kind: Self.kind(for: tool, from: point, to: point), color: color, width: width)
                }
                return
            }
            // A selection that fills the display has nowhere to move to; dragging inside it starts over instead.
            if selection.contains(point), selection != CGRect(origin: .zero, size: display.size) {
                drag = .moving(grip: CGPoint(x: point.x - selection.minX, y: point.y - selection.minY))
                return
            }
        }
        // A new region. Marks belong to the display they were made on, so another display starts clean.
        if activeDisplay != displayID { document.clear() }
        activeDisplay = displayID
        selection = nil
        let start = clamp(point, to: display.size)
        drag = .selecting(start: start, wholeDisplay: wholeDisplay)
        if hover?.display != displayID { setHover(nil) }
        // The highlight stays until the press travels, so a plain click doesn't flash the dim back.
        if hover == nil { rubberBand = CGRect(origin: start, size: .zero) }
    }

    func mouseDragged(to point: CGPoint, on displayID: CGDirectDisplayID) {
        guard let display = display(activeDisplay ?? displayID), let drag else { return }
        let point = clamp(point, to: display.size)
        switch drag {
        case .selecting(let start, _):
            let rect = Self.rect(from: start, to: point)
            if hover != nil, Self.isClick(rect) { return }
            setHover(nil)
            rubberBand = rect
        case .moving(let grip):
            guard let selection else { return }
            // The size stays as it is; only the corner moves, to a whole point.
            var moved = CGRect(origin: CGPoint(x: (point.x - grip.x).rounded(), y: (point.y - grip.y).rounded()), size: selection.size)
            moved.origin.x = min(max(0, moved.minX), display.size.width - moved.width)
            moved.origin.y = min(max(0, moved.minY), display.size.height - moved.height)
            self.selection = moved
        case .resizing(let handle, let original):
            var rect = original
            if handle.movesLeft { rect = CGRect(x: point.x, y: rect.minY, width: original.maxX - point.x, height: rect.height) }
            if handle.movesRight { rect.size.width = point.x - original.minX }
            if handle.movesTop { rect = CGRect(x: rect.minX, y: point.y, width: rect.width, height: original.maxY - point.y) }
            if handle.movesBottom { rect.size.height = point.y - original.minY }
            self.selection = Self.settle(rect, in: display.size)
        case .drawing(let start):
            guard var draft else { return }
            switch draft.kind {
            case .pencil(var points), .marker(var points):
                if let last = points.last, hypot(point.x - last.x, point.y - last.y) < 0.5 { return }
                points.append(point)
                if case .pencil = draft.kind { draft.kind = .pencil(points: points) } else { draft.kind = .marker(points: points) }
            default:
                draft.kind = Self.kind(for: tool ?? .rectangle, from: start, to: point)
            }
            self.draft = draft
        }
    }

    func mouseUp(at point: CGPoint, on displayID: CGDirectDisplayID) {
        guard let display = display(activeDisplay ?? displayID), let drag else { return }
        self.drag = nil
        let point = clamp(point, to: display.size)
        switch drag {
        case .selecting(let start, let wholeDisplay):
            rubberBand = nil
            let rect = Self.rect(from: start, to: point)
            if !Self.isClick(rect) {
                selection = Self.settle(rect, in: display.size)
            } else if !wholeDisplay, let window = frontmostWindow(at: start, on: display) {
                selection = Self.settle(window.frame, in: display.size)
            } else {
                selection = CGRect(origin: .zero, size: display.size)
            }
        case .moving, .resizing:
            break
        case .drawing:
            if let draft { document.add(draft) }
            draft = nil
        }
    }

    /// The pointer moved with nothing pressed, at a point on the desktop in AppKit's coordinates.
    /// The key overlay can hear of moves over another display, so it's the point that says which
    /// display they're on, not who reported them.
    func mouseMoved(toDesktop point: CGPoint, wholeDisplay: Bool = false) {
        guard let display = displays.first(where: { $0.frame.contains(point) }) else { return }
        mouseMoved(to: display.localPoint(fromDesktop: point), on: display.id, wholeDisplay: wholeDisplay)
    }

    /// The pointer moved with nothing pressed, in a display's own points. `wholeDisplay` is ⌥ being held.
    func mouseMoved(to point: CGPoint, on displayID: CGDirectDisplayID, wholeDisplay: Bool = false) {
        guard let display = display(displayID), CGRect(origin: .zero, size: display.size).contains(point) else { return }
        pointer = (point, displayID)
        wantsWholeDisplay = wholeDisplay
        updateHover()
    }

    /// ⌥ went down or up. That comes with no move, and the highlight has to agree with what a click would do.
    func wholeDisplayChanged(_ wholeDisplay: Bool) {
        wantsWholeDisplay = wholeDisplay
        updateHover()
    }

    private func updateHover() {
        guard selection == nil, drag == nil, let pointer, let display = display(pointer.display) else { return }
        if display.windows.isEmpty {
            setHover(nil)
        } else if wantsWholeDisplay {
            setHover(Hover(display: display.id, window: nil))
        } else {
            setHover(frontmostWindow(at: pointer.point, on: display).map { Hover(display: display.id, window: $0) })
        }
    }

    private func setHover(_ new: Hover?) {
        if hover != new { hover = new }
    }

    private func frontmostWindow(at point: CGPoint, on display: CaptureDisplay) -> CaptureWindow? {
        display.windows.first { $0.frame.contains(point) }
    }

    /// The pointer over a display: what it would do there.
    func cursor(at point: CGPoint, on displayID: CGDirectDisplayID) -> NSCursor {
        if let drag {
            switch drag {
            case .moving: return .closedHand
            case .resizing(let handle, _): return handle.cursor
            default: return .crosshair
            }
        }
        guard activeDisplay == displayID, let selection else { return .crosshair }
        if let handle = handle(at: point, in: selection) { return handle.cursor }
        if tool == nil, selection.contains(point) { return .openHand }
        return .crosshair
    }

    /// Whether SwiftUI should get the event: the text field is at this point.
    func isOverChrome(_ point: CGPoint, on displayID: CGDirectDisplayID) -> Bool {
        guard activeDisplay == displayID else { return false }
        if toolbarFrame(on: displayID)?.contains(point) == true { return true }
        return chromeFrames.values.contains { $0.contains(point) }
    }

    func setChromeFrame(_ name: String, _ frame: CGRect?) {
        chromeFrames[name] = frame
    }

    // MARK: Layout

    /// What's highlighted on a display: exactly what a click would select, and what to call it.
    func highlight(on displayID: CGDirectDisplayID) -> (frame: CGRect, label: String)? {
        guard let hover, hover.display == displayID, let display = display(displayID) else { return nil }
        let frame = hover.window.map { Self.settle($0.frame, in: display.size) } ?? CGRect(origin: .zero, size: display.size)
        return (frame, "\(hover.window?.appName ?? "Whole display") · \(Int(frame.width)) × \(Int(frame.height))")
    }

    /// Where the toolbar goes: under the selection, above it when there's no room, inside it as a last resort.
    func toolbarFrame(on displayID: CGDirectDisplayID) -> CGRect? {
        guard activeDisplay == displayID, let selection, let display = display(displayID) else { return nil }
        let size = CaptureToolbar.size
        let margin: CGFloat = 10
        let x = min(max(margin, selection.midX - size.width / 2), display.size.width - size.width - margin)
        let y: CGFloat
        if selection.maxY + margin + size.height <= display.size.height - margin {
            y = selection.maxY + margin
        } else if selection.minY - margin - size.height >= margin {
            y = selection.minY - margin - size.height
        } else {
            y = selection.maxY - margin - size.height
        }
        return CGRect(origin: CGPoint(x: x.rounded(), y: y.rounded()), size: size)
    }

    func handle(at point: CGPoint, in rect: CGRect) -> Handle? {
        let reach = Self.handleSize / 2 + 3
        return Handle.allCases.first { handle in
            let center = handle.point(in: rect)
            return abs(center.x - point.x) <= reach && abs(center.y - point.y) <= reach
        }
    }

    /// Where the toolbar's controls are, by name, in the active display's points. For tests.
    private(set) var controlFrames: [String: CGRect] = [:]

    func setControlFrame(_ name: String, _ frame: CGRect) {
        controlFrames[name] = frame
    }

    // MARK: Marks

    private func place(_ tool: AnnotationTool, at point: CGPoint) {
        switch tool {
        case .counter:
            document.add(Annotation(kind: .counter(center: point, number: document.nextCounter), color: color, width: width))
        case .text:
            editingText = ""
            draft = Annotation(kind: .text(origin: point, string: ""), color: color, width: width)
            isEditingText = true
        default:
            break
        }
    }

    func commitText() {
        guard isEditingText else { return }
        let text = editingText.trimmingCharacters(in: .newlines)
        if let draft, !text.isEmpty, case .text(let origin, _) = draft.kind {
            document.add(Annotation(id: draft.id, kind: .text(origin: origin, string: text), color: draft.color, width: draft.width))
        }
        endText()
    }

    func discardText() {
        guard isEditingText else { return }
        endText()
    }

    private func endText() {
        isEditingText = false
        draft = nil
        editingText = ""
        chromeFrames["text"] = nil
    }

    func undo() { document.undo() }
    func redo() { document.redo() }

    func finish(_ finish: Finish) {
        if isEditingText { commitText() }
        guard hasSelection else { return }
        onFinish?(finish)
    }

    func cancel() {
        onCancel?()
    }

    /// The selection and its marks as one image at the display's scale.
    func render() -> CaptureOutput? {
        guard let activeDisplay, let display = display(activeDisplay), let selection else { return nil }
        let source = CaptureRenderer.Source(image: display.image, scale: display.scale)
        guard let image = CaptureRenderer.compose(source: source, selection: selection, annotations: document.annotations) else { return nil }
        return CaptureOutput(image: image, scale: display.scale, pointSize: selection.size)
    }

    // MARK: Keys

    /// Handles a key press for the editor. Returns false to let it through, which is how typing reaches the text field.
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        let isEscape = event.keyCode == 53
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isEditingText {
            if isEscape {
                discardText()
                return true
            }
            if isReturn {
                if flags.contains(.shift) { editingText += "\n" } else { commitText() }
                return true
            }
            return false
        }
        if isEscape {
            cancel()
            return true
        }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags.contains(.command) {
            switch key {
            case "c": finish(.copy)
            case "s": finish(.save)
            case "z": flags.contains(.shift) ? redo() : undo()
            case "w": cancel()
            default: return false
            }
            return true
        }
        guard flags.isEmpty || flags == .shift else { return false }
        if isReturn {
            finish(Finish(AppSettings.shared.captureAction))
            return true
        }
        if key == "s" {
            tool = nil
            return true
        }
        if key == "o" {
            finish(.copyText)
            return true
        }
        if key == "v" {
            finish(.record)
            return true
        }
        if let picked = AnnotationTool(rawValue: key) {
            tool = picked
            return true
        }
        return false
    }

    // MARK: Snapshots

    /// Puts a selection and marks in place without the mouse, for `--snapshot`.
    func stage(selection: CGRect, on displayID: CGDirectDisplayID, annotations: [Annotation] = []) {
        activeDisplay = displayID
        self.selection = selection.integral
        document.clear()
        annotations.forEach(document.add)
    }

    // MARK: Geometry

    private static func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    private static func isClick(_ rect: CGRect) -> Bool {
        rect.width < clickSlop && rect.height < clickSlop
    }

    /// Whole points, at least a point each way, inside the display.
    private static func settle(_ rect: CGRect, in size: CGSize) -> CGRect {
        var rect = rect.standardized.integral.intersection(CGRect(origin: .zero, size: size))
        if rect.isNull || rect.isEmpty {
            rect = CGRect(x: min(max(0, rect.minX.isNaN ? 0 : rect.minX), size.width - 1),
                          y: min(max(0, rect.minY.isNaN ? 0 : rect.minY), size.height - 1), width: 1, height: 1)
        }
        rect.size.width = max(1, rect.width)
        rect.size.height = max(1, rect.height)
        return rect
    }

    private func clamp(_ point: CGPoint, to size: CGSize) -> CGPoint {
        CGPoint(x: min(max(0, point.x), size.width), y: min(max(0, point.y), size.height))
    }

    private static func kind(for tool: AnnotationTool, from start: CGPoint, to end: CGPoint) -> Annotation.Kind {
        switch tool {
        case .pencil: .pencil(points: [start])
        case .marker: .marker(points: [start])
        case .line: .line(from: start, to: end)
        case .arrow: .arrow(from: start, to: end)
        case .rectangle: .rectangle(rect(from: start, to: end))
        case .ellipse: .ellipse(rect(from: start, to: end))
        case .blur: .blur(rect(from: start, to: end))
        case .text: .text(origin: start, string: "")
        case .counter: .counter(center: start, number: 1)
        }
    }
}

/// A finished capture: its pixels, the scale they were taken at, and its size in points.
struct CaptureOutput {
    let image: CGImage
    let scale: CGFloat
    let pointSize: CGSize
}

// MARK: - Views

/// The outline, the handles and the size label around the selection.
struct SelectionChrome: View {
    let selection: CGRect
    let accent: Color
    let displaySize: CGSize
    @Environment(\.notchTheme) private var theme

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .stroke(accent, lineWidth: 1)
                .frame(width: selection.width, height: selection.height)
                .position(x: selection.midX, y: selection.midY)
            ForEach(Array(CaptureEditor.Handle.allCases.enumerated()), id: \.offset) { _, handle in
                let point = handle.point(in: selection)
                // White squares ringed in the accent, over whatever the capture holds.
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(accent, lineWidth: 1.5))
                    .frame(width: CaptureEditor.handleSize, height: CaptureEditor.handleSize)
                    .position(x: point.x, y: point.y)
            }
            sizeLabel
        }
        .frame(width: displaySize.width, height: displaySize.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// "640 × 400" on a block of the accent, above the selection's top-left corner, or just inside
    /// it at the top of the display.
    private var sizeLabel: some View {
        let fitsAbove = selection.minY >= 26
        return Text("\(Int(selection.width)) × \(Int(selection.height))")
            .font(NotchFont.time(11.5, .medium))
            .foregroundStyle(theme.onAccent)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(theme.controlShape.fill(accent))
            .fixedSize()
            .offset(x: max(4, selection.minX + (fitsAbove ? 0 : 6)), y: fitsAbove ? selection.minY - 24 : selection.minY + 6)
            .accessibilityLabel("Selection \(Int(selection.width)) by \(Int(selection.height))")
    }
}

/// What a click would select: a 2-point outline around the window, or the display, and a label.
struct HoverChrome: View {
    let frame: CGRect
    let label: String
    let accent: Color
    let displaySize: CGSize
    @Environment(\.notchTheme) private var theme

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Inside the edge, so it stays whole around a window or a display that reaches the side of the screen.
            Rectangle()
                .strokeBorder(accent, lineWidth: 2)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
            labelView
        }
        .frame(width: displaySize.width, height: displaySize.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// Above the top-left corner, or just inside it at the top of the display, like the size label.
    /// How wide it is only layout knows, so a guide keeps it off the display's right edge.
    private var labelView: some View {
        let fitsAbove = frame.minY >= 26
        let x = frame.minX + (fitsAbove ? 0 : 6)
        let y = fitsAbove ? frame.minY - 24 : frame.minY + 6
        return Text(verbatim: label)
            .font(NotchFont.time(11.5, .medium))
            .lineLimit(1)
            .foregroundStyle(theme.onAccent)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(theme.controlShape.fill(accent))
            .fixedSize()
            .alignmentGuide(.leading) { size in -max(4, min(x, displaySize.width - size.width - 4)) }
            .alignmentGuide(.top) { _ in -y }
            .accessibilityLabel(label)
    }
}

/// The marks, drawn by the same code that makes the finished image.
struct AnnotationLayer: View {
    @ObservedObject var editor: CaptureEditor
    @ObservedObject var document: AnnotationDocument
    let display: CaptureDisplay

    var body: some View {
        let marks = document.annotations + (editor.visibleDraft.map { [$0] } ?? [])
        let source = CaptureRenderer.Source(image: display.image, scale: display.scale)
        Canvas(rendersAsynchronously: false) { context, _ in
            context.withCGContext { cgContext in
                CaptureRenderer.draw(marks, in: cgContext, source: source)
            }
        }
        .frame(width: display.size.width, height: display.size.height)
        .allowsHitTesting(false)
    }
}

/// The field a text mark is typed into, at the mark's place and in its font and color.
struct TextAnnotationField: View {
    @ObservedObject var editor: CaptureEditor
    let origin: CGPoint
    let displaySize: CGSize
    @FocusState private var isFocused: Bool

    private var font: NSFont { .systemFont(ofSize: Annotation.fontSize(for: editor.width), weight: .medium) }

    /// Wide enough for the longest line so far, so nothing wraps and the mark comes out as typed.
    private var fieldWidth: CGFloat {
        let longest = editor.editingText.split(separator: "\n", omittingEmptySubsequences: false)
            .map { NSAttributedString(string: String($0), attributes: [.font: font]).size().width }.max() ?? 0
        return min(max(60, longest.rounded(.up) + 20), max(60, displaySize.width - origin.x))
    }

    var body: some View {
        TextField("", text: $editor.editingText, axis: .vertical)
            .textFieldStyle(.plain)
            .font(Font(font))
            .foregroundStyle(editor.color.color)
            .lineLimit(1...20)
            .focused($isFocused)
            .frame(width: fieldWidth, alignment: .leading)
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(editor.accent.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { editor.setChromeFrame("text", proxy.frame(in: .named("overlay"))) }
                    .onChange(of: proxy.size) { editor.setChromeFrame("text", proxy.frame(in: .named("overlay"))) }
            })
            // The field's text sits a few points in from its frame; line it up with where the mark will be drawn.
            .offset(x: origin.x - 4, y: origin.y - 5)
            .onAppear { isFocused = true }
            .accessibilityLabel("Text")
    }
}

/// A hint in the middle of each display until something's selected. With no windows listed for
/// the display, a click there can only select all of it, so the hint says that instead.
struct SelectionHint: View {
    var hasWindows = false
    /// A highlighted window can lie under it, at full brightness. The panel's surface is opaque, so
    /// it reads the same either way.
    var isOverCapture = false
    @Environment(\.notchTheme) private var theme

    var body: some View {
        Text(hasWindows ? "Drag to select a region  ·  Click a window  ·  ⌥-click for the whole display  ·  Esc to cancel"
                        : "Drag to select a region  ·  Click for the whole display  ·  Esc to cancel")
            .font(NotchFont.body)
            .foregroundStyle(theme.primary)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(CaptureSurface(shape: theme.controlShape))
            .allowsHitTesting(false)
    }
}

/// What the capture's chrome stands on: the open notch's flat surface, in light or dark as the
/// notch is, with its hairline.
private struct CaptureSurface<S: InsettableShape>: View {
    let shape: S
    @Environment(\.notchTheme) private var theme

    var body: some View {
        ZStack {
            shape.fill(theme.background)
            shape.strokeBorder(theme.line, lineWidth: 1)
        }
    }
}

// MARK: Toolbar

/// The tools, colors and width, with undo and the actions, beside the selection. It's a fixed
/// size so the editor can place it and know where it is. A strip of the panel's flat surface: the
/// near-square tools on top, the one in hand a solid block of the accent, and under them the colors,
/// the width and what to do with the capture, Copy the focus button.
struct CaptureToolbar: View {
    static let size = CGSize(width: 700, height: 88)

    @ObservedObject var editor: CaptureEditor
    @ObservedObject var document: AnnotationDocument
    /// When there's no room beside the selection, the toolbar sits on it. Its surface is opaque, so
    /// it reads the same either way.
    var isOverCapture = false
    @Environment(\.notchTheme) private var theme

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 2) {
                ToolbarButton(symbol: "cursorarrow", title: "Select", key: "S", isSelected: editor.tool == nil, editor: editor) {
                    editor.tool = nil
                }
                ForEach(AnnotationTool.allCases) { tool in
                    ToolbarButton(symbol: tool.symbol, title: tool.title, key: tool.rawValue.uppercased(),
                                  isSelected: editor.tool == tool, editor: editor) {
                        editor.tool = tool
                    }
                }
                ToolbarDivider()
                ToolbarButton(symbol: "arrow.uturn.backward", title: "Undo", key: "⌘Z", isEnabled: document.canUndo, editor: editor) {
                    editor.undo()
                }
                ToolbarButton(symbol: "arrow.uturn.forward", title: "Redo", key: "⇧⌘Z", isEnabled: document.canRedo, editor: editor) {
                    editor.redo()
                }
                ToolbarDivider()
                ToolbarButton(symbol: "record.circle", title: "Record", key: "V", tint: theme.alert, editor: editor) { editor.finish(.record) }
                ToolbarButton(symbol: "text.viewfinder", title: "Copy Text", key: "O", editor: editor) { editor.finish(.copyText) }
                Spacer(minLength: 0)
                RecordFormatPicker(editor: editor)
                ToolbarDivider()
                ToolbarButton(symbol: "xmark", title: "Close", key: "Esc", editor: editor) { editor.cancel() }
            }
            HStack(spacing: 6) {
                HStack(spacing: 0) {
                    ForEach(AnnotationColor.allCases) { swatch in
                        ColorSwatch(color: swatch, isSelected: editor.color == swatch, editor: editor) { editor.color = swatch }
                    }
                }
                ToolbarDivider()
                WidthSlider(value: $editor.width)
                    .reportingFrame("Width", to: editor)
                Text("\(Int(editor.width)) pt")
                    .font(NotchFont.time(11, .medium))
                    .foregroundStyle(theme.secondary)
                    .frame(width: 34, alignment: .trailing)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                ToolbarTextButton(title: "Pin", style: .ghost, help: "Pin it above every window", editor: editor) { editor.finish(.pin) }
                ToolbarTextButton(title: "Add to Tray", help: "Add to Tray", editor: editor) { editor.finish(.addToTray) }
                ToolbarTextButton(title: "Save", help: "Save (⌘S)", editor: editor) { editor.finish(.save) }
                Button { editor.finish(.copy) } label: {
                    CopyButtonLabel(editor: editor)
                }
                .buttonStyle(PressableButtonStyle(scale: 0.96))
                .help("Copy (⌘C)")
                .accessibilityLabel("Copy")
                .accessibilityIdentifier("capture.Copy")
                .reportingFrame("Copy", to: editor)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(width: Self.size.width, height: Self.size.height)
        .background {
            let shape = RoundedRectangle(cornerRadius: theme.radius + 6, style: .continuous)
            CaptureSurface(shape: shape)
                .shadow(color: .black.opacity(theme.isDark ? 0.45 : 0.18), radius: 18, y: 8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Capture tools")
    }
}

/// Copy's focus button, with ⌘C after its name.
private struct CopyButtonLabel: View {
    let editor: CaptureEditor
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        FocusButtonLabel(title: "Copy ⌘C", height: 28, hovering: hovering)
            .onHover { hovering = $0 }
            .animation(.notchHighlight, value: hovering)
    }
}

/// A worded button in the toolbar's second row: Pin, Add to Tray, Save.
private struct ToolbarTextButton: View {
    enum Style { case plain, ghost }

    let title: String
    var style: Style = .plain
    let help: String
    let editor: CaptureEditor
    let action: () -> Void
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(NotchFont.bodyStrong)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(style == .ghost && !hovering ? theme.secondary : theme.primary)
                .padding(.horizontal, 11)
                .frame(height: 28)
                .background {
                    if style == .plain || hovering {
                        theme.controlShape.fill(hovering ? theme.controlHover : theme.hover)
                    }
                }
                .contentShape(theme.controlShape)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.96))
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .help(help)
        .accessibilityLabel(title)
        .accessibilityIdentifier("capture.\(title)")
        .reportingFrame(title, to: editor)
    }
}

private struct ToolbarButton: View {
    let symbol: String
    let title: String
    var key: String?
    var isSelected = false
    var isEnabled = true
    /// A color of its own, for Record.
    var tint: Color?
    let editor: CaptureEditor
    let action: () -> Void
    @ViewState private var hovering = false
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let shape = theme.controlShape
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? theme.onAccent : tint ?? (isEnabled ? (hovering ? theme.primary : theme.secondary) : theme.tertiary.opacity(0.5)))
                .frame(width: 30, height: 30)
                .background {
                    if isSelected {
                        shape.fill(editor.accent)
                    } else if hovering && isEnabled {
                        shape.fill(theme.hover)
                    }
                }
                // The key that picks a tool, small in its corner, as the board draws it.
                .overlay(alignment: .bottomTrailing) {
                    if let key, key.count == 1 {
                        Text(key)
                            .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(isSelected ? theme.onAccent.opacity(0.8) : theme.tertiary)
                            .padding(.trailing, 2)
                            .padding(.bottom, 1)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.92))
        .disabled(!isEnabled)
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .animation(.notchToggle, value: isSelected)
        .help(key.map { "\(title) (\($0))" } ?? title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("capture.\(title)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .reportingFrame(title, to: editor)
    }
}

private extension View {
    /// Tells the editor where a control is, so a test can click it.
    func reportingFrame(_ name: String, to editor: CaptureEditor) -> some View {
        background(GeometryReader { proxy in
            let frame = proxy.frame(in: .named("overlay"))
            Color.clear
                .onAppear { editor.setControlFrame(name, frame) }
                .onChange(of: frame) { editor.setControlFrame(name, frame) }
        })
    }
}

/// What Record makes, MP4 or GIF. The same choice as in Settings → Tray. An Orbit segmented control:
/// the one picked a solid block of the panel's raised shade.
private struct RecordFormatPicker: View {
    let editor: CaptureEditor
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.notchTheme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(RecordFormat.allCases) { format in
                let isSelected = settings.recordFormat == format
                Button { settings.recordFormat = format } label: {
                    Text(format.title)
                        .font(NotchFont.time(11, .semibold))
                        .foregroundStyle(isSelected ? theme.primary : theme.secondary)
                        .frame(width: 38, height: 24)
                        .background {
                            if isSelected {
                                theme.controlShape.fill(theme.raised)
                                    .overlay(theme.controlShape.strokeBorder(theme.line))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle(scale: 0.95))
                .help("Record as \(format.title)")
                .accessibilityLabel("Record as \(format.title)")
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                .reportingFrame(format.title, to: editor)
            }
        }
        .padding(2)
        .background(theme.controlShape.fill(theme.hover))
    }
}

/// A hairline between groups.
private struct ToolbarDivider: View {
    @Environment(\.notchTheme) private var theme

    var body: some View {
        theme.line
            .frame(width: 1, height: 22)
            .padding(.horizontal, 6)
            .accessibilityHidden(true)
    }
}

private struct ColorSwatch: View {
    let color: AnnotationColor
    let isSelected: Bool
    let editor: CaptureEditor
    let action: () -> Void
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: max(2, theme.radius * 0.8), style: .continuous)
        Button(action: action) {
            // A flat square of the color, ringed in the panel's text color while it's the one in use.
            shape.fill(color.color)
                .overlay(shape.strokeBorder(theme.line))
                .frame(width: 16, height: 16)
                .padding(2)
                .overlay(
                    RoundedRectangle(cornerRadius: max(3, theme.radius * 0.8 + 2), style: .continuous)
                        .strokeBorder(theme.primary, lineWidth: isSelected ? 1.5 : 0)
                )
                .padding(1)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .help(color.title)
        .accessibilityLabel(color.title)
        .accessibilityIdentifier("capture.color.\(color.rawValue)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .reportingFrame(color.title, to: editor)
    }
}

/// The stroke width, 1 to 16 points: a flat track that fills with the accent and a square knob,
/// like Orbit's sliders.
private struct WidthSlider: View {
    @Binding var value: CGFloat
    private let range: ClosedRange<CGFloat> = 1...16
    private let knob: CGFloat = 12
    @Environment(\.notchTheme) private var theme

    var body: some View {
        GeometryReader { proxy in
            let travel = max(1, proxy.size.width - knob)
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let track = RoundedRectangle(cornerRadius: min(theme.radius, 2), style: .continuous)
            ZStack(alignment: .leading) {
                track.fill(theme.hover).frame(height: 4)
                track.fill(theme.accent).frame(width: knob / 2 + travel * fraction, height: 4)
                RoundedRectangle(cornerRadius: min(theme.radius, 3), style: .continuous)
                    .fill(theme.raised)
                    .overlay(RoundedRectangle(cornerRadius: min(theme.radius, 3), style: .continuous).strokeBorder(theme.edge, lineWidth: 1))
                    .frame(width: knob, height: knob)
                    .offset(x: travel * fraction)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let fraction = min(max((drag.location.x - knob / 2) / travel, 0), 1)
                let stepped = (range.lowerBound + fraction * (range.upperBound - range.lowerBound)).rounded()
                if stepped != value { value = stepped }
            })
        }
        .frame(width: 90, height: 28)
        .accessibilityRepresentation {
            Slider(value: $value, in: range, step: 1) { Text("Width") }
                .accessibilityValue("\(Int(value)) points")
        }
        .accessibilityIdentifier("capture.width")
    }
}
