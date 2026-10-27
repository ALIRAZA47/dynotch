import AppKit
import Combine

/// Takes over the volume and brightness keys so only Dynotch's HUD shows, instead of Dynotch's
/// and the system's together. An event tap sees the keys before the system does; creating one
/// needs Accessibility permission. Keys Dynotch can't act on, like an output without a volume
/// control or an external display's brightness, go on to the system.
@MainActor
final class MediaKeyTap: ObservableObject {
    static let shared = MediaKeyTap()

    /// The tap is installed and handling keys.
    @Published private(set) var isActive = false
    /// Dynotch has Accessibility access, so the tap can be created.
    @Published private(set) var hasAccess = AXIsProcessTrusted()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var accessPoll: Poll?
    private var cancellables = Set<AnyCancellable>()

    // From IOKit's ev_keymap.h.
    private enum Key: Int {
        case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
    }

    private init() {}

    func start() {
        let settings = AppSettings.shared
        // Launching never asks for permission; turning the setting on does.
        if settings.replaceSystemHUD { enable(askForAccess: false) }
        settings.$replaceSystemHUD
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] enabled in
                if enabled { self?.enable(askForAccess: true) } else { self?.disable() }
            }
            .store(in: &cancellables)
        // Coming back from System Settings, where access is granted.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refreshAccess() }
            .store(in: &cancellables)
    }

    /// Where one press of a volume or brightness key lands: the next sixteenth, or sixty-fourth with ⇧⌥,
    /// as in macOS. It's at least a quarter of a step away, so a level just short of a step still moves a whole one.
    nonisolated static func step(from value: Float, up: Bool, fine: Bool) -> Float {
        let steps: Float = fine ? 64 : 16
        let position = value * steps
        let next = up ? (position + 0.25).rounded(.down) + 1 : (position - 0.25).rounded(.up) - 1
        return min(steps, max(0, next)) / steps
    }

    /// Shows the system's Accessibility prompt, or System Settings if Dynotch has asked before,
    /// then starts the tap as soon as access is granted.
    func requestAccess() {
        let askedBefore = UserDefaults.dynotch.bool(forKey: "askedForAccessibility")
        UserDefaults.dynotch.set(true, forKey: "askedForAccessibility")
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        if !AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary), askedBefore {
            CalendarService.openPrivacySettings("Privacy_Accessibility")
        }
        waitForAccess()
    }

    // MARK: Private

    private func enable(askForAccess: Bool) {
        if install() { return }
        if askForAccess { requestAccess() } else { waitForAccess() }
    }

    /// Access is granted in System Settings, which doesn't tell the app; check every couple of seconds for a while.
    private func waitForAccess() {
        accessPoll?.cancel()
        let deadline = Date.now.addingTimeInterval(600)
        accessPoll = EnergyCoordinator.shared.schedule(.accessibilityCheck) { [weak self] in
            guard let self else { return }
            if Date.now < deadline { self.refreshAccess() }
            if self.hasAccess || Date.now >= deadline {
                self.accessPoll?.cancel()
                self.accessPoll = nil
            }
        }
    }

    private func refreshAccess() {
        let trusted = AXIsProcessTrusted()
        if trusted != hasAccess { hasAccess = trusted }
        if trusted, AppSettings.shared.replaceSystemHUD { install() }
    }

    @discardableResult
    private func install() -> Bool {
        if tap != nil { return true }
        guard AXIsProcessTrusted() else { return false }
        // Media and brightness keys arrive as system-defined events (NX_SYSDEFINED, 14).
        let mask = CGEventMask(1) << 14
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: mediaKeyCallback, userInfo: nil) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        isActive = true
        if !hasAccess { hasAccess = true }
        return true
    }

    private func disable() {
        accessPoll?.cancel()
        accessPoll = nil
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
        isActive = false
    }

    /// The system turns a tap off when its callback is slow; turn it back on.
    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// True when Dynotch handled the key and the system shouldn't see it.
    fileprivate func handle(_ cgEvent: CGEvent) -> Bool {
        guard AppSettings.shared.liveHUD,
              let event = NSEvent(cgEvent: cgEvent), event.type == .systemDefined, event.subtype.rawValue == 8,
              let key = Key(rawValue: (event.data1 & 0xFFFF_0000) >> 16) else { return false }
        let isDown = (event.data1 & 0xFF00) >> 8 == 0x0A
        // ⌥ alone opens Sound or Displays settings, and ⌃ or ⌘ belong to other tools, so leave those
        // to the system. ⇧⌥ takes quarter steps.
        let flags = cgEvent.flags
        let option = flags.contains(.maskAlternate), shift = flags.contains(.maskShift)
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || (option && !shift) { return false }
        switch key {
        case .soundUp, .soundDown:
            let volume = VolumeMonitor.shared
            guard volume.canSetVolume else { return false }
            if isDown { volume.step(up: key == .soundUp, fine: option) }
            return true
        case .mute:
            let volume = VolumeMonitor.shared
            guard volume.canMute else { return false }
            if isDown { volume.toggleMute() }
            return true
        case .brightnessUp, .brightnessDown:
            let brightness = BrightnessMonitor.shared
            guard brightness.canSetBrightness else { return false }
            // If setting it fails, the system gets the key after all.
            return isDown ? brightness.step(up: key == .brightnessUp, fine: option) : true
        }
    }
}

/// The tap's run loop source is on the main run loop, so this runs on the main thread.
private func mediaKeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { MediaKeyTap.shared.reenable() }
        return Unmanaged.passUnretained(event)
    }
    let handled = MainActor.assumeIsolated { MediaKeyTap.shared.handle(event) }
    return handled ? nil : Unmanaged.passUnretained(event)
}
