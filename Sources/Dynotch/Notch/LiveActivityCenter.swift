import Combine
import SwiftUI

/// A short-lived message in the closed notch: charging, volume, a device connecting...
struct LiveNotice: Equatable {
    enum Kind: Equatable {
        case info
        /// A level meter, like the volume HUD.
        case meter(Double)
    }

    /// Notices with the same key update in place instead of animating in again.
    var key: String
    var symbol: String
    var tint: Color
    var text: String = ""
    /// Longer text shown on a second row under the notch.
    var detail: String?
    var kind: Kind = .info
    /// Posted by a `dynotch://` link rather than by Dynotch. Drawn with a terminal badge, since a
    /// script may borrow any symbol and color.
    var fromScript = false
}

/// What the closed notch is showing.
enum ClosedActivity: Equatable {
    case idle
    case music
    case trackPeek
    case timer
    case notice(LiveNotice)
    /// A named timer from the Focus tab.
    case countdown(Countdown)
    case stopwatch
    /// Files arriving in ~/Downloads.
    case download
}

/// A second activity, drawn as a small glyph at the end of the right ear while the main
/// activity keeps the left ear and the rest of the notch.
enum CompactActivity: Equatable {
    case timer
    case music
    /// The microphone is muted. Its badge shows even when nothing else does.
    case micMuted
    case countdown(Countdown)
    case stopwatch
    case download
    /// A Focus is on. Like the mute badge, it shows even when nothing else does.
    case focus(FocusMode)

    /// The main activity already shows this one.
    func isShown(by activity: ClosedActivity) -> Bool {
        switch (self, activity) {
        case (.timer, .timer), (.music, .music), (.music, .trackPeek), (.stopwatch, .stopwatch), (.download, .download): true
        case (.micMuted, .notice(let notice)): notice.key == "mic"
        case (.focus, .notice(let notice)): notice.key == "focus"
        case (.countdown(let compact), .countdown(let main)): compact.id == main.id
        default: false
        }
    }

    /// A state rather than something going on, so it may show on its own while "Two at once" is off.
    var isStatus: Bool {
        switch self {
        case .micMuted, .focus: true
        default: false
        }
    }
}

/// Everything in the closed notch: the main activity and the glyph of a second one beside it.
struct ClosedContent: Equatable {
    var activity: ClosedActivity = .idle
    var secondary: CompactActivity?
}

/// Decides what the closed notch shows. The main activity goes by priority: notices, a new
/// track, a running timer (the focus timer or a named one, whichever ends soonest, then the
/// stopwatch), a download, then music that's playing. The most important of the others that
/// has a compact form shows beside it: the mute badge, timers, a download, the Focus, music.
@MainActor
final class LiveActivityCenter: ObservableObject {
    static let shared = LiveActivityCenter()

    @Published private(set) var content = ClosedContent()

    /// The main activity.
    var activity: ClosedActivity { content.activity }

    private var notice: LiveNotice?
    private var noticeTask: Task<Void, Never>?
    private var trackPeekActive = false
    private var trackPeekTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    func start() {
        let media = NowPlayingService.shared
        let timer = PomodoroTimer.shared
        Publishers.MergeMany(
            media.$isPlaying.map { _ in () }.eraseToAnyPublisher(),
            media.$track.map { _ in () }.eraseToAnyPublisher(),
            timer.$isRunning.map { _ in () }.eraseToAnyPublisher(),
            MicMonitor.shared.$isMuted.map { _ in () }.eraseToAnyPublisher(),
            TimerStore.shared.$countdowns.map { _ in () }.eraseToAnyPublisher(),
            TimerStore.shared.$stopwatch.map { _ in () }.eraseToAnyPublisher(),
            DownloadMonitor.shared.$downloads.map(\.isEmpty).removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            FocusMonitor.shared.$mode.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher()
        )
        // @Published fires before the value changes; read it on the next turn.
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.recompute() }
        .store(in: &cancellables)
    }

    func post(_ notice: LiveNotice, for duration: TimeInterval = 2.6) {
        self.notice = notice
        recompute()
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.notice = nil
            self?.recompute()
        }
    }

    func showMeter(key: String, symbol: String, level: Double) {
        guard AppSettings.shared.liveHUD else { return }
        post(LiveNotice(key: key, symbol: symbol, tint: .white, kind: .meter(level)), for: 1.6)
    }

    func peekTrack() {
        guard AppSettings.shared.trackPeek else { return }
        trackPeekActive = true
        recompute()
        trackPeekTask?.cancel()
        trackPeekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.2))
            guard !Task.isCancelled else { return }
            self?.trackPeekActive = false
            self?.recompute()
        }
    }

    private func recompute() {
        let settings = AppSettings.shared
        let media = NowPlayingService.shared
        let store = TimerStore.shared
        let musicPlaying = settings.liveMusic && media.isPlaying && media.track != nil
        let downloading = settings.liveDownloads && !DownloadMonitor.shared.downloads.isEmpty

        // Running timers, the one that ends soonest first, then the stopwatch.
        var timers: [(end: Date, activity: ClosedActivity, compact: CompactActivity)] = []
        if settings.liveTimer, let end = PomodoroTimer.shared.endDate {
            timers.append((end, .timer, .timer))
        }
        if settings.liveCountdowns {
            for countdown in store.countdowns {
                if let end = countdown.endDate { timers.append((end, .countdown(countdown), .countdown(countdown))) }
            }
            if store.stopwatch.isRunning { timers.append((.distantFuture, .stopwatch, .stopwatch)) }
        }
        timers.sort { $0.end < $1.end }

        let activity: ClosedActivity
        if let notice {
            activity = .notice(notice)
        } else if trackPeekActive, settings.liveMusic, media.track != nil {
            activity = .trackPeek
        } else if let timer = timers.first {
            activity = timer.activity
        } else if downloading {
            activity = .download
        } else if musicPlaying {
            activity = .music
        } else {
            activity = .idle
        }

        // The ones with a compact form, most important first.
        var compact: [CompactActivity] = []
        if settings.liveMicMuted, MicMonitor.shared.isMuted { compact.append(.micMuted) }
        compact += timers.map(\.compact)
        if downloading { compact.append(.download) }
        if settings.liveFocus, let focus = FocusMonitor.shared.mode { compact.append(.focus(focus)) }
        if musicPlaying { compact.append(.music) }
        var secondary = compact.first { !$0.isShown(by: activity) }
        // Without "Two at once", only a status like the mute badge shows, and only when nothing else does.
        if !settings.liveSecondary, activity != .idle || secondary?.isStatus != true { secondary = nil }

        let next = ClosedContent(activity: activity, secondary: secondary)
        guard next != content else { return }
        withAnimation(.notchActivity) { content = next }
    }
}
