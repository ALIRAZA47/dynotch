import SwiftUI

/// What the glance shows: the activity in the closed notch, or a meeting about to start, or paused
/// music, and otherwise a look at the day.
enum GlanceContent: Equatable {
    case music
    case pomodoro
    case countdown(Countdown)
    case stopwatch
    case download
    case notice(LiveNotice)
    case event(CalendarService.Event)
    case today
    /// The recent list, with this many rows.
    case recent(rows: Int)

    /// Each side of the glance beside the camera.
    static let earWidth: CGFloat = 100
    /// The most the recent list shows.
    static let recentRows = 4
    private static let recentRowHeight: CGFloat = 30

    @MainActor
    init(activity: ClosedActivity) {
        switch activity {
        case .music, .trackPeek:
            self = .music
            return
        case .timer:
            self = .pomodoro
            return
        case .countdown(let countdown):
            self = .countdown(countdown)
            return
        case .stopwatch:
            self = .stopwatch
            return
        case .download:
            self = .download
            return
        case .notice(let notice):
            // A volume or brightness meter is nothing to glance at.
            if case .info = notice.kind {
                self = .notice(notice)
                return
            }
        case .idle:
            break
        }
        let now = Date.now
        if let event = GlanceContent.meetingSoon(at: now) {
            self = .event(event)
        } else if NowPlayingService.shared.track != nil {
            self = .music
        } else {
            self = .today
        }
    }

    /// How much taller than the closed notch the glance is.
    var extraHeight: CGFloat {
        switch self {
        case .music: 70
        case .pomodoro, .countdown, .stopwatch, .event: 54
        case .download, .notice: 50
        case .today: 52
        case .recent(let rows): CGFloat(rows) * Self.recentRowHeight + 10
        }
    }

    /// A timed event that's on now or starts within a quarter of an hour.
    @MainActor
    static func meetingSoon(at now: Date) -> CalendarService.Event? {
        let calendar = CalendarService.shared
        guard calendar.hasEventAccess else { return nil }
        return calendar.events(on: now).first { !$0.isAllDay && $0.end > now && $0.start.timeIntervalSince(now) < 15 * 60 }
    }
}

/// What resting the pointer on the notch shows: the live thing with a control or two. A click
/// anywhere else on it, or a swipe down, opens the whole notch.
struct GlanceView: View {
    @ObservedObject var viewModel: NotchViewModel
    // The glance follows the music and the calendar as they change.
    @ObservedObject private var media = NowPlayingService.shared
    @ObservedObject private var calendar = CalendarService.shared
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let band = viewModel.geometry.closedSize.height
        Group {
            switch viewModel.glanceContent {
            case .music: MusicGlance(viewModel: viewModel, band: band)
            case .pomodoro: PomodoroGlance(band: band)
            case .countdown(let countdown): CountdownGlance(countdown: countdown, band: band)
            case .stopwatch: StopwatchGlance(band: band)
            case .download: DownloadGlance(band: band)
            case .notice(let notice): NoticeGlance(notice: notice, viewModel: viewModel, band: band)
            case .event(let event): EventGlance(event: event, band: band)
            case .today: TodayGlance(viewModel: viewModel, band: band)
            case .recent: RecentGlance(viewModel: viewModel, band: band)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { viewModel.open() }
        // The glance is black to its edge whatever the open notch is made of, so its glass is lit as
        // glass on black: a pane on Liquid Glass darkens the glass, and on black it would vanish.
        .environment(\.notchTheme, theme.onBlack)
    }
}

private extension NotchTheme {
    /// This look on the black slab: the same accent, corners and contrast, with black's tokens.
    var onBlack: NotchTheme {
        var theme = self
        theme.material = .black
        return theme
    }
}

// MARK: Layout

/// The side of the picture at the glance's left: artwork, a ring, a date.
private let glancePicture: CGFloat = 46

/// The glance's places around the camera, as on an iPhone's Dynamic Island: a picture on the left
/// that reaches down from the top edge, controls in the right ear, two lines under the camera, and
/// sometimes a row along the bottom.
private struct GlanceLayout<Leading: View, Trailing: View, Center: View, Bottom: View>: View {
    let band: CGFloat
    let leading: Leading
    let trailing: Trailing
    let center: Center
    let bottom: Bottom

