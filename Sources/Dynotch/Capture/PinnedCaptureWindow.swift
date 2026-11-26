import AppKit
import SwiftUI

/// A capture floating above every window, to keep in view while you work. Drag it anywhere;
/// Esc, ⌘W or the close glyph that appears under the pointer puts it away. Any number can be up.
@MainActor
final class PinnedCaptureWindow: NSPanel {
    private static var pinned: [PinnedCaptureWindow] = []

    /// Shows a capture where it was taken, or on the main display, at its point size. One larger than a
    /// quarter of the display is scaled down to fit that. A test's stays off screen, `isParked`, and
    /// leaves the keyboard alone.
    @discardableResult
    static func pin(_ output: CaptureOutput, near rect: CGRect?, isParked: Bool = false) -> PinnedCaptureWindow {
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
        if isParked { origin = CGPoint(x: -30_000, y: -70_000) }
        let window = PinnedCaptureWindow(output: output, frame: CGRect(origin: origin, size: size))
        pinned.append(window)
        if isParked {
            window.orderFrontRegardless()
        } else {
            window.makeKeyAndOrderFront(nil)
        }
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

/// The capture with square corners, which keep all of it, and a hairline round it. Under the
/// pointer, a close button sits in its corner: a square of the open notch's flat surface.
private struct PinnedCaptureView: View {
    let image: NSImage
    let close: () -> Void
    @ViewState private var hovering = false
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.colorSchemeContrast) private var contrast

    /// The open notch's look, light or dark as Settings and the system say.
    private var theme: NotchTheme {
        var theme = AppSettings.shared.theme(systemIsDark: systemScheme == .dark)
        theme.isHighContrast = contrast == .increased
        return theme
    }

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .overlay(Rectangle().strokeBorder(theme.line, lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(theme.primary)
                        .frame(width: 24, height: 24)
                        .background(theme.controlShape.fill(theme.background))
                        .overlay(theme.controlShape.strokeBorder(theme.edge, lineWidth: 1))
                        .padding(6)
                        .contentShape(Rectangle())
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
