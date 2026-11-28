import AppKit

// The Nook's stack of widgets, one card at a time, is gone: Orbit's Widgets section shows the
// picked widgets side by side (`WidgetsSection`). What's left is the marker the window controller
// looks for before turning a stack with a vertical swipe. Nothing puts one on screen now, so
// swipes over the widgets do what swipes do elsewhere in the open notch.

/// Takes no events: it's only there to be found.
final class StackSwipeAreaView: NSView {
    private static let all = NSHashTable<StackSwipeAreaView>.weakObjects()

    override init(frame: NSRect) {
        super.init(frame: frame)
        Self.all.add(self)
    }

    required init?(coder: NSCoder) { nil }

    /// A stack is on screen at `point` in `window`.
    static func covers(_ point: CGPoint, in window: NSWindow) -> Bool {
        all.allObjects.contains { view in
            view.window === window && !view.isHiddenOrHasHiddenAncestor
                && window.convertToScreen(view.convert(view.bounds, to: nil)).contains(point)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
