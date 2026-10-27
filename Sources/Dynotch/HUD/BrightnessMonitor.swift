import AppKit

/// Shows the built-in display's brightness in the notch when the brightness keys are pressed.
/// There's no public API to read it on Apple silicon, so this uses DisplayServices when it's there
/// and stays quiet when it isn't.
@MainActor
final class BrightnessMonitor {
    static let shared = BrightnessMonitor()

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private var getBrightness: GetBrightness?
    private var monitor: Any?

    // From IOKit's ev_keymap.h.
    private static let brightnessUpKey = 2
    private static let brightnessDownKey = 3
    private static let auxControlButtonsSubtype: Int16 = 8

    private init() {}

    func start() {
        if let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
           let symbol = dlsym(handle, "DisplayServicesGetBrightness") {
            getBrightness = unsafeBitCast(symbol, to: GetBrightness.self)
        }
        guard getBrightness != nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
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
            let symbol = level < 0.5 ? "sun.min.fill" : "sun.max.fill"
            LiveActivityCenter.shared.showMeter(key: "brightness", symbol: symbol, level: Double(level))
        }
    }

    private func currentBrightness() -> Float? {
        guard let getBrightness else { return nil }
        let display = NSScreen.screens.first { CGDisplayIsBuiltin($0.displayID) != 0 }?.displayID ?? CGMainDisplayID()
        var value: Float = 0
        return getBrightness(display, &value) == 0 ? value : nil
    }
}
