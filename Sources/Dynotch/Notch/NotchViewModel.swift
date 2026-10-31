import AppKit
import Combine
import SwiftUI

/// The size of the black notch body (flares excluded) and its corner radii.
struct NotchMetrics: Equatable {
    var width: CGFloat
    var height: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var outerWidth: CGFloat { width + topRadius * 2 }
}

/// The closed notch: the hardware cutout in the middle, with matching "ears"
/// either side for live activities and an optional row underneath. A second
/// activity's glyph goes at the end of the right ear, and both ears grow to fit it.
/// A notice's row underneath can widen the notch too, up to `maxRowWidth`.
struct ClosedLayout: Equatable {
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var earWidth: CGFloat
    var rowHeight: CGFloat

    /// The second activity's glyph, and the gap before it.
    static let glyphSize: CGFloat = 16
    static let glyphSpacing: CGFloat = 8
    /// The widest a notice's second row makes the notch; longer text is cut off.
    static let maxRowWidth: CGFloat = 420

    var totalWidth: CGFloat { notchWidth + earWidth * 2 }
    var totalHeight: CGFloat { notchHeight + rowHeight }

    init(activity: ClosedActivity, secondary: CompactActivity?, notch: CGSize) {
        self.init(besideCamera: activity, notch: notch)
        if secondary != nil {
            earWidth = activity == .idle ? notch.height + 6 : earWidth + Self.glyphSize + Self.glyphSpacing
        }
        earWidth = max(earWidth, Self.rowEarWidth(for: activity, notch: notch))
    }

    init(activity: ClosedActivity, notch: CGSize) {
        self.init(activity: activity, secondary: nil, notch: notch)
    }

    /// How wide each ear must be for a notice's second row to fit, measured in the row's font.
    private static func rowEarWidth(for activity: ClosedActivity, notch: CGSize) -> CGFloat {
        guard case .notice(let notice) = activity, case .info = notice.kind, let detail = notice.detail else { return 0 }
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let text = (detail as NSString).size(withAttributes: [.font: font]).width
        // The row's padding either side, and a little slack so the text never truncates early.
        let row = min(text.rounded(.up) + 36, maxRowWidth)
        return max(0, (row - notch.width) / 2)
    }

    /// The ears for what sits beside the camera.
    private init(besideCamera activity: ClosedActivity, notch: CGSize) {
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
        case .countdown(let countdown):
            // The ring and up to ten letters of the name on the left, the time at its widest on the right.
            let name = CGFloat(min(countdown.name.count, 10)) * 7
            let time: CGFloat = countdown.duration >= 3600 ? 56 : countdown.duration >= 600 ? 42 : 34
            earWidth = max(64, 10 + 17 + 6 + name + 6, 11 + time + 8)
            rowHeight = 0
        case .stopwatch:
            earWidth = 72
            rowHeight = 0
        case .download:
            // Room for a size like "482.3 MB" on the right.
            earWidth = 78
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
        /// `glance`: the live thing with a control or two, from resting the pointer on the notch.
        case closed, hovering, glance, open
    }

    @Published private(set) var geometry: NotchGeometry
    @Published private(set) var phase: Phase = .closed {
        didSet {
            guard (oldValue == .glance) != (phase == .glance) else { return }
            LiveActivityCenter.shared.glanceChanged(isGlancing: phase == .glance)
        }
    }
    @Published var tab: NotchTab = .home
    /// Files are being dragged toward the notch; the tray shows its drop zones.
    @Published var isDraggingFiles = false
    @Published private(set) var activity: ClosedActivity
    /// A second activity, shown as a glyph at the end of the right ear.
    @Published private(set) var secondary: CompactActivity?
    /// A context menu is open; the notch must not close under it.
    @Published var isMenuOpen = false
    /// The command field covers the tabs. The panel takes the keyboard while it's up.
    @Published private(set) var isCommandMode = false
    @Published var commandQuery = "" {
        didSet { commandResults = CommandEngine.results(for: commandQuery, in: self) }
    }
    /// What the command field offers for `commandQuery`, worked out as it changes.
    @Published private(set) var commandResults: [CommandResult] = []