    init(band: CGFloat, @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing,
         @ViewBuilder center: () -> Center, @ViewBuilder bottom: () -> Bottom) {
        self.band = band
        self.leading = leading()
        self.trailing = trailing()
        self.center = center()
        self.bottom = bottom()
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            leading
                .frame(width: glancePicture, height: glancePicture)
                .padding(.leading, 14)
                .padding(.top, 10)
            trailing
                // Centered in the band, or in the tallest control's height when a short menu bar
                // makes the band shorter, so no control's lit top edge is cut off at the screen's edge.
                .frame(width: GlanceContent.earWidth - 12, height: max(band, 28), alignment: .trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 12)
            center
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 14 + glancePicture + 12)
                .padding(.trailing, 14)
                .padding(.top, band + 3)
            bottom
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.horizontal, 14)
                .padding(.bottom, 11)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension GlanceLayout where Bottom == EmptyView {
    init(band: CGFloat, @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing,
         @ViewBuilder center: () -> Center) {
        self.init(band: band, leading: leading, trailing: trailing, center: center) { EmptyView() }
    }
}

/// A round button in the glance's ear, a disc of glass with the tint's light in it: pause, play.
private struct GlanceCircleButton: View {
    let symbol: String
    let tint: Color
    let help: String
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 27, height: 27)
                .glass(.tint(tint), in: Circle(), isLit: hovering)
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The picture for a stopwatch or a notice: its symbol on a disc of glass holding the tint's light.
private struct GlanceDisc: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: glancePicture, height: glancePicture)
            .glass(.tint(tint), in: Circle())
    }
}

