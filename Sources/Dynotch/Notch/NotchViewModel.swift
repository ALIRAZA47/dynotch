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
    /// Room along the foot for a script's progress line.
    var footHeight: CGFloat = 0

    /// The second activity's glyph, and the gap before it.
    static let glyphSize: CGFloat = 16
    static let glyphSpacing: CGFloat = 8
    /// The widest a notice's second row makes the notch; longer text is cut off.
    static let maxRowWidth: CGFloat = 420
    /// The line along the foot, the gap under it, and how far it stays clear of the bottom corners.
    static let footLineHeight: CGFloat = 3
    static let footGap: CGFloat = 5
    static let footInset: CGFloat = 14

    var totalWidth: CGFloat { notchWidth + earWidth * 2 }
    var totalHeight: CGFloat { notchHeight + rowHeight + footHeight }

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
        let text: CGFloat
        if case .lyrics(let rowWidth) = activity {
            text = rowWidth
        } else if case .notice(let notice) = activity, case .info = notice.kind, let detail = notice.detail {
            text = (detail as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width
        } else {
            return 0
        }
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
        case .lyrics:
            earWidth = notch.height + 8
            rowHeight = 26
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
        case .recording:
            // Room for "1:02:45" on the right, as for the stopwatch.
            earWidth = 72
            rowHeight = 0
        case .script(let script):
            // The symbol and up to ten letters of the name on the left, "100%" on the right.
            let name = CGFloat(min(script.key.count, 10)) * 7
            earWidth = max(64, 10 + 14 + 6 + name + 6, 11 + 36 + 8)
            rowHeight = 0
            footHeight = Self.footLineHeight + Self.footGap
        case .ci(let run):
            // The workflow's name, up to twelve letters, on the left.
            earWidth = max(64, 10 + 14 + 6 + CGFloat(min(run.workflow.count, 12)) * 7 + 6)
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
            if phase == .glance { glanceAppeared = .now }
            LiveActivityCenter.shared.glanceChanged(isGlancing: phase == .glance)
        }
    }
    /// The Tray's two sides: its files, and what's been copied.
    enum TraySide: Hashable {
        case files, clipboard
    }

    @Published var tab: NotchTab = .home
    @Published var traySide = TraySide.files
    /// What's typed in the Clipboard side's search field.
    @Published var clipSearch = ""
    /// Files are being dragged toward the notch; the tray shows its drop zones.
    @Published var isDraggingFiles = false {
        didSet { if !isDraggingFiles { isDraggingImages = false } }
    }
    /// An image is among them, so the tray offers what can be done with one. It ends with the drag.
    @Published var isDraggingImages = false
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
    /// The glance has turned to Claude's usage.
    @Published private(set) var isShowingUsage = false
    /// Review has turned the glance to the tool calls waiting, which takes it from a recording's Stop.
    @Published private(set) var isReviewing = false
    /// When the latest press on the notch began. Allow goes by this rather than by when it's let go.
    var lastPress = Date.distantPast
    private var clickedForGlance = Date.distantPast
    private var glanceAppeared = Date.distantPast

    /// Something was dragged out of the tray and the drag hasn't ended yet.
    @Published var isDraggingOut = false
    var onOpen: (() -> Void)?
    /// The open notch is turning to the glance, which is smaller, so the pointer may end up outside it.
    var onTurnToGlance: (() -> Void)?
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
        // The Agents tab comes and goes with the sessions, and an approval takes over the glance.
        AgentDeck.shared.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // Review was for those waiting then. The next to come waits for a recording like any other.
        AgentDeck.shared.$approvals
            .filter(\.isEmpty)
            .sink { [weak self] _ in self?.isReviewing = false }
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
        // A tool call can wait for a recording, since Claude Code's own prompt is still there. Review
        // asks for it by name, so that brings it up all the same.
        if !isRecording || isReviewing, AppSettings.shared.liveAgents, let approval = AgentDeck.shared.approvals.first {
            return .approval(approval)
        }
        if isShowingUsage, AppSettings.shared.liveUsage { return .usage }
        // The recording's for as long as it runs, whatever the closed notch shows, so Stop stays put.
        if isRecording { return .recording }
        return GlanceContent(activity: activity)
    }

    /// A double-click that brought up the glance shouldn't land its second click on a button that
    /// has just appeared under it, like Join.
    var acceptsNoticeButtons: Bool {
        Date.now.timeIntervalSince(clickedForGlance) > NSEvent.doubleClickInterval
    }

    /// A notice with buttons is showing, or a tool call is waiting. Both are in the glance, so that's
    /// where a click goes.
    var noticeHasActions: Bool {
        if AppSettings.shared.liveAgents, !AgentDeck.shared.approvals.isEmpty { return true }
        if case .notice(let notice) = activity { return !notice.actions.isEmpty }
        return false
    }

    /// A recording is going, in the notch itself or as the dot beside a notice.
    var isRecording: Bool { activity == .recording || secondary == .recording }

    /// How long Stop stays dead once the glance has come up.
    static let stopGate: TimeInterval = 0.4

    /// Stop refuses clicks for a moment after the glance appears, however it appeared. A click meant
    /// for the notch can land on a Stop that has just arrived under it, whether the pointer resting
    /// there or a click raised the glance, and it would end the recording. `acceptsNoticeButtons`
    /// only knows of clicks.
    var acceptsStop: Bool {
        Date.now.timeIntervalSince(glanceAppeared) >= Self.stopGate
    }

    /// Stop has come up in a glance that was already there, when a tool call it was showing went.
    func stopAppeared() {
        glanceAppeared = .now
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
            let content = glanceContent
            var width = closed.width + GlanceContent.earWidth * 2
            // A command shows whole, so the more room it has the fewer lines it takes.
            if case .approval = content { width = max(width, ApprovalGlance.width) }
            return NotchMetrics(width: min(settings.openWidth, width), height: closed.height + content.extraHeight,
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
        // Whatever opens the Tray by name means its files, like a screenshot's Show.
        if tab == .tray { traySide = .files }
        guard phase != .open else { return }
        withAnimation(.notchOpen) {
            phase = .open
            isShowingRecent = false
            isShowingUsage = false
            isReviewing = false
        }
        onOpen?()
        NowPlayingService.shared.refresh()
    }

    /// A click on the closed notch: the glance, for a notice's buttons or a recording's Stop, and
    /// otherwise the whole notch. It never stops a recording.
    func activate() {
        if noticeHasActions || isRecording {
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

    /// Turns the glance to Claude's usage, from the recent list too.
    func showUsage() {
        glance()
        withAnimation(.notchGlance) {
            isShowingRecent = false
            isShowingUsage = true
        }
    }

    /// Notes when a press began, by the event's own time, in case it waited its turn on a busy main thread.
    func notePress(_ event: NSEvent) {
        lastPress = Date.now.addingTimeInterval(event.timestamp - ProcessInfo.processInfo.systemUptime)
    }

    /// Turns to the tool call waiting for an answer, which is only ever answered in the glance.
    func showApproval() {
        clickedForGlance = .now
        isReviewing = true
        guard phase == .open else { return glance() }
        onTurnToGlance?()
        withAnimation(.notchGlance) { phase = .glance }
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
            isShowingUsage = false
            isReviewing = false
        }
        commandQuery = ""
        clipSearch = ""
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
            Task {
                await ShortcutsService.shared.reload()
                // One of them may be among what's offered on an empty field.
                if isCommandMode, commandQuery.isEmpty { commandResults = CommandEngine.results(for: "", in: self) }
            }
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
            CommandEngine.noteUse(of: result.id)
            close()
        case .stay:
            CommandEngine.noteUse(of: result.id)
            withAnimation(.notchTab) { endCommand() }
        case .fill(let text):
            // It's only asked for more: what comes of that is what counts.
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
               traySide: TraySide = .files, clipSearch: String = "",
               draggingFiles: Bool = false, draggingImages: Bool = false, command: String? = nil, showingRecent: Bool = false,
               showingUsage: Bool = false) {
        self.phase = phase
        isShowingRecent = showingRecent
        isShowingUsage = showingUsage
        isReviewing = false
        self.activity = activity
        self.secondary = secondary
        self.tab = tab
        self.traySide = traySide
        self.clipSearch = clipSearch
        isDraggingFiles = draggingFiles
        isDraggingImages = draggingImages
        isCommandMode = command != nil
        commandQuery = command ?? ""
    }
}
