import AppKit
import SwiftUI

/// A borderless window over one display while a capture is taken. It shows the display's frozen
/// image under the editor, takes the keyboard without activating the app, and hands the editor
/// every mouse event that isn't over the toolbar or the text field, which SwiftUI handles.
final class CaptureOverlayWindow: NSPanel {
    let display: CaptureDisplay
    private let editor: CaptureEditor

    private enum DragTarget {
        /// SwiftUI's: the toolbar or the text field.
        case chrome
        /// The editor's: the selection or a mark.
        case capture
    }

    /// Where the drag in progress began, so it stays with that until the mouse goes up.
    private var dragTarget: DragTarget?

    init(display: CaptureDisplay, editor: CaptureEditor) {
        self.display = display
        self.editor = editor
        super.init(contentRect: display.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Above every window, the menu bar and the Dock included, as screenshot tools sit.
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        let host = CaptureHostingView(rootView: CaptureOverlayView(display: display, editor: editor))
        host.sizingOptions = []
        contentView = host
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The window covers the display, menu bar and all, or sits off screen for a snapshot.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            let point = localPoint(event)
            if editor.isOverChrome(point, on: display.id) {
                dragTarget = .chrome
                super.sendEvent(event)
            } else {
                dragTarget = .capture
                if !isKeyWindow { makeKey() }
                editor.mouseDown(at: point, on: display.id)
                editor.cursor(at: point, on: display.id).set()
            }
        case .leftMouseDragged:
            if dragTarget == .chrome {
                super.sendEvent(event)
            } else {
                editor.mouseDragged(to: localPoint(event), on: display.id)
            }
        case .leftMouseUp:
            if dragTarget == .chrome {
                super.sendEvent(event)
            } else {
                let point = localPoint(event)
                editor.mouseUp(at: point, on: display.id)
                editor.cursor(at: point, on: display.id).set()
            }
            dragTarget = nil
        case .mouseMoved:
            // SwiftUI gets it too, for the toolbar's hover highlights.
            super.sendEvent(event)
            let point = localPoint(event)
            (editor.isOverChrome(point, on: display.id) ? NSCursor.arrow : editor.cursor(at: point, on: display.id)).set()
        case .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            break
        default:
            super.sendEvent(event)
        }
    }

    /// Keys the editor and the text field didn't take end here. Not a beep.
    override func keyDown(with event: NSEvent) {}

    /// The event's place in the display's points, origin at the top-left.
    private func localPoint(_ event: NSEvent) -> CGPoint {
        let location = event.locationInWindow
        return CGPoint(x: location.x, y: frame.height - location.y)
    }
}

/// Takes the first click, as the app is never active, and asks for mouse moves whether or not the
/// window is key, so the cursor and the toolbar's hover highlights follow the pointer.
private final class CaptureHostingView<Content: View>: NSHostingView<Content> {
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }
}

/// One display's part of the capture: its frozen image dimmed except for the selection, the marks,
/// the selection's outline and handles, the toolbar and the text field.
struct CaptureOverlayView: View {
    let display: CaptureDisplay
    @ObservedObject var editor: CaptureEditor

    var body: some View {
        let isActive = editor.activeDisplay == display.id
        let selection = isActive ? editor.selection : nil
        let hole = selection ?? (isActive ? editor.rubberBand : nil)
        ZStack(alignment: .topLeading) {
            Image(decorative: display.image, scale: display.scale)
                .resizable()
                .frame(width: display.size.width, height: display.size.height)
            DimLayer(size: display.size, hole: hole)
            if let hole, selection == nil {
                Rectangle()
                    .stroke(editor.accent, lineWidth: 1)
                    .frame(width: hole.width, height: hole.height)
                    .position(x: hole.midX, y: hole.midY)
                    .allowsHitTesting(false)
            }
            if isActive {
                AnnotationLayer(editor: editor, document: editor.document, display: display)
            }
            if let selection {
                SelectionChrome(selection: selection, accent: editor.accent, displaySize: display.size)
                if let frame = editor.toolbarFrame(on: display.id) {
                    CaptureToolbar(editor: editor, document: editor.document)
                        .offset(x: frame.minX, y: frame.minY)
                }
                if editor.isEditingText, let draft = editor.draft, case .text(let origin, _) = draft.kind {
                    TextAnnotationField(editor: editor, origin: origin, displaySize: display.size)
                }
            }
            if editor.selection == nil, editor.rubberBand == nil {
                SelectionHint()
                    .position(x: display.size.width / 2, y: display.size.height / 2)
            }
        }
        .frame(width: display.size.width, height: display.size.height, alignment: .topLeading)
        .coordinateSpace(name: "overlay")
        .environment(\.colorScheme, .dark)
    }
}

/// Dims the display to about forty percent, leaving the selection, or the region being dragged out, as it was.
private struct DimLayer: View {
    let size: CGSize
    let hole: CGRect?

    var body: some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: size))
            if let hole, !hole.isEmpty { path.addRect(hole) }
        }
        .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}
