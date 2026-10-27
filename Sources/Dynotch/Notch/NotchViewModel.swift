import Combine
import SwiftUI

/// The size of the black notch body (flares excluded) and its corner radii.
struct NotchMetrics: Equatable {
    var width: CGFloat
    var height: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var outerWidth: CGFloat { width + topRadius * 2 }

    static let openTopRadius: CGFloat = 12
    static let openBottomRadius: CGFloat = 26
}

/// The closed notch: the hardware cutout in the middle, with matching "ears"
/// either side for live activities and an optional row underneath.
struct ClosedLayout: Equatable {
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var earWidth: CGFloat
    var rowHeight: CGFloat

    var totalWidth: CGFloat { notchWidth + earWidth * 2 }
    var totalHeight: CGFloat { notchHeight + rowHeight }

    init(activity: ClosedActivity, notch: CGSize) {
        notchWidth = notch.width
        notchHeight = notch.height
        switch activity {
        case .idle:
            earWidth = 0
            rowHeight = 0
        case .music:
            earWidth = notch.height + 8
            rowHeight = 0
        case .trackPeek:
            earWidth = 54
            rowHeight = 26
        case .timer:
            earWidth = 64
            rowHeight = 0
        case .notice(let notice):
            switch notice.kind {
            case .meter:
                earWidth = 96
                rowHeight = 0
            case .info:
                earWidth = max(56, CGFloat(notice.text.count) * 7.5 + 22)
                rowHeight = notice.detail == nil ? 0 : 26
            }
        }
    }
}

@MainActor
final class NotchViewModel: ObservableObject {
    enum Phase: Equatable {
        case closed, hovering, open
    }

    @Published private(set) var geometry: NotchGeometry
    @Published private(set) var phase: Phase = .closed
    @Published var tab: NotchTab = .home
    /// Files are being dragged toward the notch; the tray shows its drop zones.
    @Published var isDraggingFiles = false
    @Published private(set) var activity: ClosedActivity
    /// A context menu is open; the notch must not close under it.
    @Published var isMenuOpen = false

    /// Something was dragged out of the tray and the drag hasn't ended yet.
    var isDraggingOut = false
    var onOpen: (() -> Void)?

    private var cancellables = Set<AnyCancellable>()

    init(geometry: NotchGeometry) {
        self.geometry = geometry
        activity = LiveActivityCenter.shared.activity
        LiveActivityCenter.shared.$activity
            .dropFirst()
            .sink { [weak self] activity in
                withAnimation(.notchActivity) { self?.activity = activity }
            }
            .store(in: &cancellables)
        // Open size and enabled tabs live in settings.
        AppSettings.shared.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    var isOpen: Bool { phase == .open }

    var shouldStayOpen: Bool { isMenuOpen || isDraggingFiles || isDraggingOut }

    /// The tab on screen: the tray while files are dragged in, otherwise the chosen one if it's enabled.
    var visibleTab: NotchTab {
        if isDraggingFiles { return .tray }
        return AppSettings.shared.enabledTabs.contains(tab) ? tab : .home
    }

    var closedLayout: ClosedLayout {
        ClosedLayout(activity: activity, notch: geometry.closedSize)
    }

    var metrics: NotchMetrics {
        let settings = AppSettings.shared
        switch phase {
        case .open:
            return NotchMetrics(width: settings.openWidth, height: settings.openHeight,
                                topRadius: NotchMetrics.openTopRadius, bottomRadius: NotchMetrics.openBottomRadius)
        case .closed, .hovering:
            let layout = closedLayout
            let hovering = phase == .hovering
            let tall = layout.rowHeight > 0
            return NotchMetrics(width: layout.totalWidth + (hovering ? 14 : 0),
                                height: layout.totalHeight + (hovering ? 3 : 0),
                                topRadius: 6,
                                bottomRadius: tall ? 16 : (hovering ? 12 : 10))
        }
    }

    func open(tab: NotchTab? = nil) {
        if let tab { self.tab = tab }
        guard phase != .open else { return }
        withAnimation(.notchOpen) { phase = .open }
        onOpen?()
        NowPlayingService.shared.refresh()
    }

    func close() {
        guard phase != .closed else { return }
        withAnimation(.notchClose) {
            phase = .closed
            isDraggingFiles = false
        }
    }

    func setHovering(_ hovering: Bool) {
        guard phase != .open else { return }
        let next: Phase = hovering ? .hovering : .closed
        guard next != phase else { return }
        withAnimation(.notchHover) { phase = next }
    }

    func update(geometry: NotchGeometry) {
        guard geometry != self.geometry else { return }
        self.geometry = geometry
    }

    // MARK: Snapshots

    func stage(phase: Phase, activity: ClosedActivity, tab: NotchTab = .home, draggingFiles: Bool = false) {
        self.phase = phase
        self.activity = activity
        self.tab = tab
        isDraggingFiles = draggingFiles
    }
}
