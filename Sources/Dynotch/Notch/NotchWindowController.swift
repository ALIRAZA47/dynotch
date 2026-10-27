import AppKit
import Combine
import SwiftUI

/// One notch on one screen. The panel is as big as the open notch, so it only
/// takes mouse events while the pointer is over the visible notch; everywhere
/// else clicks fall through to the apps underneath.
@MainActor
final class NotchWindowController {
    var screen: NSScreen
    let viewModel: NotchViewModel

    private let panel: NotchPanel
    private let host: NSView
    /// The views are off the panel while nobody can see the screen.
    private var isQuiet = false
    private var isInside = false
    /// Opened from the keyboard or menu: stays open until the pointer has been over it once.
    private var awaitingPointer = false
    private var hoverTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var scrollTotal: CGFloat = 0
    /// Sideways travel of the current swipe, positive to the right.
    private var swipeAcross: CGFloat = 0
    /// Up and down or sideways, settled once the fingers have moved a little.
    private var swipeAxis: Axis?
    private var hasSkipped = false
    private var lastScroll = Date.distantPast
    private var cancellables = Set<AnyCancellable>()

    /// Room around the open notch for its shadow.
    private static let shadowInset: CGFloat = 40

    var displayID: CGDirectDisplayID { screen.displayID }

    init(screen: NSScreen) {
        self.screen = screen
        viewModel = NotchViewModel(geometry: NotchGeometry.make(
            for: screen, virtualWidth: AppSettings.shared.virtualNotchWidth))
        panel = NotchPanel(contentRect: .zero)
        let host = NotchHostingView(rootView: NotchRootView(viewModel: viewModel))
        host.sizingOptions = []
        self.host = host
        panel.contentView = host
        layout()
        panel.orderFrontRegardless()

        // These publish before the value changes, so act on the next turn.
        viewModel.$phase
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                if phase == .closed { self?.panel.giveUpKeyFocus() }
                self?.refreshPointer()
            }
            .store(in: &cancellables)
        Publishers.Merge(viewModel.$isMenuOpen, viewModel.$isDraggingFiles)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.closeIfAbandoned() }
            .store(in: &cancellables)
        AudioOutputs.shared.$isPresentingRoutes
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.closeIfAbandoned() }
            .store(in: &cancellables)
    }

    func layout() {
        let settings = AppSettings.shared
        viewModel.update(geometry: NotchGeometry.make(for: screen, virtualWidth: settings.virtualNotchWidth))
        let width = settings.openWidth + NotchMetrics.openTopRadius * 2 + Self.shadowInset * 2
        let height = settings.openHeight + Self.shadowInset
        let frame = screen.frame
        panel.setFrame(CGRect(x: (frame.midX - width / 2).rounded(), y: frame.maxY - height, width: width, height: height),
                       display: true)
    }

    func tearDown() {
        hoverTask?.cancel()
        closeTask?.cancel()
        cancellables.removeAll()
        panel.orderOut(nil)
        panel.close()
    }

    /// While nobody can see the screen, the notch's views come off the panel. Off a window,
    /// SwiftUI stops their clocks and animations (the equalizer's bars alone wake the app a couple
    /// of hundred times a second) and their onDisappear stops the Stats sampling, the camera and the
    /// equalizer's audio tap. They go back as they were.
    func setQuiet(_ quiet: Bool) {
        guard quiet != isQuiet else { return }
        isQuiet = quiet
        if quiet {
            hoverTask?.cancel()
            cancelClose()
            panel.contentView = NSView()
            panel.orderOut(nil)
        } else {
            panel.contentView = host
            panel.orderFrontRegardless()
            refreshPointer()
        }
    }

    // MARK: Pointer

    func mouseMoved(to point: CGPoint) {
        // A drag that ended outside any window never sends us a mouse-up.
        if NSEvent.pressedMouseButtons == 0 {
            if viewModel.isDraggingOut { viewModel.isDraggingOut = false }
            if viewModel.isDraggingFiles { viewModel.isDraggingFiles = false }
        }
        let inside = hitRect().contains(point)
        setInteractive(inside)
        if inside != isInside {
            isInside = inside
            inside ? pointerEntered() : pointerExited()
        } else if !inside, viewModel.isOpen, !awaitingPointer, closeTask == nil, !isHeldOpen {
            // Whatever held the notch open (a drag, a menu) has ended while the pointer was away.
            scheduleClose()
        }
    }

    /// Opens without the pointer, from the keyboard shortcut or the menu bar.
    func present(tab: NotchTab?) {
        awaitingPointer = true
        viewModel.open(tab: tab)
    }

    func mouseDown(at point: CGPoint) {
        let inside = hitRect().contains(point)
        if inside, !viewModel.isOpen {
            hoverTask?.cancel()
            viewModel.open()
        } else if !inside, viewModel.isOpen, !viewModel.isMenuOpen, !AudioOutputs.shared.isPresentingRoutes {
            dismiss()
        }
    }

    func mouseUp(at point: CGPoint) {
        if viewModel.isDraggingOut {
            viewModel.isDraggingOut = false
            closeIfAbandoned()
        }
    }

    func mouseDragged(to point: CGPoint, carryingFiles: Bool) {
        guard carryingFiles, !viewModel.isDraggingOut, AppSettings.shared.trayOpensOnDrag else {
            mouseMoved(to: point)
            return
        }
        let reach = viewModel.isOpen ? notchRect.insetBy(dx: -24, dy: -24) : notchRect.insetBy(dx: -80, dy: -70)
        if reach.contains(point) {
            cancelClose()
            setInteractive(true)
            if !viewModel.isDraggingFiles { viewModel.isDraggingFiles = true }
            if !viewModel.isOpen {
                Haptics.tap()
                viewModel.open(tab: .tray)
            }
        } else if viewModel.isDraggingFiles {
            viewModel.isDraggingFiles = false
            viewModel.close()
            setInteractive(false)
        }
    }

    func scrolled(_ event: NSEvent, at point: CGPoint) {
        guard event.momentumPhase.isEmpty else { return }
        // Over the open player's artwork, scrolling changes the volume instead.
        if viewModel.isOpen, VolumeScrollView.covers(point, in: panel) {
            resetSwipe()
            return
        }
        guard AppSettings.shared.swipeGestures else { return }
        guard hitRect().contains(point) else {
            resetSwipe()
            return
        }
        // A mouse wheel has no phases, so a pause starts a new gesture.
        if event.phase == .began || event.phase == .mayBegin
            || (event.phase.isEmpty && Date.now.timeIntervalSince(lastScroll) > 0.4) {
            resetSwipe()
        }
        lastScroll = .now
        // Positive when the fingers move down or right, whatever the natural-scrolling setting.
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
        let inverted = event.isDirectionInvertedFromDevice
        scrollTotal += (inverted ? event.scrollingDeltaY : -event.scrollingDeltaY) * scale
        swipeAcross += (inverted ? event.scrollingDeltaX : -event.scrollingDeltaX) * scale
        if swipeAxis == nil, max(abs(scrollTotal), abs(swipeAcross)) > 6 {
            swipeAxis = abs(swipeAcross) > abs(scrollTotal) ? .horizontal : .vertical
            // Skipping a track shouldn't open the notch on the way.
            if swipeAxis == .horizontal { hoverTask?.cancel() }
        }

        switch swipeAxis {
        case .vertical:
            if !viewModel.isOpen, scrollTotal > 14 {
                scrollTotal = 0
                hoverTask?.cancel()
                Haptics.tap()
                viewModel.open()
            } else if viewModel.isOpen, scrollTotal < -40, swipeClosesNotch(at: point) {
                scrollTotal = 0
                dismiss()
            }
        case .horizontal:
            // Hovering opens the notch quickly, so its header row, where the closed notch was, counts too.
            if !hasSkipped, abs(swipeAcross) > 40, !viewModel.isOpen || isOverHeader(point) {
                hasSkipped = true
                skipTrack(forward: swipeAcross < 0)
            }
        case nil:
            break
        }
        if event.phase == .ended || event.phase == .cancelled { resetSwipe() }
    }

    func dismiss() {
        hoverTask?.cancel()
        cancelClose()
        awaitingPointer = false
        viewModel.close()
    }

    func refreshPointer() {
        mouseMoved(to: NSEvent.mouseLocation)
    }

    // MARK: Private

    /// The visible notch in screen coordinates.
    private var notchRect: CGRect {
        let metrics = viewModel.metrics
        let frame = viewModel.geometry.screenFrame
        return CGRect(x: frame.midX - metrics.outerWidth / 2, y: frame.maxY - metrics.height,
                      width: metrics.outerWidth, height: metrics.height)
    }

    /// The notch plus a little slack, and up past the top edge so the very top pixel counts.
    private func hitRect() -> CGRect {
        let slack: CGFloat = viewModel.isOpen ? 6 : 4
        let rect = notchRect
        return CGRect(x: rect.minX - slack, y: rect.minY - slack, width: rect.width + slack * 2, height: rect.height + slack + 4)
    }

    private func setInteractive(_ interactive: Bool) {
        if panel.ignoresMouseEvents == interactive { panel.ignoresMouseEvents = !interactive }
    }

    private func pointerEntered() {
        cancelClose()
        awaitingPointer = false
        guard !viewModel.isOpen else { return }
        viewModel.setHovering(true)
        Haptics.tap()
        guard AppSettings.shared.openOnHover else { return }
        hoverTask?.cancel()
        let delay = AppSettings.shared.hoverDelay
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.isInside else { return }
            self.viewModel.open()
        }
    }

    private func pointerExited() {
        hoverTask?.cancel()
        viewModel.setHovering(false)
        if viewModel.isOpen { scheduleClose() }
    }

    private func scheduleClose(after delay: TimeInterval = 0.15) {
        closeTask?.cancel()
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.closeTask = nil
            guard !self.isInside, !self.isHeldOpen else { return }
            self.viewModel.close()
        }
    }

    private func cancelClose() {
        closeTask?.cancel()
        closeTask = nil
    }

    /// A menu, a drag or AirPlay's device list hangs off the open notch, so it stays open.
    private var isHeldOpen: Bool {
        viewModel.shouldStayOpen || AudioOutputs.shared.isPresentingRoutes
    }

    /// Something that held the notch open went away while the pointer was elsewhere.
    private func closeIfAbandoned() {
        guard viewModel.isOpen, !isHeldOpen else { return }
        isInside = hitRect().contains(NSEvent.mouseLocation)
        if !isInside { scheduleClose(after: 0.4) }
    }

    /// The Focus tab has scrolling lists, so there only a swipe over the header closes the notch.
    private func swipeClosesNotch(at point: CGPoint) -> Bool {
        guard viewModel.visibleTab == .focus else { return true }
        return isOverHeader(point)
    }

    /// The open notch's top row, beside the camera.
    private func isOverHeader(_ point: CGPoint) -> Bool {
        let geometry = viewModel.geometry
        return point.y >= geometry.screenFrame.maxY - geometry.closedSize.height - 8
    }

    private func resetSwipe() {
        scrollTotal = 0
        swipeAcross = 0
        swipeAxis = nil
        hasSkipped = false
    }

    /// Two fingers sideways over the notch: to the left for the next track, to the right for the previous one.
    private func skipTrack(forward: Bool) {
        let media = NowPlayingService.shared
        guard media.player != nil else { return }
        Haptics.tap()
        if forward { media.next() } else { media.previous() }
    }
}