/// The two lines under the camera: what it is, then a quieter line about it.
private struct GlanceLines: View {
    let title: String
    var subtitle: String?
    var truncation: Text.TruncationMode = .tail
    @Environment(\.notchTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(NotchFont.glanceTitle)
                .foregroundStyle(theme.primary)
                .lineLimit(1)
                .truncationMode(truncation)
            if let subtitle {
                Text(subtitle)
                    .font(NotchFont.body)
                    .foregroundStyle(theme.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// Two lines under the camera: a quiet one, then the main one, large.
private struct GlanceFigure: View {
    let caption: String
    let figure: String
    let tint: Color
    @Environment(\.notchTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(caption)
                .font(NotchFont.body)
                .foregroundStyle(theme.secondary)
                .lineLimit(1)
            Text(figure)
                .font(NotchFont.figure(22))
                .foregroundStyle(tint)
                .contentTransition(.numericText(countsDown: true))
        }
    }
}

// MARK: Glances

private struct MusicGlance: View {
    @ObservedObject var viewModel: NotchViewModel
    let band: CGFloat
    @ObservedObject private var media = NowPlayingService.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var center = LiveActivityCenter.shared
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let tint = settings.artworkTint ? Color(nsColor: media.accent) : theme.accent
        GlanceLayout(band: band) {
            // The art's color falls on the black below it, as the player's does. No art, no light.
            ArtworkView(image: media.artwork, size: glancePicture, cornerRadius: 11,
                        glow: settings.artworkTint && media.artwork != nil ? tint : nil)
        } trailing: {
            HStack(spacing: 2) {
                IconButton(symbol: "backward.fill", size: 12, help: "Previous", action: media.previous)
                PlayButton(isPlaying: media.isPlaying, side: 28, action: media.playPause)
                IconButton(symbol: "forward.fill", size: 12, help: "Next", action: media.next)
            }
        } center: {
            HStack(spacing: 0) {
                GlanceLines(title: media.track?.title ?? "Nothing playing", subtitle: media.track?.artist ?? "")
                Spacer(minLength: 0)
                // The music fills the glance while it plays, so the recent list needs a way in here too.
                if center.unseenRecents > 0 {
                    GlanceChip(symbol: "bell.fill", tint: theme.secondary, text: "\(center.unseenRecents)") {
                        viewModel.showRecent()
                    }
                    .padding(.leading, 8)
                }
            }
        } bottom: {
            PlaybackScrubber(tint: tint)
        }
    }
}

private struct PomodoroGlance: View {
    let band: CGFloat
    @ObservedObject private var timer = PomodoroTimer.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        let color = timer.phase.color
        GlanceLayout(band: band) {
            ZStack {
                ProgressRing(progress: timer.progress, color: color, lineWidth: 4, halo: true)
                Image(systemName: timer.phase.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(color)
            }
            .padding(2)
        } trailing: {
            HStack(spacing: 4) {
                IconButton(symbol: "forward.end.fill", size: 11, idleOpacity: 0.6, help: "Skip to the next phase", action: timer.skip)
                GlanceCircleButton(symbol: timer.isRunning ? "pause.fill" : "play.fill", tint: color,
                                   help: timer.isRunning ? "Pause" : "Start", action: timer.toggle)
            }
        } center: {
            let session = min(timer.completedSessions + 1, settings.sessionsPerRound)
            GlanceFigure(caption: "\(timer.phase.title) · session \(session) of \(settings.sessionsPerRound)",
                         figure: Format.duration(timer.remaining), tint: color)
        }
    }
}

private struct CountdownGlance: View {
    let countdown: Countdown
    let band: CGFloat
    @ObservedObject private var store = TimerStore.shared
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        // The live one: the closed notch's copy only changes when the activity does.
        let countdown = store.countdowns.first { $0.id == self.countdown.id } ?? self.countdown
        let tint = countdown.isRunning ? TimerStore.tint : theme.secondary
        GlanceLayout(band: band) {
            ZStack {
                // Light runs round the ring only while it's counting.
                ProgressRing(progress: countdown.progress(at: store.now), color: tint, lineWidth: 4,
                             halo: countdown.isRunning)
                Image(systemName: "timer")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .padding(2)
        } trailing: {
            HStack(spacing: 4) {
                Button {
                    store.extend(countdown, by: 60)
                } label: {
                    Text("+1 min")
                        .font(NotchFont.bodyStrong)
                        .foregroundStyle(TimerStore.tint)
                        .padding(.horizontal, 9)
                        .frame(height: 25)
                        .glass(.tint(TimerStore.tint), in: Capsule(), isLit: hovering)
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableButtonStyle(scale: 0.94))
                .onHover { hovering = $0 }
                .animation(.notchHighlight, value: hovering)
                .help("A minute more")
                GlanceCircleButton(symbol: countdown.isRunning ? "pause.fill" : "play.fill", tint: TimerStore.tint,
                                   help: countdown.isRunning ? "Pause" : "Resume") { store.togglePause(countdown) }
            }
        } center: {
            GlanceFigure(caption: countdown.endDate.map { "\(countdown.name) · ends at \($0.formatted(date: .omitted, time: .shortened))" }
                            ?? "\(countdown.name) · paused",
                         figure: Format.duration(countdown.remaining(at: store.now).rounded(.up)), tint: tint)
        }
    }
}

private struct StopwatchGlance: View {
    let band: CGFloat
    @ObservedObject private var store = TimerStore.shared

    var body: some View {
        let stopwatch = store.stopwatch
        let tint = TimerStore.stopwatchTint
        GlanceLayout(band: band) {
            GlanceDisc(symbol: "stopwatch.fill", tint: tint)
        } trailing: {
            HStack(spacing: 4) {
                IconButton(symbol: "arrow.counterclockwise", size: 11, idleOpacity: 0.6, help: "Reset the stopwatch",
                           action: store.resetStopwatch)
                GlanceCircleButton(symbol: stopwatch.isRunning ? "pause.fill" : "play.fill", tint: tint,
                                   help: stopwatch.isRunning ? "Pause the stopwatch" : "Start the stopwatch",
                                   action: store.toggleStopwatch)
            }
        } center: {
            GlanceFigure(caption: stopwatch.isRunning ? "Stopwatch" : "Stopwatch · paused",
                         figure: Format.duration(stopwatch.elapsed(at: store.now)), tint: tint)
        }
    }
}

private struct DownloadGlance: View {
    let band: CGFloat
    @ObservedObject private var monitor = DownloadMonitor.shared

    var body: some View {
        GlanceLayout(band: band) {
            DownloadRing(fraction: monitor.fraction, lineWidth: 4, arrowSize: 15, halo: true)
                .padding(2)
        } trailing: {
            DownloadAmount()
        } center: {
            GlanceLines(title: title, subtitle: "Downloading to Downloads", truncation: .middle)
        }
    }

    /// The file's name, without the browser's partial-download extension.
    private var title: String {
        guard let first = monitor.downloads.first else { return "Downloading" }
        var name = first.id
        for suffix in [".download", ".crdownload", ".part", ".opdownload"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }
        let others = monitor.downloads.count - 1
        return others > 0 ? "\(name) and \(others) more" : name
    }
}

private struct NoticeGlance: View {
    let notice: LiveNotice
    @ObservedObject var viewModel: NotchViewModel
    let band: CGFloat
    @ObservedObject private var thumbnails = ThumbnailCache.shared

    var body: some View {
        GlanceLayout(band: band) {
            picture
                // A script's notice keeps its terminal badge, so it can't pass for one of Dynotch's own.
                .overlay(alignment: .bottomTrailing) {
                    if notice.fromScript { ScriptBadge().scaleEffect(1.6, anchor: .bottomTrailing) }
                }
        } trailing: {
            EmptyView()
        } center: {
            HStack(spacing: 0) {
                // A notice with only a detail, like a screenshot's, gives it the title's line.
                GlanceLines(title: notice.text.isEmpty ? (notice.detail ?? "") : notice.text,
                            subtitle: notice.text.isEmpty ? nil : notice.detail)
                Spacer(minLength: 0)
                ForEach(Array(buttons.enumerated()), id: \.offset) { index, action in
                    NoticeButton(action: action, isMain: index == 0) { action.perform(in: viewModel) }
                        .padding(.leading, 8)
                }
            }
        }
    }

    /// Two at most. A code keeps the room for itself, so the line beside the button can show it.
    private var buttons: [NoticeAction] {
        if case .copyCode = notice.actions.first?.kind { return Array(notice.actions.prefix(1)) }
        return Array(notice.actions.prefix(2))
    }

    /// The file a notice is about, which drags out of the glance, or else its symbol.
    @ViewBuilder
    private var picture: some View {
        if let file = notice.actions.file {
            Image(nsImage: thumbnails.image(for: file))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: glancePicture, height: glancePicture)
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                .onDrag {
                    viewModel.isDraggingOut = true
                    return NSItemProvider(contentsOf: file) ?? NSItemProvider()
                }
                .help("Drag \(file.lastPathComponent) out")
        } else {
            GlanceDisc(symbol: notice.symbol, tint: notice.tint)
        }
    }
}

/// A button on a notice. The main one is the accent's jewel, in ink; another is glass.
private struct NoticeButton: View {
    let action: NoticeAction
    var isMain = true
    var height: CGFloat = 28
    let run: () -> Void
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        Button(action: run) {
            Text(action.title)
                .font(NotchFont.bodyStrong)
                .foregroundStyle(isMain ? theme.onAccent : theme.primary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: height)
                .glass(isMain ? .lens(theme.accent) : .control, in: Capsule(), isLit: hovering)
                .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.95))
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .fixedSize()
        .help(action.title)
    }
}

