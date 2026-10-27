import AppKit
import Combine

/// Owns a notch per screen and feeds them the pointer, which it watches app-wide.
@MainActor
final class NotchManager {
    static let shared = NotchManager()

    private(set) var controllers: [NotchWindowController] = []
    private var monitors: [Any] = []
    /// The drag pasteboard's change count at the last click; a new drag bumps it.
    private var dragChangeCount = NSPasteboard(name: .drag).changeCount
    /// Set while the capture overlay covers the screen, so the notch neither grows nor opens under it.
    var isPointerSuspended = false
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    func start() {
        rebuild()
        installMonitors()

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)

        let settings = AppSettings.shared
        settings.$displayMode.dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
        Publishers.Merge4(settings.$openWidth.dropFirst().map { _ in () },
                          settings.$openHeight.dropFirst().map { _ in () },
                          settings.$virtualNotchWidth.dropFirst().map { _ in () },
                          settings.$virtualNotchStyle.dropFirst().map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.controllers.forEach { $0.layout() } }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)
            .sink { [weak self] _ in self?.controllers.forEach { $0.viewModel.isMenuOpen = true } }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)
            .sink { [weak self] _ in self?.controllers.forEach { $0.viewModel.isMenuOpen = false } }
            .store(in: &cancellables)

        // Nobody can see the screen: close the notch and let its views rest.
        EnergyCoordinator.shared.$conditions
            .map(\.isQuiet)
            .removeDuplicates()
            .sink { [weak self] quiet in
                if quiet { self?.close() }
                self?.controllers.forEach { $0.setQuiet(quiet) }
            }
            .store(in: &cancellables)
    }

    /// Opens the notch under the pointer (or closes the open one).
    func toggle(tab: NotchTab? = nil) {
        guard let controller = activeController() else { return }
        let viewModel = controller.viewModel
        if viewModel.isOpen, tab == nil || viewModel.visibleTab == tab {
            controller.dismiss()
        } else {
            controller.present(tab: tab)
        }
    }

    func open(tab: NotchTab? = nil) {
        activeController()?.present(tab: tab)
    }

    /// Opens the notch under the pointer straight into the command field, ready to type.
    func openCommand() {
        activeController()?.presentCommand()
    }

    func close() {
        controllers.forEach { $0.dismiss() }
    }

    // MARK: Private

    private func activeController() -> NotchWindowController? {
        let pointer = NSEvent.mouseLocation
        return controllers.first { $0.viewModel.isOpen }
            ?? controllers.first { $0.screen.frame.contains(pointer) }
            ?? controllers.first
    }

    private func targetScreens() -> [NSScreen] {
        let screens = NSScreen.screens
        switch AppSettings.shared.displayMode {
        case .all:
            return screens
        case .main:
            return Array(screens.prefix(1))
        case .notched:
            let notched = screens.filter(\.hasNotch)
            return notched.isEmpty ? Array(screens.prefix(1)) : notched
        }
    }

    private func rebuild() {
        var kept: [NotchWindowController] = []
        for screen in targetScreens() {
            if let existing = controllers.first(where: { $0.displayID == screen.displayID }) {
                existing.screen = screen
                existing.layout()
                kept.append(existing)
            } else {
                let controller = NotchWindowController(screen: screen)
                controller.viewModel.onOpen = { [weak self, weak controller] in
                    self?.controllers.filter { $0 !== controller }.forEach { $0.dismiss() }
                }
                if EnergyCoordinator.shared.isQuiet { controller.setQuiet(true) }
                kept.append(controller)
            }
        }
        for controller in controllers where !kept.contains(where: { $0 === controller }) {
            controller.tearDown()
        }
        controllers = kept
    }

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown, .leftMouseUp, .scrollWheel]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.route(event) }
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.route(event) }
            return event
        }) {
            monitors.append(monitor)
        }
        // Escape closes the notch while one of its text fields has focus.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return handled ? nil : event
        }) {
            monitors.append(monitor)
        }
    }

    private func route(_ event: NSEvent) {
        guard !isPointerSuspended else { return }
        EnergyCoordinator.shared.sawInput()
        let point = NSEvent.mouseLocation
        switch event.type {
        case .mouseMoved:
            controllers.forEach { $0.mouseMoved(to: point) }
        case .leftMouseDragged:
            let files = isDraggingFiles()
            controllers.forEach { $0.mouseDragged(to: point, carryingFiles: files) }
        case .leftMouseDown, .rightMouseDown:
            dragChangeCount = NSPasteboard(name: .drag).changeCount
            controllers.forEach { $0.mouseDown(at: point) }
        case .leftMouseUp:
            controllers.forEach { $0.mouseUp(at: point) }
        case .scrollWheel:
            controllers.forEach { $0.scrolled(event, at: point) }
        default:
            break
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.keyCode == 53, let open = controllers.first(where: { $0.viewModel.isOpen }) else { return false }
        // In the command field, Escape clears what's typed, then leaves the field; the next one closes the notch.
        if open.viewModel.isCommandMode {
            open.viewModel.escapeCommand()
        } else {
            open.dismiss()
        }
        return true
    }

    /// True while a drag that started after the last click carries something the tray accepts.
    private func isDraggingFiles() -> Bool {
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != dragChangeCount else { return false }
        let types = pasteboard.types ?? []
        return types.contains(.fileURL) || types.contains(.png) || types.contains(.tiff)
    }
}
