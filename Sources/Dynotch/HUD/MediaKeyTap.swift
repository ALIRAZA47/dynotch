import AppKit
import Combine

/// The keys the tap takes. From IOKit's ev_keymap.h.
enum MediaKey: Int, Sendable {
    case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7

    var isVolume: Bool { self == .soundUp || self == .soundDown }
    var isBrightness: Bool { self == .brightnessUp || self == .brightnessDown }
}

/// What the tap's thread needs to know to decide about a key without asking the main thread.
/// The main thread keeps it current.
struct KeyRouting: Equatable, Sendable {
    /// Volume and brightness show in the notch at all.
    var showsHUD = false
    var canSetVolume = false
    var canMute = false
    /// Dynotch can set the built-in display's brightness.
    var canSetBrightness = false

    /// Whether Dynotch takes `key`, and whether ⇧⌥ asks for quarter steps. ⌥ alone opens Sound or
    /// Displays settings, and ⌃ or ⌘ belong to other tools, so those go on to the system; so does a
    /// key Dynotch can't act on, like an output without a volume control, or a brightness key while
    /// the pointer is on another display.
    func takes(_ key: MediaKey, flags: CGEventFlags, pointerOnBuiltIn: Bool) -> (taken: Bool, fine: Bool) {
        let option = flags.contains(.maskAlternate), shift = flags.contains(.maskShift)
        guard showsHUD, !flags.contains(.maskCommand), !flags.contains(.maskControl), !option || shift else {
            return (false, false)
        }
        let taken = switch key {
        case .soundUp, .soundDown: canSetVolume
        case .mute: canMute
        case .brightnessUp, .brightnessDown: canSetBrightness && pointerOnBuiltIn
        }
        return (taken, option)
    }
}

/// One press of a key, waiting for the main thread to act on it.
struct KeyPress: Equatable, Sendable {
    var key: MediaKey
    /// ⇧⌥: a quarter of a step.
    var fine = false
    /// Sent by the keyboard while the key is held, not by pressing it.
    var isRepeat = false
}

/// The presses the tap has taken and the app hasn't acted on yet. The tap never waits for the app,
/// so if the app is busy they collect here instead of holding up the Mac's input. Two rules keep a
/// busy app from running on after the key: letting go drops what holding the key still had waiting,
/// and no more waits than would cross the whole range.
struct KeyBacklog: Equatable, Sendable {
    /// A full sweep of the volume or the brightness is sixteen steps.
    static let mostRepeats = 16
    static let most = 48

    private(set) var presses: [KeyPress] = []

    var isEmpty: Bool { presses.isEmpty }

    mutating func add(_ press: KeyPress) {
        guard presses.count < Self.most else { return }
        if press.isRepeat, presses.filter({ $0.isRepeat && $0.key == press.key }).count >= Self.mostRepeats { return }
        presses.append(press)
    }

    /// `key` came up. Presses stay; what holding it still had waiting goes.
    mutating func release(_ key: MediaKey) {
        presses.removeAll { $0.key == key && $0.isRepeat }
    }

    mutating func drain() -> [KeyPress] {
        defer { presses = [] }
        return presses
    }
}

/// The part of the tap that lives on its own thread. An event tap that can swallow keys holds up
/// every key press and click on the Mac until its callback answers, so the callback must never wait
/// for the main thread, which may be busy drawing, or blocked on a Bluetooth output. This answers
/// from what it was last told (`KeyRouting`), notes the press, and wakes the main thread to act on it.
final class KeyTapCore: @unchecked Sendable {
    private let lock = NSLock()
    private var routing = KeyRouting()
    private var backlog = KeyBacklog()
    private var isScheduled = false
    /// Keys whose press Dynotch took, so their release is taken too and the system never sees half a key.
    private var held: Set<MediaKey> = []
    private var port: CFMachPort?
    private var loop: CFRunLoop?
    private var isStopped = false
    /// Called on the main thread when there are presses to act on.
    private let wake: @Sendable (KeyTapCore) -> Void