/// The last few notices, newest first. A notification is only its app's name here: what it said
/// was shown and forgotten.
private struct RecentGlance: View {
    @ObservedObject var viewModel: NotchViewModel
    let band: CGFloat
    @ObservedObject private var center = LiveActivityCenter.shared
    @Environment(\.notchTheme) private var theme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("Recent")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.primary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .frame(height: band)
                ForEach(center.recents.prefix(GlanceContent.recentRows)) { recent in
                    row(recent, at: context.date)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func row(_ recent: RecentNotice, at now: Date) -> some View {
        HStack(spacing: 8) {
            Image(systemName: recent.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(recent.tint)
                .frame(width: 18)
            Text(recent.count > 1 ? "\(recent.title) × \(recent.count)" : recent.title)
                .font(NotchFont.bodyStrong)
                .foregroundStyle(theme.primary)
                .lineLimit(1)
                .layoutPriority(1)
            if let detail = recent.detail {
                Text(detail)
                    .font(NotchFont.body)
                    .foregroundStyle(theme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(Format.ago(recent.date, from: now))
                .font(NotchFont.caption)
                .foregroundStyle(theme.tertiary)
                .lineLimit(1)
                .fixedSize()
            if let action = recent.actions.first {
                NoticeButton(action: action, isMain: false, height: 24) { action.perform(in: viewModel) }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
    }
}

private struct EventGlance: View {
    let event: CalendarService.Event
    let band: CGFloat
    @Environment(\.notchTheme) private var theme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            GlanceLayout(band: band) {
                // A leaf of a desk calendar: a pane with the weekday over the day.
                VStack(spacing: 0) {
                    Text(event.start.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(Color.orange)
                    Text(event.start.formatted(.dateTime.day()))
                        .font(NotchFont.numeric(20))
                        .foregroundStyle(theme.primary)
                }
                // Digits leave the line's descender empty, so the pair sits a point low to look centered.
                .offset(y: 1)
                .frame(width: glancePicture, height: glancePicture)
                .glass(.pane, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } trailing: {
                Text(event.isHappening(at: context.date) ? "Now" : Format.countdown(to: event.start, from: context.date))
                    .font(NotchFont.numeric(12))
                    .foregroundStyle(Color.orange)
                    .lineLimit(1)
            } center: {
                HStack(spacing: 8) {
                    GlanceLines(title: event.title,
                                subtitle: event.start.formatted(date: .omitted, time: .shortened) + " – "
                                    + event.end.formatted(date: .omitted, time: .shortened))
                    Spacer(minLength: 0)
                    if let url = event.meetingURL {
                        JoinButton(url: url, height: 28)
                    }
                }
            }
        }
    }
}

/// Nothing live: the date and the battery beside the camera, and the weather, the next event and
/// the Tray underneath. Each opens where there's more.
private struct TodayGlance: View {
    @ObservedObject var viewModel: NotchViewModel
    let band: CGFloat
    @ObservedObject private var power = PowerMonitor.shared
    @ObservedObject private var weather = WeatherService.shared
    @ObservedObject private var calendar = CalendarService.shared
    @ObservedObject private var tray = TrayStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var center = LiveActivityCenter.shared
    @ObservedObject private var toggles = QuickToggles.shared
    @Environment(\.notchTheme) private var theme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: 8) {
                HStack(spacing: 0) {
                    Text(context.date.formatted(.dateTime.weekday(.abbreviated).day()))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.primary)
                    Spacer(minLength: 0)
                    if power.hasBattery {
                        HStack(spacing: 3) {
                            if power.isCharging {
                                Image(systemName: "bolt.fill").font(.system(size: 9, weight: .bold))
                            }
                            Text("\(power.level)%")
                        }
                        .font(NotchFont.numeric(12))
                        .foregroundStyle(power.isCharging ? Color.green : power.level <= 20 ? Color.orange : theme.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: band)
                // The weather gives up its description first, then the Tray and Keep Awake their chips,
                // so the row never runs past the glance's edges.
                ViewThatFits(in: .horizontal) {
                    chips(at: context.date, describesSky: true, showsTray: true, showsAwake: true)
                    chips(at: context.date, describesSky: false, showsTray: true, showsAwake: true)
                    chips(at: context.date, describesSky: false, showsTray: false, showsAwake: true)
                    chips(at: context.date, describesSky: false, showsTray: false, showsAwake: false)
                }
                .padding(.horizontal, 14)
            }
            .padding(.top, 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func chips(at now: Date, describesSky: Bool, showsTray: Bool, showsAwake: Bool) -> some View {
        HStack(spacing: 6) {
            if center.unseenRecents > 0 {
                chip(symbol: "bell.fill", tint: theme.accent, text: "\(center.unseenRecents) recent") {
                    viewModel.showRecent()
                }
            }
            if let conditions = weather.conditions {
                let sky = Sky(code: conditions.code, isDay: conditions.isDay)
                let temperature = WeatherService.format(conditions.temperature, units: settings.weatherUnits)
                chip(symbol: sky.symbol, tint: .yellow, text: describesSky ? temperature + " " + sky.description : temperature) {
                    viewModel.open(tab: .home)
                }
            }
            if let event = nextEvent(at: now) {
                chip(symbol: "calendar", tint: .orange, text: eventText(event, at: now)) {
                    viewModel.open(tab: .home)
                }
            }
            if showsAwake, toggles.isKeepingAwake {
                chip(symbol: "cup.and.saucer.fill", tint: .orange, text: toggles.keepAwakeDescription) {
                    viewModel.open(tab: .stats)
                }
            }
            if showsTray, !tray.items.isEmpty {
                chip(symbol: "tray.full.fill", tint: theme.secondary, text: "Tray \(tray.items.count)") {
                    viewModel.open(tab: .tray)
                }
            }
            if weather.conditions == nil, nextEvent(at: now) == nil, tray.items.isEmpty, center.unseenRecents == 0,
               !toggles.isKeepingAwake {
                chip(symbol: "sparkles", tint: theme.secondary, text: "Nothing coming up") { viewModel.open() }
            }
        }
    }

    private func chip(symbol: String, tint: Color, text: String, action: @escaping () -> Void) -> some View {
        GlanceChip(symbol: symbol, tint: tint, text: text, action: action)
    }

    private func nextEvent(at now: Date) -> CalendarService.Event? {
        guard calendar.hasEventAccess else { return nil }
        return calendar.events(on: now).first { !$0.isAllDay && $0.start > now }
    }

    private func eventText(_ event: CalendarService.Event, at now: Date) -> String {
        let when = event.start.timeIntervalSince(now) < 3 * 3600
            ? Format.countdown(to: event.start, from: now)
            : "at " + event.start.formatted(date: .omitted, time: .shortened)
        return "\(event.title) \(when)"
    }
}

/// A capsule of glass under the camera: what's coming, in its color, and a tap opens where it is.
private struct GlanceChip: View {
    let symbol: String
    let tint: Color
    let text: String
    let action: () -> Void
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                // As wide as the words, up to a point.
                Text(text)
                    .font(NotchFont.body)
                    .foregroundStyle(theme.primary)
                    .lineLimit(1)
                    .frame(maxWidth: 160, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 11)
            .frame(height: 28)
            .glass(.control, in: Capsule(), isLit: hovering)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.95))
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .help(text)
    }
}
