import CoreGraphics
import Foundation
import ScreenCaptureKit

/// A window on a frozen display, as it stood when the display froze.
struct CaptureWindow: Equatable {
    let id: CGWindowID
    /// The app's name, which the highlight shows.
    let appName: String
    /// In the display's own points, with the origin at its top-left corner, clipped to the display.
    let frame: CGRect
}

/// Works out which windows a capture can snap to on a display, and in what order. ScreenCaptureKit
/// says what's there and the Window Server says who's in front, and `windows(on:listed:stack:ownProcess:)`
/// puts the two together in plain values, so tests can drive it without either.
enum CaptureWindowList {
    /// A window as ScreenCaptureKit lists it.
    struct Listed {
        let id: CGWindowID
        let appName: String
        let bundleID: String
        let processID: pid_t
        /// On the desktop, with the origin at the top-left of the main display.
        let frame: CGRect
        let layer: Int
    }

    /// A window's place in the Window Server's stack.
    struct Stacked {
        let id: CGWindowID
        let alpha: CGFloat
    }

    /// Normal windows are at 0, an app's floating ones at 3 and its modal ones at 8. Below that is
    /// the desktop, and above it the Dock, the menu bar and the rest of the system.
    private static let appLayers = 0...8
    /// Under this either way a window is a badge or a sliver, not something to capture.
    private static let smallestSide: CGFloat = 40
    /// Names without their spaces, as the same app shows up both ways.
    private static let systemApps: Set<String> = ["windowserver", "dock", "systemuiserver", "controlcenter",
                                                  "notificationcenter", "windowmanager", "wallpaper", "loginwindow"]
    /// The same apps by identifier, in case a Mac in another language translates the names above.
    private static let systemBundles: Set<String> = ["com.apple.dock", "com.apple.systemuiserver", "com.apple.controlcenter",
                                                     "com.apple.notificationcenterui", "com.apple.WindowManager",
                                                     "com.apple.wallpaper.agent", "com.apple.loginwindow"]

    /// The windows on a display, frontmost first, in its own points and clipped to it. `display` is
    /// its place on the desktop from `CGDisplayBounds`, whose origin is the same as a window frame's.
    ///
    /// `listed` is what counts and `stack` is the order. The order `SCShareableContent` lists its
    /// windows in isn't documented, so a window with no place in the stack is left out: it has
    /// closed since, or the stack couldn't be read, and guessing could pick the window behind.
    static func windows(on display: CGRect, listed: [Listed], stack: [Stacked], ownProcess: pid_t) -> [CaptureWindow] {
        var places: [CGWindowID: (index: Int, alpha: CGFloat)] = [:]
        for (index, window) in stack.enumerated() where places[window.id] == nil {
            places[window.id] = (index, window.alpha)
        }
        let found = listed.compactMap { window -> (place: Int, window: CaptureWindow)? in
            // The size is the whole window's, so a big one that only just reaches onto a display still counts there.
            guard let place = places[window.id], place.alpha > 0,
                  window.processID != ownProcess,
                  appLayers.contains(window.layer),
                  window.frame.width >= smallestSide, window.frame.height >= smallestSide,
                  !window.appName.isEmpty,
                  !systemApps.contains(window.appName.filter { !$0.isWhitespace }.lowercased()),
                  !systemBundles.contains(window.bundleID)
            else { return nil }
            let visible = window.frame.intersection(display)
            guard !visible.isNull, !visible.isEmpty else { return nil }
            let frame = visible.offsetBy(dx: -display.minX, dy: -display.minY)
            return (place.index, CaptureWindow(id: window.id, appName: window.appName, frame: frame))
        }
        return found.sorted { $0.place < $1.place }.map(\.window)
    }

    // MARK: Reading them

    /// `content.windows` as plain values. A window with no app gets no name, and so doesn't count.
    static func listed(_ windows: [SCWindow]) -> [Listed] {
        windows.map { window in
            Listed(id: window.windowID, appName: window.owningApplication?.applicationName ?? "",
                   bundleID: window.owningApplication?.bundleIdentifier ?? "",
                   processID: window.owningApplication?.processID ?? 0, frame: window.frame, layer: window.windowLayer)
        }
    }

    /// The on-screen windows right now, front to back as CGWindow.h promises for this option. It
    /// needs no Screen Recording. Empty if it can't be read, and then there's nothing to snap to.
    static func currentStack() -> [Stacked] {
        stack(from: CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
    }

    /// The entries of a window list, in their order.
    static func stack(from entries: [[String: Any]]) -> [Stacked] {
        entries.compactMap { entry in
            guard let number = entry[kCGWindowNumber as String] as? NSNumber else { return nil }
            let alpha = entry[kCGWindowAlpha as String] as? NSNumber
            return Stacked(id: number.uint32Value, alpha: CGFloat(alpha?.doubleValue ?? 1))
        }
    }
}
