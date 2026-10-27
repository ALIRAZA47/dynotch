import AppKit

/// Where the notch sits on a screen and how big the closed notch is.
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var closedSize: CGSize
    var hasHardwareNotch: Bool

    static func make(for screen: NSScreen, virtualWidth: CGFloat) -> NotchGeometry {
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return NotchGeometry(screenFrame: screen.frame,
                                 closedSize: CGSize(width: width, height: screen.safeAreaInsets.top),
                                 hasHardwareNotch: true)
        }
        // No notch: draw one that hangs from the menu bar, or from the top edge when it's hidden.
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        let height = menuBar > 0 ? min(max(menuBar, 22), 32) : 26
        return NotchGeometry(screenFrame: screen.frame,
                             closedSize: CGSize(width: virtualWidth, height: height),
                             hasHardwareNotch: false)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    var hasNotch: Bool {
        safeAreaInsets.top > 0 && auxiliaryTopLeftArea != nil
    }
}