    init(wake: @escaping @Sendable (KeyTapCore) -> Void) {
        self.wake = wake
    }

    // MARK: From the main thread

    func update(_ routing: KeyRouting) {
        lock.withLock { self.routing = routing }
    }

    func takeBacklog() -> [KeyPress] {
        lock.withLock {
            isScheduled = false
            return backlog.drain()
        }
    }

    /// Starts the tap's thread. False if macOS wouldn't make the tap.
    func start() -> Bool {
        // Media and brightness keys arrive as system-defined events (NX_SYSDEFINED, 14).
        let mask = CGEventMask(1) << 14
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: mediaKeyCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        lock.withLock { self.port = port }
        let thread = Thread { [self] in run(port) }
        thread.name = "app.dynotch.media-keys"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    func stop() {
        let (port, loop) = lock.withLock {
            isStopped = true
            return (self.port, self.loop)
        }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let loop { CFRunLoopStop(loop) }
    }

    // MARK: On the tap's thread

    private func run(_ port: CFMachPort) {
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        let current = CFRunLoopGetCurrent()
        let stopped = lock.withLock {
            loop = current
            return isStopped
        }
        guard !stopped else { return }
        CFRunLoopAddSource(current, source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        CFRunLoopRun()
        CFRunLoopRemoveSource(current, source, .commonModes)
    }

    /// True when Dynotch takes the event and the system shouldn't see it. Nothing here waits on
    /// anything but the lock, which is only ever held for a few instructions.
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // macOS turns a tap off when its callback is slow. Turn it back on, and say so: with the
            // callback off the main thread this shouldn't happen.
            if type == .tapDisabledByTimeout { NSLog("Dynotch: the media key tap timed out and was turned back on") }
            if let port = lock.withLock({ port }) { CGEvent.tapEnable(tap: port, enable: true) }
            return false
        }
        return autoreleasepool {
            guard let nsEvent = NSEvent(cgEvent: event), nsEvent.type == .systemDefined, nsEvent.subtype.rawValue == 8,
                  let key = MediaKey(rawValue: (nsEvent.data1 & 0xFFFF_0000) >> 16) else { return false }
            let state = (nsEvent.data1 & 0xFF00) >> 8
            let isDown = state == 0x0A, isUp = state == 0x0B
            let isRepeat = nsEvent.data1 & 0x1 != 0
            if isUp {
                // The release of a press Dynotch took is Dynotch's too; any other belongs to the system.
                return lock.withLock {
                    backlog.release(key)
                    return held.remove(key) != nil
                }
            }
            guard isDown else { return false }
            let pointerOnBuiltIn = key.isBrightness ? Self.pointerIsOnBuiltInDisplay() : true
            let schedule: Bool? = lock.withLock {
                let (taken, fine) = routing.takes(key, flags: event.flags, pointerOnBuiltIn: pointerOnBuiltIn)
                guard taken else {
                    held.remove(key)
                    return nil
                }
                held.insert(key)
                backlog.add(KeyPress(key: key, fine: fine, isRepeat: isRepeat))
                guard !isScheduled else { return false }
                isScheduled = true
                return true
            }
            guard let schedule else { return false }
            if schedule {
                let wake = wake
                DispatchQueue.main.async { [self] in wake(self) }
            }
            return true
        }
    }

    /// The brightness keys change the display the pointer is on. Dynotch only sets the built-in one,
    /// so with the pointer on another display, or the lid closed, the key is left to macOS.
    private static func pointerIsOnBuiltInDisplay() -> Bool {
        var count: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(16, &displays, &count) == .success else { return false }
        let active = displays.prefix(Int(count))
        guard active.contains(where: { CGDisplayIsBuiltin($0) != 0 }) else { return false }
        if active.count == 1 { return true }
        guard let pointer = CGEvent(source: nil)?.location else { return false }
        var under: CGDirectDisplayID = 0
        var found: UInt32 = 0
        guard CGGetDisplaysWithPoint(pointer, 1, &under, &found) == .success, found > 0 else { return false }
        return CGDisplayIsBuiltin(under) != 0
    }
}

