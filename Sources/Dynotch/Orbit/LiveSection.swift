import SwiftUI

/// One thing that's live now, as a row in Live: what it is, when, and what can be done about it.
struct LiveItem: Identifiable {
    enum Rank: Int, Comparable {
        /// It waits on you: a tool call, a meeting about to start.
        case needsYou
        /// Recording the screen.
        case recording
        case music
        /// A timer, nearest end first.
        case timer
        /// A run, a download, a script.
        case running
        case agent
        case event
        /// A switch that's been left on, like Keep Awake.
        case status

        static func < (lhs: Rank, rhs: Rank) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let id: String
    let rank: Rank
    /// Within a rank, sooner first.
    var order: Double = 0
    var time: String
    var symbol: String
    var title: String
    var subtitle: String?
    var status: String?
    var statusColor: Color?
    var needsYou = false
    var actions: [RowAction] = []
    /// The section a click on the row opens.
    var opens: NotchTab?
}

/// Everything live, ranked. Built from the services each time Live draws, so it's never stale.
@MainActor
enum LiveFeed {
    /// The most rows Live shows; the rest are a count in its title line.
    static let mostShown = 5

    static func items(at now: Date, viewModel: NotchViewModel?, theme: NotchTheme) -> [LiveItem] {
        let settings = AppSettings.shared
        var items: [LiveItem] = []

        // Tool calls waiting. Allow is only ever given in the glance, where the whole command shows,
        // so the row's button reviews it there.
        let deck = AgentDeck.shared
        if settings.liveAgents {
            for (index, approval) in deck.approvals.enumerated() {
                items.append(LiveItem(
                    id: "approval-\(approval.id)", rank: .needsYou, order: Double(index), time: "Now", symbol: "terminal",
                    title: "Claude Code · \(approval.project)", subtitle: approval.asking, status: "Waiting",
                    statusColor: theme.accent, needsYou: true,
                    actions: index == 0 ? [RowAction(title: "Review", role: .primary) { viewModel?.showApproval() }] : [],
                    opens: .agents))
            }
        }

        let recorder = ScreenRecorder.shared
        if recorder.isActive {
            items.append(LiveItem(
                id: "recording", rank: .recording, time: Format.duration(recorder.elapsed), symbol: "record.circle",
                title: "Recording the screen", subtitle: recorder.plan.map { _ in "Stop from here or the menu bar" },
                status: "Recording", statusColor: theme.alert,
                actions: [RowAction(title: "Stop", role: .risk) {
                    guard viewModel?.acceptsStop ?? true else { return }
                    recorder.stop()
                }]))
        }

        let pomodoro = PomodoroTimer.shared
        if settings.liveTimer, pomodoro.isRunning || pomodoro.progress > 0 {
            let next = pomodoro.endDate.map { "Ends at \($0.formatted(date: .omitted, time: .shortened))" }
            items.append(LiveItem(
                id: "pomodoro", rank: .timer, order: pomodoro.endDate?.timeIntervalSince(now) ?? .greatestFiniteMagnitude,
                time: Format.duration(pomodoro.remaining), symbol: "timer",
                title: "\(pomodoro.phase.title) · round \(pomodoro.completedSessions + 1)",
                subtitle: pomodoro.isRunning ? next : "Paused",
                status: pomodoro.isRunning ? "Running" : "Paused", statusColor: pomodoro.isRunning ? theme.live : nil,
                actions: [RowAction.icon("forward.end.fill", "Skip") { pomodoro.skip() },
                          RowAction.icon(pomodoro.isRunning ? "pause.fill" : "play.fill", pomodoro.isRunning ? "Pause" : "Resume",
                                         role: .primary) { pomodoro.toggle() }],
                opens: .focus))
        }

        let timers = TimerStore.shared
        for countdown in settings.liveCountdowns ? timers.countdowns : [] {
            let left = countdown.remaining(at: now)
            items.append(LiveItem(
                id: "countdown-\(countdown.id)", rank: .timer, order: left,
                time: Format.duration(left), symbol: "hourglass", title: countdown.name.isEmpty ? "Timer" : countdown.name,
                subtitle: countdown.endDate.map { "Ends at \($0.formatted(date: .omitted, time: .shortened))" } ?? "Paused",
                status: countdown.isRunning ? "Running" : "Paused", statusColor: countdown.isRunning ? theme.live : nil,
                actions: [RowAction.icon("xmark", "Cancel") { timers.cancel(countdown) },
                          RowAction.icon(countdown.isRunning ? "pause.fill" : "play.fill", countdown.isRunning ? "Pause" : "Resume",
                                         role: .primary) { timers.togglePause(countdown) }],
                opens: .focus))
        }
        if settings.liveCountdowns, !timers.stopwatch.isReset {
            items.append(LiveItem(
                id: "stopwatch", rank: .timer, order: .greatestFiniteMagnitude,
                time: Format.duration(timers.stopwatch.elapsed(at: now)), symbol: "stopwatch", title: "Stopwatch",
                subtitle: timers.stopwatch.isRunning ? "Counting up" : "Stopped",
                status: timers.stopwatch.isRunning ? "Running" : "Stopped", statusColor: timers.stopwatch.isRunning ? theme.live : nil,
                actions: [RowAction.icon("arrow.counterclockwise", "Reset") { timers.resetStopwatch() },
                          RowAction.icon(timers.stopwatch.isRunning ? "pause.fill" : "play.fill",
                                         timers.stopwatch.isRunning ? "Stop" : "Start", role: .primary) { timers.toggleStopwatch() }],
                opens: .focus))
        }

        let media = NowPlayingService.shared
        if settings.liveMusic, let track = media.track {
            let player = media.player.map { " · \($0.name)" } ?? ""
            items.append(LiveItem(
                id: "music", rank: .music, time: Format.duration(media.elapsed(at: now)), symbol: "music.note",
                title: track.title, subtitle: track.artist + player,
                status: media.isPlaying ? "Playing" : "Paused", statusColor: media.isPlaying ? theme.live : nil,
                actions: [RowAction.icon("backward.fill", "Previous") { media.previous() },
                          RowAction.icon(media.isPlaying ? "pause.fill" : "play.fill", media.isPlaying ? "Pause" : "Play",
                                         role: .primary) { media.playPause() },
                          RowAction.icon("forward.fill", "Next") { media.next() }],
                opens: .music))
        }

        if settings.liveCI, let run = CIMonitor.shared.run {
            let open = run.openAction
            items.append(LiveItem(
                id: "ci-\(run.id)", rank: .running, time: run.elapsedText, symbol: "arrow.triangle.branch",
                title: "\(run.workflow) · \(run.repository)", subtitle: run.summary, status: run.statusText,
                statusColor: run.phase == .running ? theme.primary : theme.secondary,
                actions: open.map { action in [RowAction(title: action.title) { if let viewModel { action.perform(in: viewModel) } }] } ?? []))
        }

        let downloads = DownloadMonitor.shared
        if settings.liveDownloads, !downloads.downloads.isEmpty {
            let received = downloads.downloads.reduce(Int64(0)) { $0 + $1.received }
            let first = downloads.downloads[0].id
            items.append(LiveItem(
                id: "downloads", rank: .running,
                time: downloads.fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? Format.bytes(received),
                symbol: "arrow.down.circle",
                title: downloads.downloads.count == 1 ? first : "\(downloads.downloads.count) downloads",
                subtitle: Format.bytes(received) + " so far", status: "Downloading", statusColor: theme.primary))
        }

        if settings.liveAgents {
            for session in deck.sessions {
                if case .waiting = session.state { continue }
                if case .done = session.state { continue }
                items.append(LiveItem(
                    id: "session-\(session.id)", rank: .agent, order: -session.since.timeIntervalSince1970, time: "",
                    symbol: "sparkle", title: "Claude Code · \(session.project)", subtitle: session.line(at: now),
                    status: "Working", statusColor: theme.primary, opens: .agents))
            }
        }

        // A script's progress, as `dynotch progress` reports it.
        if settings.liveScripts {
            for activity in ScriptActivityStore.shared.activities {
                items.append(LiveItem(
                    id: "script-\(activity.key)", rank: .running, order: 1, time: activity.percentText ?? "", symbol: "terminal",
                    title: activity.key, subtitle: activity.detail, status: "Running", statusColor: theme.primary))
            }
        }

        // The event going on now, and the next one within three hours. Each gets its own row, so a
        // meeting about to start isn't hidden behind one that's running over.
        let calendar = CalendarService.shared
        let upcoming = settings.liveEvents ? calendar.events.filter { !$0.isAllDay && $0.end > now } : []
        let current = upcoming.first { $0.isHappening(at: now) }
        let next = upcoming.first { $0.start > now && $0.start.timeIntervalSince(now) < 3 * 3600 }
        for event in [current, next].compactMap({ $0 }) {
            let isNow = event.isHappening(at: now)
            let untilStart = event.start.timeIntervalSince(now)
            // Worth an interruption: about to start, or only just started, with a call to join.
            let isSoon = !isNow && untilStart < 15 * 60
            let justStarted = isNow && now.timeIntervalSince(event.start) < 10 * 60
            let needsYou = event.meetingURL != nil && (isSoon || justStarted)
            var actions: [RowAction] = []
            if let url = event.meetingURL {
                actions.append(RowAction(title: "Join", role: .primary) { NSWorkspace.shared.open(url) })
            }
            items.append(LiveItem(
                id: "event-\(event.id)", rank: needsYou ? .needsYou : .event, order: untilStart,
                time: event.start.formatted(date: .omitted, time: .shortened), symbol: "calendar", title: event.title,
                subtitle: isNow ? "Until \(event.end.formatted(date: .omitted, time: .shortened))"
                    : "Starts \(Format.countdown(to: event.start, from: now))",
                status: isNow ? "Now" : isSoon ? "Soon" : nil, statusColor: isNow ? theme.live : isSoon ? theme.accent : nil,
                needsYou: needsYou, actions: actions, opens: .calendar))
        }

        if settings.liveMicMuted, MicMonitor.shared.isMuted {
            items.append(LiveItem(
                id: "mic", rank: .status, order: 0, time: "", symbol: "mic.slash", title: "Microphone muted",
                subtitle: "Nothing you say is heard", status: "Muted",
                actions: [RowAction(title: "Unmute") { MicMonitor.shared.setMuted(false) }], opens: .stats))
        }
        if settings.liveFocus, let focus = FocusMonitor.shared.mode {
            items.append(LiveItem(
                id: "focus-mode", rank: .status, order: 1, time: "", symbol: focus.symbol, title: "\(focus.name) Focus",
                subtitle: "Notifications are quiet", status: "On"))
        }

        let toggles = QuickToggles.shared
        if settings.liveKeepAwake, toggles.isKeepingAwake {
            items.append(LiveItem(
                id: "awake", rank: .status, order: 2, time: "", symbol: "cup.and.saucer", title: "Keeping the Mac awake",
                subtitle: toggles.keepAwakeDescription, status: "On",
                actions: [RowAction(title: "Turn Off") { toggles.stopKeepingAwake() }], opens: .stats))
        }

        return items.sorted { ($0.rank, $0.order) < ($1.rank, $1.order) }
    }
}

/// Live now: whatever's going on, most urgent first, as ranked rows. Where the notch opens.
struct LiveSectionView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var media = NowPlayingService.shared
    @ObservedObject private var pomodoro = PomodoroTimer.shared
    @ObservedObject private var timers = TimerStore.shared
    @ObservedObject private var deck = AgentDeck.shared
    @ObservedObject private var calendar = CalendarService.shared
    @ObservedObject private var downloads = DownloadMonitor.shared
    @ObservedObject private var ci = CIMonitor.shared
    @ObservedObject private var recorder = ScreenRecorder.shared
    @ObservedObject private var toggles = QuickToggles.shared
    @ObservedObject private var center = LiveActivityCenter.shared
    @ObservedObject private var scripts = ScriptActivityStore.shared
    @ObservedObject private var mic = MicMonitor.shared
    @ObservedObject private var focus = FocusMonitor.shared
    @Environment(\.notchTheme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = isSnapshot ? SnapshotClock.now : context.date
            let items = LiveFeed.items(at: now, viewModel: viewModel, theme: theme)
            let shown = Array(items.prefix(LiveFeed.mostShown))
            VStack(spacing: 0) {
                if shown.isEmpty {
                    EmptyState(symbol: "waveform.path.ecg",
                               message: "Nothing's live. Music, timers, agents and your next meeting show up here.")
                } else {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { OrbitRowDivider() }
                        OrbitRow(id: item.id, time: item.time, symbol: item.symbol, title: item.title,
                                 subtitle: item.subtitle, status: item.status, statusColor: item.statusColor,
                                 needsYou: item.needsYou, actions: item.actions,
                                 forcesHover: isSnapshot && index == 0 && item.needsYou) {
                            if let tab = item.opens {
                                withAnimation(.notchTab) { viewModel.tab = tab }
                            }
                        }
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                    }
                    Spacer(minLength: 0)
                }
            }
            .animation(.notchActivity, value: shown.map(\.id))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .orbitHeader("Live now", subtitle: subtitle(count: items.count, at: now)) {
                // The notices that have come and gone. They're listed in the glance.
                if !center.recents.isEmpty {
                    OrbitButton(title: center.unseenRecents > 0 ? "Recent · \(center.unseenRecents)" : "Recent", symbol: "bell",
                                style: .ghost, help: "Recent notices") {
                        viewModel.showRecent()
                    }
                }
            }
        }
    }

    private func subtitle(count: Int, at now: Date) -> String {
        let things = count == 0 ? "Nothing" : count == 1 ? "1 thing" : "\(count) things"
        return things + " · " + now.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// Rows plus the band and the command field: Live grows with what's in it.
    static func preferredHeight(rows: Int, band: CGFloat, actionBar: Bool = false) -> CGFloat {
        let rows = CGFloat(min(max(rows, 2), LiveFeed.mostShown))
        return band + 8 + rows * NotchTheme.rowHeight + (rows - 1) + 12
            + (actionBar ? RowActionBar.height + 8 : 0)
            + NotchTheme.commandFieldHeight + NotchTheme.commandFieldGap + 14
    }
}

/// The moment snapshots show as now, so the sample times match the rest of the run.
@MainActor
enum SnapshotClock {
    static var now = Date.now
}
