import AppKit
import Combine
import Quartz
import SwiftUI

/// Space-bar Quick Look for the tray, as in Finder. The notch panel never activates the app, so
/// clicking an item makes the panel the key window, which lets the space bar reach the tray. The
/// preview holds the notch open the way a menu does, and closing it hands the keyboard back.
@MainActor
final class TrayQuickLook: NSResponder {
    static let shared = TrayQuickLook()

    /// The view that anchors the tray on screen, and its window: the notch panel.
    private weak var anchor: NSView?
    private weak var viewModel: NotchViewModel?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    private var indexObservation: NSKeyValueObservation?
    /// The app that had the keyboard before the preview opened.
    private var previousApp: NSRunningApplication?
    private var isHoldingNotch = false
    private(set) var isPreviewing = false

    private override init() {
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    private var window: NSWindow? { anchor?.window }

    /// The tray is on screen. Its window gets the space and arrow keys from now on.
    func attach(_ anchor: NSView, viewModel: NotchViewModel) {
        self.anchor = anchor
        self.viewModel = viewModel
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            // The next key window isn't known until the next turn.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.closeIfAbandoned() } }
        }
    }

    /// The tray left the screen: the preview closes and the selection goes with it.
    func detach(_ anchor: NSView) {
        guard anchor === self.anchor || self.anchor == nil else { return }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        keyMonitor = nil
        resignObserver = nil
        close()
        TrayStore.shared.select(nil)
        self.anchor = nil
    }

    /// Makes the notch panel the key window, without activating the app, so the space bar reaches the tray.
    func takeKeyboard() {
        guard let window, !window.isKeyWindow else { return }
        window.makeKey()
    }

    func toggle() {
        isPreviewing ? close() : open()
    }

    func open() {
        guard !isPreviewing, TrayStore.shared.selection != nil, let panel = QLPreviewPanel.shared() else { return }
        isPreviewing = true
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost == NSRunningApplication.current ? nil : frontmost
        // Only with the keyboard: clicking elsewhere takes it away, which closes the preview and lets the notch go.
        takeKeyboard()
        holdNotchOpen(window?.isKeyWindow == true)
        // The panel looks for its controller along the responder chain, which ends with the app's next responder.
        if NSApp.nextResponder !== self {
            nextResponder = NSApp.nextResponder
            NSApp.nextResponder = self
        }
        // Not key: the notch keeps the keyboard, so the space bar closes the preview again. The app
        // isn't active, so the panel also needs ordering in front of the active app's windows.
        panel.orderFront(nil)
        panel.orderFrontRegardless()
        if panel.currentController == nil {
            panel.dataSource = self
            panel.delegate = self
        }
        panel.reloadData()
        sync()
        observe(panel)
    }

    func close() {
        guard isPreviewing else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            // Ends our control of the panel, which finishes up.
            panel.orderOut(nil)
        }
        finish()
    }

    // MARK: Private

    /// The preview went away, however that happened.
    private func finish() {
        guard isPreviewing else { return }
        isPreviewing = false
        cancellables.removeAll()
        indexObservation = nil
        if NSApp.nextResponder === self { NSApp.nextResponder = nextResponder }
        nextResponder = nil
        holdNotchOpen(false)
        // Clicking into the preview can bring the app forward; give the keyboard back to the app it came from.
        if NSApp.isActive, let previousApp { previousApp.activate() }
        previousApp = nil
    }

    /// Quick Look counts as a menu, so the notch stays open under it.
    private func holdNotchOpen(_ hold: Bool) {
        guard let viewModel, hold != isHoldingNotch else { return }
        isHoldingNotch = hold
        viewModel.isMenuOpen = hold
        guard hold else { return }
        // Opened from a context menu, which clears the flag on its way out; set it again after that.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                if self?.isPreviewing == true { viewModel.isMenuOpen = true }
            }
        }
    }

    /// Closes the preview once neither the notch nor the preview has the keyboard, say after a click in another app.
    private func closeIfAbandoned() {
        guard isPreviewing else { return }
        let key = NSApp.keyWindow
        if key == nil || (key !== window && !(key is QLPreviewPanel)) { close() }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, !(window.firstResponder is NSText),
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        let tray = TrayStore.shared
        switch event.keyCode {
        case 49:  // Space
            guard tray.selection != nil else { return false }
            if !event.isARepeat { toggle() }
            return true
        case 123, 124:  // Left and right arrows
            guard !tray.items.isEmpty else { return false }
            tray.moveSelection(by: event.keyCode == 123 ? -1 : 1)
            return true
        default:
            return false
        }
    }

    private func observe(_ panel: QLPreviewPanel) {
        let tray = TrayStore.shared
        // These publish before the value changes; act on the next turn.
        tray.$selection.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &cancellables)
        tray.$items.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] items in
                guard let self else { return }
                if items.isEmpty { close() } else { QLPreviewPanel.shared()?.reloadData() }
            }
            .store(in: &cancellables)
        // The preview's own arrows and swipes move the tray's selection too.
        indexObservation = panel.observe(\.currentPreviewItemIndex, options: [.new]) { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { TrayQuickLook.shared.followPanel() } }
        }
    }

    /// Selects the item the preview moved to.
    private func followPanel() {
        guard isPreviewing, let panel = QLPreviewPanel.shared() else { return }
        let items = TrayStore.shared.items
        let index = panel.currentPreviewItemIndex
        guard items.indices.contains(index), TrayStore.shared.selection != items[index].id else { return }
        TrayStore.shared.select(items[index])
    }

    /// Points the preview at the selected item.
    private func sync() {
        guard isPreviewing, let panel = QLPreviewPanel.shared() else { return }
        let tray = TrayStore.shared
        guard let index = tray.items.firstIndex(where: { $0.id == tray.selection }) else {
            close()
            return
        }
        if panel.currentPreviewItemIndex != index { panel.currentPreviewItemIndex = index }
    }

    // MARK: QLPreviewPanelController

    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { isPreviewing }
    }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
            finish()
        }
    }
}

extension TrayQuickLook: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { TrayStore.shared.items.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { () -> QLPreviewItem? in
            let items = TrayStore.shared.items
            return items.indices.contains(index) ? items[index].url as NSURL : nil
        }
    }

    /// Keys the preview doesn't handle itself, while it has the keyboard.
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        MainActor.assumeIsolated {
            guard event.type == .keyDown else { return false }
            switch event.keyCode {
            case 49:
                close()
                return true
            case 123, 124:
                TrayStore.shared.moveSelection(by: event.keyCode == 123 ? -1 : 1)
                return true
            default:
                return false
            }
        }
    }
}

/// Lets Quick Look know the tray is on screen, and in which window.
struct QuickLookAnchor: NSViewRepresentable {
    let viewModel: NotchViewModel

    func makeNSView(context: Context) -> AnchorView {
        AnchorView(viewModel: viewModel)
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {}

    static func dismantleNSView(_ nsView: AnchorView, coordinator: ()) {
        nsView.leave()
    }

    final class AnchorView: NSView {
        let viewModel: NotchViewModel

        init(viewModel: NotchViewModel) {
            self.viewModel = viewModel
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                TrayQuickLook.shared.attach(self, viewModel: viewModel)
            } else {
                leave()
            }
        }

        /// After the view update that removed the tray, since detaching changes published state.
        func leave() {
            DispatchQueue.main.async { MainActor.assumeIsolated { TrayQuickLook.shared.detach(self) } }
        }
    }
}