/// Runs on the tap's own thread. See `KeyTapCore`.
private func mediaKeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let core = Unmanaged<KeyTapCore>.fromOpaque(refcon).takeUnretainedValue()
    return core.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}

/// Takes over the volume and brightness keys so only Dynotch's HUD shows, instead of Dynotch's
/// and the system's together. An event tap sees the keys before the system does; creating one
/// needs Accessibility permission. Keys Dynotch can't act on, like an output without a volume
/// control or an external display's brightness, go on to the system.
///
/// The tap answers on a thread of its own (`KeyTapCore`) and this acts on the presses afterwards,
/// a batch at a time, so however busy the app is it can't hold up the Mac's keyboard and clicks.
@MainActor
final class MediaKeyTap: ObservableObject {
    static let shared = MediaKeyTap()

    /// The tap is installed and handling keys.
    @Published private(set) var isActive = false
    /// Dynotch has Accessibility access, so the tap can be created.
    @Published private(set) var hasAccess = AXIsProcessTrusted()

    private var core: KeyTapCore?
    private var accessPoll: Poll?
    private var cancellables = Set<AnyCancellable>()

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
        // What the tap's thread goes by: whether the HUD shows, the output, the displays.
        let screens = NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification).map { _ in () }
        let woke = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).map { _ in () }
        Publishers.Merge4(settings.objectWillChange.map { _ in () }, VolumeMonitor.shared.outputChanged, screens, woke)
            // @Published fires before the value changes; read it on the next turn.
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refreshRouting() }
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

    /// Where a run of presses lands, each stepping from where the last one left it.
    nonisolated static func level(from value: Float, after presses: [KeyPress], up: (MediaKey) -> Bool) -> Float {
        presses.reduce(value) { step(from: $0, up: up($1.key), fine: $1.fine) }
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
        if core != nil { return true }
        guard AXIsProcessTrusted() else { return false }
        let core = KeyTapCore { core in
            MainActor.assumeIsolated { MediaKeyTap.shared.act(for: core) }
        }
        core.update(currentRouting())
        guard core.start() else { return false }
        self.core = core
        isActive = true
        if !hasAccess { hasAccess = true }
        return true
    }

    private func disable() {
        accessPoll?.cancel()
        accessPoll = nil
        guard let core else { return }
        core.stop()
        self.core = nil
        isActive = false
    }

    private func currentRouting() -> KeyRouting {
        let volume = VolumeMonitor.shared
        return KeyRouting(showsHUD: AppSettings.shared.liveHUD, canSetVolume: volume.canSetVolume, canMute: volume.canMute,
                          canSetBrightness: BrightnessMonitor.shared.canSetLevel)
    }

    private func refreshRouting() {
        core?.update(currentRouting())
    }

    /// Acts on the presses the tap has taken since the last time: every volume press in one change
    /// to the volume, every brightness press in one to the brightness, in the order they came.
    private func act(for core: KeyTapCore) {
        // A tap that has been turned off since has nothing more to say.
        guard core === self.core else { return }
        var run: [KeyPress] = []
        func flush() {
            guard let first = run.first else { return }
            if first.key.isVolume {
                VolumeMonitor.shared.step(run)
            } else {
                BrightnessMonitor.shared.step(run)
            }
            run = []
        }
        for press in core.takeBacklog() {
            if press.key == .mute {
                flush()
                VolumeMonitor.shared.toggleMute()
            } else {
                if let first = run.first, first.key.isVolume != press.key.isVolume { flush() }
                run.append(press)
            }
        }
        flush()
        // The output or the display may have stopped taking changes; the next key goes by this.
        refreshRouting()
    }
}
