import AppKit

/// A thin line around the region while it records, so it's clear what's being recorded. It's
/// Dynotch's own window, so the stream's filter keeps it out of the video. Clicks go through it,
/// and it never takes the keyboard.
final class RecordingOutline: NSPanel {
    /// Just outside the region, so it's never in the way of what's recorded.
    static let lineWidth: CGFloat = 2
    /// Off screen for a test, where a recording is made up.
    static let parkedOrigin = NSPoint(x: -24_000, y: -74_000)

    init(around region: CGRect, isParked: Bool) {
        var frame = region.insetBy(dx: -Self.lineWidth, dy: -Self.lineWidth)
        if isParked { frame.origin = Self.parkedOrigin }
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        let line = NSView(frame: NSRect(origin: .zero, size: frame.size))
        line.autoresizingMask = [.width, .height]
        line.wantsLayer = true
        line.layer?.borderColor = NSColor.systemRed.cgColor
        line.layer?.borderWidth = Self.lineWidth
        contentView = line
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Where it's told, which may be past the edge of a screen: the region can touch the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
