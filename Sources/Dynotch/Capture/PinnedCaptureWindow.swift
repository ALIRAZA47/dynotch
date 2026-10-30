import AppKit
import SwiftUI

/// A capture floating above every window, to keep in view while you work. Drag it anywhere;
/// Esc, ⌘W or the close glyph that appears under the pointer puts it away. Any number can be up.
@MainActor
final class PinnedCaptureWindow: NSPanel {
    private static var pinned: [PinnedCaptureWindow] = []

    /// Shows a capture where it was taken, or on the main display, at its point size. One larger than a
    /// quarter of the display is scaled down to fit that.
    @discardableResult
    static func pin(_ output: CaptureOutput, near rect: CGRect?) -> PinnedCaptureWindow {
        let screen = rect.flatMap { rect in NSScreen.screens.first { $0.frame.intersects(rect) } } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let limit = CGSize(width: visible.width / 2, height: visible.height / 2)
        var size = output.pointSize
        let shrink = min(1, limit.width / max(1, size.width), limit.height / max(1, size.height))
        size = CGSize(width: (size.width * shrink).rounded(), height: (size.height * shrink).rounded())
        let center = rect.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: visible.midX, y: visible.midY)
        var origin = CGPoint(x: (center.x - size.width / 2).rounded(), y: (center.y - size.height / 2).rounded())
        origin.x = min(max(visible.minX, origin.x), max(visible.minX, visible.maxX - size.width))
        origin.y = min(max(visible.minY, origin.y), max(visible.minY, visible.maxY - size.height))
        let window = PinnedCaptureWindow(output: output, frame: CGRect(origin: origin, size: size))
        pinned.append(window)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    static var all: [PinnedCaptureWindow] { pinned }

    init(output: CaptureOutput, frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        let image = NSImage(cgImage: output.image, size: output.pointSize)
        let host = PinnedHostingView(rootView: PinnedCaptureView(image: image, close: { [weak self] in self?.dismiss() }))
        host.sizingOptions = []
        contentView = host
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { dismiss() }
    }

    /// ⌘W, which the main menu's Close would otherwise refuse for a window with no close button.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
            dismiss()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func dismiss() {
        orderOut(nil)
        close()
        Self.pinned.removeAll { $0 === self }
    }
}

private final class PinnedHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// A drag anywhere on the picture moves the window.
    override var mouseDownCanMoveWindow: Bool { true }
}

/// The capture with square corners, which keep all of it, and an edge that catches the light along
/// the top. Under the pointer, a close button sits in its corner: a disc of dark glass.
private struct PinnedCaptureView: View {
    let image: NSImage
    let close: () -> Void
    @ViewState private var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast

    /// The notch's light, for the close button's glass, its lit edge a step brighter with Increase Contrast.
    private var theme: NotchTheme {
        var theme = NotchTheme.standard
        theme.isHighContrast = contrast == .increased
        return theme
    }

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .overlay(Rectangle().strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.06)],
                                                             startPoint: .top, endPoint: .bottom)))
            .overlay(alignment: .topTrailing) {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background {
                            // Dark enough for the white glyph over any capture, lit like the notch's controls.
                            Circle().fill(Color.black.opacity(0.6))
                                .overlay(Circle().fill(LinearGradient(colors: [.white.opacity(theme.sheen(.control)), .clear],
                                                                      startPoint: .top, endPoint: .center)))
                                .overlay(Circle().strokeBorder(theme.rim(.control)))
                        }
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .padding(6)
                        .contentShape(Circle())
                }
                .buttonStyle(PressableButtonStyle())
                .opacity(hovering ? 1 : 0)
                .animation(.notchHighlight, value: hovering)
                .help("Close (Esc)")
                .accessibilityLabel("Close")
            }
            .onHover { hovering = $0 }
            .accessibilityLabel("Pinned capture")
    }
}
