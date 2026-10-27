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

    /// Each side of the glance beside the camera.
    static let earWidth: CGFloat = 100

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

    var body: some View {
        let band = viewModel.geometry.closedSize.height
        Group {
            switch viewModel.glanceContent {
            case .music: MusicGlance(band: band)
            case .pomodoro: PomodoroGlance(band: band)
            case .countdown(let countdown): CountdownGlance(countdown: countdown, band: band)
            case .stopwatch: StopwatchGlance(band: band)
            case .download: DownloadGlance(band: band)
            case .notice(let notice): NoticeGlance(notice: notice, band: band)
            case .event(let event): EventGlance(event: event, band: band)
            case .today: TodayGlance(viewModel: viewModel, band: band)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { viewModel.open() }
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
                .frame(width: GlanceContent.earWidth - 12, height: band, alignment: .trailing)
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

/// A round button in the glance's ear: pause, play.
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
                .frame(width: 26, height: 26)
                .background(Circle().fill(tint.opacity(hovering ? 0.3 : 0.2)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .help(help)
        .accessibilityLabel(help)
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
                .font(NotchFont.numeric(22))
                .foregroundStyle(tint)
                .contentTransition(.numericText(countsDown: true))
        }
    }
}

// MARK: Glances

private struct MusicGlance: View {
    let band: CGFloat
    @ObservedObject private var media = NowPlayingService.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let tint = settings.artworkTint ? Color(nsColor: media.accent) : theme.accent
        GlanceLayout(band: band) {
            ArtworkView(image: media.artwork, size: glancePicture, cornerRadius: 11)
        } trailing: {
            HStack(spacing: 2) {
                IconButton(symbol: "backward.fill", size: 12, help: "Previous", action: media.previous)
                PlayButton(isPlaying: media.isPlaying, side: 28, action: media.playPause)
                IconButton(symbol: "forward.fill", size: 12, help: "Next", action: media.next)
            }
        } center: {
            VStack(alignment: .leading, spacing: 1) {
                Text(media.track?.title ?? "Nothing playing")
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                Text(media.track?.artist ?? "")
                    .font(NotchFont.body)
                    .foregroundStyle(theme.secondary)
                    .lineLimit(1)
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
                ProgressRing(progress: timer.progress, color: color, lineWidth: 4)
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
                ProgressRing(progress: countdown.progress(at: store.now), color: tint, lineWidth: 4)
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
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(Capsule().fill(TimerStore.tint.opacity(hovering ? 0.3 : 0.2)))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableButtonStyle(scale: 0.94))
                .onHover { hovering = $0 }
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
            Image(systemName: "stopwatch.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 46, height: 46)
                .background(Circle().fill(tint.opacity(0.16)))
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
    @Environment(\.notchTheme) private var theme

    var body: some View {
        GlanceLayout(band: band) {
            DownloadRing(fraction: monitor.fraction, lineWidth: 4, arrowSize: 15)
                .padding(2)
        } trailing: {
            DownloadAmount()
        } center: {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Downloading to Downloads")
                    .font(NotchFont.body)
                    .foregroundStyle(theme.secondary)
                    .lineLimit(1)
            }
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
    let band: CGFloat
    @Environment(\.notchTheme) private var theme

    var body: some View {
        GlanceLayout(band: band) {
            Image(systemName: notice.symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(notice.tint)
                .frame(width: 46, height: 46)
                .background(Circle().fill(notice.tint.opacity(0.16)))
        } trailing: {
            EmptyView()
        } center: {
            VStack(alignment: .leading, spacing: 1) {
                Text(notice.text)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                if let detail = notice.detail {
                    Text(detail)
                        .font(NotchFont.body)
                        .foregroundStyle(theme.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

private struct EventGlance: View {
    let event: CalendarService.Event
    let band: CGFloat
    @Environment(\.notchTheme) private var theme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            GlanceLayout(band: band) {
                VStack(spacing: 0) {
                    Text(event.start.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(Color.orange)
                    Text(event.start.formatted(.dateTime.day()))
                        .font(NotchFont.numeric(20))
                }
                .frame(width: 46, height: 46)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(theme.control))
            } trailing: {
                Text(event.isHappening(at: context.date) ? "Now" : Format.countdown(to: event.start, from: context.date))
                    .font(NotchFont.numeric(12))
                    .foregroundStyle(Color.orange)
                    .lineLimit(1)
            } center: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.title)
                            .font(.system(size: 13.5, weight: .semibold))
                            .lineLimit(1)
                        Text(event.start.formatted(date: .omitted, time: .shortened) + " – "
                             + event.end.formatted(date: .omitted, time: .shortened))
                            .font(NotchFont.body)
                            .foregroundStyle(theme.secondary)
                            .lineLimit(1)
                    }
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
    @Environment(\.notchTheme) private var theme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: 8) {
                HStack(spacing: 0) {
                    Text(context.date.formatted(.dateTime.weekday(.abbreviated).day()))
                        .font(.system(size: 12, weight: .semibold))
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
                HStack(spacing: 6) {
                    if let conditions = weather.conditions {
                        let sky = Sky(code: conditions.code, isDay: conditions.isDay)
                        chip(symbol: sky.symbol, tint: .yellow,
                             text: WeatherService.format(conditions.temperature, units: settings.weatherUnits) + " " + sky.description) {
                            viewModel.open(tab: .home)
                        }
                    }
                    if let event = nextEvent(at: context.date) {
                        chip(symbol: "calendar", tint: .orange, text: eventText(event, at: context.date)) {
                            viewModel.open(tab: .home)
                        }
                    }
                    if !tray.items.isEmpty {
                        chip(symbol: "tray.full.fill", tint: theme.secondary, text: "Tray \(tray.items.count)") {
                            viewModel.open(tab: .tray)
                        }
                    }
                    if weather.conditions == nil, nextEvent(at: context.date) == nil, tray.items.isEmpty {
                        chip(symbol: "sparkles", tint: theme.secondary, text: "Nothing coming up") { viewModel.open() }
                    }
                }
                .padding(.horizontal, 14)
            }
            .padding(.top, 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                    .lineLimit(1)
                    .frame(maxWidth: 160, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(hovering ? theme.controlHover : theme.control))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.95))
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .help(text)
    }
}
