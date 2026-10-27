import AppKit

/// Shows the built-in display's brightness in the notch when the brightness keys are pressed.
/// There's no public API to read it on Apple silicon, so this uses DisplayServices when it's there
/// and stays quiet when it isn't. With the system HUD replaced, it sets the brightness too.
@MainActor
final class BrightnessMonitor {
    static let shared = BrightnessMonitor()

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanChangeBrightness = @convention(c) (CGDirectDisplayID) -> Bool
    private var getBrightness: GetBrightness?
    private var setBrightness: SetBrightness?
    private var canChangeBrightness: CanChangeBrightness?
    private var monitor: Any?

    // From IOKit's ev_keymap.h.
    private static let brightnessUpKey = 2
    private static let brightnessDownKey = 3
    private static let auxControlButtonsSubtype: Int16 = 8

    private init() {}

    func start() {
        if let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY) {
            if let symbol = dlsym(handle, "DisplayServicesGetBrightness") {
                getBrightness = unsafeBitCast(symbol, to: GetBrightness.self)
            }
            if let symbol = dlsym(handle, "DisplayServicesSetBrightness") {
                setBrightness = unsafeBitCast(symbol, to: SetBrightness.self)
            }
            if let symbol = dlsym(handle, "DisplayServicesCanChangeBrightness") {
                canChangeBrightness = unsafeBitCast(symbol, to: CanChangeBrightness.self)
            }
        }
        guard getBrightness != nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    // MARK: Changing the brightness

    /// The brightness keys would change the built-in display, which Dynotch can set. With the pointer
    /// on another display, or the lid closed, the keys are left to macOS.
    var canSetBrightness: Bool { getBrightness != nil && setBrightness != nil && keyTarget != nil }

    /// One press of a brightness key: a sixteenth, or a sixty-fourth with ⇧⌥, as in macOS. Shows the
    /// meter even at either end. False if the brightness couldn't be set.
    @discardableResult
    func step(up: Bool, fine: Bool) -> Bool {
        guard let display = keyTarget, let getBrightness, let setBrightness else { return false }
        var current: Float = 0
        guard getBrightness(display, &current) == 0 else { return false }
        let level = MediaKeyTap.step(from: current, up: up, fine: fine)
        guard setBrightness(display, level) == 0 else { return false }
        showMeter(level)
        return true
    }

    // MARK: Private

    /// The built-in display, while it's on and the pointer is on it.
    private var keyTarget: CGDirectDisplayID? {
        let screens = NSScreen.screens
        guard let builtIn = screens.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 }) else { return nil }
        let pointer = NSEvent.mouseLocation
        if screens.count > 1, let underPointer = screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }),
           underPointer != builtIn {
            return nil
        }
        let display = builtIn.displayID
        if let canChangeBrightness, !canChangeBrightness(display) { return nil }
        return display
    }

    private func handle(_ event: NSEvent) {
        guard event.subtype.rawValue == Self.auxControlButtonsSubtype else { return }
        let key = (event.data1 & 0xFFFF_0000) >> 16
        let isDown = (event.data1 & 0xFF00) >> 8 == 0x0A
        guard isDown, key == Self.brightnessUpKey || key == Self.brightnessDownKey else { return }
        Task {
            // Give the system a moment to apply the change before reading it back.
            try? await Task.sleep(for: .milliseconds(90))
            guard let level = currentBrightness() else { return }
            showMeter(level)
        }
    }

    private func showMeter(_ level: Float) {
        let symbol = level < 0.5 ? "sun.min.fill" : "sun.max.fill"
        LiveActivityCenter.shared.showMeter(key: "brightness", symbol: symbol, level: Double(level))
    }

    private func currentBrightness() -> Float? {
        guard let getBrightness else { return nil }
        let display = NSScreen.screens.first { CGDisplayIsBuiltin($0.displayID) != 0 }?.displayID ?? CGMainDisplayID()
        var value: Float = 0
        return getBrightness(display, &value) == 0 ? value : nil
    }
}