    /// The glance has turned to the recent list.
    @Published private(set) var isShowingRecent = false
    private var clickedForGlance = Date.distantPast

    /// Something was dragged out of the tray and the drag hasn't ended yet.
    @Published var isDraggingOut = false
    var onOpen: (() -> Void)?
    /// A swipe over the Nook's stack of widgets: true for the next card, false for the one before.
    let stackTurns = PassthroughSubject<Bool, Never>()

    private var cancellables = Set<AnyCancellable>()

    init(geometry: NotchGeometry) {
        self.geometry = geometry
        let center = LiveActivityCenter.shared
        activity = center.content.activity
        secondary = center.content.secondary
        center.$content
            .dropFirst()
            .sink { [weak self] content in
                withAnimation(.notchActivity) {
                    self?.activity = content.activity
                    self?.secondary = content.secondary
                }
            }
            .store(in: &cancellables)
        // Open size and enabled tabs live in settings.
        AppSettings.shared.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    var isOpen: Bool { phase == .open }
    var isGlancing: Bool { phase == .glance }

    var shouldStayOpen: Bool { isMenuOpen || isDraggingFiles || isDraggingOut }

    /// The line a virtual notch rests as, and how it swells under the pointer.
    static let lineHeight: CGFloat = 3
    static let lineHoverHeight: CGFloat = 5

    /// The notch is drawn as a faint line: a virtual notch set to one, closed, with nothing to show.
    var isLine: Bool {
        geometry.isLine && (phase == .closed || phase == .hovering) && activity == .idle && secondary == nil
    }

    /// What the glance shows, from what's live right now.
    var glanceContent: GlanceContent {
        if isShowingRecent { return .recent(rows: LiveActivityCenter.shared.recents.count) }
        return GlanceContent(activity: activity)
    }

    /// A double-click that brought up the glance shouldn't land its second click on a button that
    /// has just appeared under it, like Join.
    var acceptsNoticeButtons: Bool {
        Date.now.timeIntervalSince(clickedForGlance) > NSEvent.doubleClickInterval
    }

    /// A notice with buttons is showing. They're in the glance, so that's where a click goes.
    var noticeHasActions: Bool {
        if case .notice(let notice) = activity { return !notice.actions.isEmpty }
        return false
    }

    /// The open notch with the command field up: tall enough for its rows, at least as tall as the tabs.
    static func commandHeight(rows: Int, closedHeight: CGFloat) -> CGFloat {
        max(closedHeight, NotchTheme.headerControlHeight) + 92 + 32 * CGFloat(min(max(rows, 1), CommandEngine.maximumResults))
    }

    /// The tallest the open notch gets, so its panel always has room.
    static func tallestOpenHeight(closedHeight: CGFloat) -> CGFloat {
        max(AppSettings.shared.openHeight, commandHeight(rows: CommandEngine.maximumResults, closedHeight: closedHeight))
    }

    /// The tab on screen: the tray while files are dragged in, otherwise the chosen one if it's enabled.
    var visibleTab: NotchTab {
        if isDraggingFiles { return .tray }
        return AppSettings.shared.enabledTabs.contains(tab) ? tab : .home
    }

    var closedLayout: ClosedLayout {
        ClosedLayout(activity: activity, secondary: secondary, notch: geometry.closedSize)
    }

    var metrics: NotchMetrics {
        let settings = AppSettings.shared
        switch phase {
        case .open:
            let theme = settings.theme
            var height = settings.openHeight
            if isCommandMode {
                height = max(height, Self.commandHeight(rows: commandResults.count, closedHeight: geometry.closedSize.height))
            }
            return NotchMetrics(width: settings.openWidth, height: height,
                                topRadius: theme.topRadius, bottomRadius: theme.bottomRadius)
        case .glance:
            let closed = geometry.closedSize
            return NotchMetrics(width: min(settings.openWidth, closed.width + GlanceContent.earWidth * 2),
                                height: closed.height + glanceContent.extraHeight,
                                topRadius: 8, bottomRadius: 22)
        case .closed, .hovering:
            let hovering = phase == .hovering
            if isLine {
                // Flat along the top edge with rounded bottom corners. Hovering swells it, like the notch.
                return NotchMetrics(width: geometry.closedSize.width + (hovering ? 14 : 0),
                                    height: hovering ? Self.lineHoverHeight : Self.lineHeight,
                                    topRadius: 0, bottomRadius: hovering ? 2.5 : 1.5)
            }
            let layout = closedLayout
            return NotchMetrics(width: layout.totalWidth + (hovering ? 14 : 0),
                                height: layout.totalHeight + (hovering ? 3 : 0),
                                topRadius: NotchTheme.closedTopRadius,
                                bottomRadius: NotchTheme.closedBottomRadius(hasRow: layout.rowHeight > 0, isHovering: hovering))
        }
    }

    func open(tab: NotchTab? = nil) {
        if let tab { self.tab = tab }
        guard phase != .open else { return }
        withAnimation(.notchOpen) {
            phase = .open
            isShowingRecent = false
        }
        onOpen?()
        NowPlayingService.shared.refresh()
    }

    /// A click on the closed notch: the glance, for a notice's buttons, and otherwise the whole notch.
    func activate() {
        if noticeHasActions {
            clickedForGlance = .now
            glance()
        } else {
            open()
        }
    }

    /// Turns the glance to the recent list.
    func showRecent() {
        LiveActivityCenter.shared.markRecentsSeen()
        glance()
        withAnimation(.notchGlance) { isShowingRecent = true }
    }

    /// Grows the hovered notch into a glance at what's live.
    func glance() {
        guard phase == .closed || phase == .hovering else { return }
        withAnimation(.notchGlance) { phase = .glance }
    }

    func close() {
        guard phase != .closed else { return }
        withAnimation(.notchClose) {
            phase = .closed
            isDraggingFiles = false
            isCommandMode = false
            isShowingRecent = false
        }
        commandQuery = ""
    }

    func setHovering(_ hovering: Bool) {
        guard phase == .closed || phase == .hovering else { return }
        let next: Phase = hovering ? .hovering : .closed
        guard next != phase else { return }
        withAnimation(.notchHover) { phase = next }
    }

    // MARK: Command field

    /// Puts the command field over the tabs, with `text` typed into it.
    func beginCommand(_ text: String = "") {
        commandQuery = text
        isCommandMode = true
        // The shortcuts are commands too, and they're only listed once asked for.
        if ShortcutsService.shared.all.isEmpty {
            Task { await ShortcutsService.shared.reload() }
        }
    }

    /// Back to the tab that was showing.
    func endCommand() {
        guard isCommandMode else { return }
        isCommandMode = false
        commandQuery = ""
    }

    /// Escape: clears what's typed, then leaves the field.
    func escapeCommand() {
        if commandQuery.isEmpty {
            withAnimation(.notchTab) { endCommand() }
        } else {
            commandQuery = ""
        }
    }

    /// Runs a result, then gets out of the way: the notch closes unless the result opened a tab.
    func run(_ result: CommandResult) {
        guard let action = result.action else { return }
        switch action(self) {
        case .close:
            close()
        case .stay:
            withAnimation(.notchTab) { endCommand() }
        case .fill(let text):
            commandQuery = text
        }
    }

    func update(geometry: NotchGeometry) {
        guard geometry != self.geometry else { return }
        // Switching a virtual notch between the notch and the line redraws the closed notch.
        withAnimation(.notchActivity) { self.geometry = geometry }
    }

    // MARK: Snapshots

    func stage(phase: Phase, activity: ClosedActivity, secondary: CompactActivity? = nil, tab: NotchTab = .home,
               draggingFiles: Bool = false, command: String? = nil, showingRecent: Bool = false) {
        self.phase = phase
        isShowingRecent = showingRecent
        self.activity = activity
        self.secondary = secondary
        self.tab = tab
        isDraggingFiles = draggingFiles
        isCommandMode = command != nil
        commandQuery = command ?? ""
    }
}
