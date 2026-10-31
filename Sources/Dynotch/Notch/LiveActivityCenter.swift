import Combine
import SwiftUI

/// A short-lived message in the closed notch: charging, volume, a device connecting...
struct LiveNotice: Equatable {
    enum Kind: Equatable {
        case info
        /// A level meter, like the volume HUD.
        case meter(Double)
    }

    /// What becomes of a notice while the Mac is quiet: on a call, presenting or in full screen.
    enum Timing: Equatable {
        /// It shows anyway: it answers something you just did, or it can't wait.
        case always
        /// It holds its place and shows afterwards.
        case waits
        /// It goes unshown, since it would be out of date by then.
        case perishes
    }

    /// What the glance's recent list keeps of a notice once it's gone.
    enum Recall: Equatable {
        case nothing
        case whole
        /// Only this name: what a notification said isn't Dynotch's to keep.
        case name(String)
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
    /// Buttons in the glance, the main one first.
    var actions: [NoticeAction] = []
    var timing: Timing = .always
    var recall: Recall = .nothing

    /// What to call it in a list of several.
    var sourceName: String? {
        if case .name(let name) = recall { return name }
        return text.isEmpty ? detail : text
    }
}

/// A notice after it's gone. Kept in memory only, and only the last few.
struct RecentNotice: Identifiable, Equatable {
    let id: UUID
    var symbol: String
    var tint: Color
    var title: String
    var detail: String?
    var date: Date
    var actions: [NoticeAction]
    /// How many came in a row from the same place, like several messages from one app.
    var count = 1
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
    /// Notices waiting for a call or a presentation to end.
    case held(Int)
    /// Keep Awake is on.
    case keepAwake

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
        case .micMuted, .focus, .held, .keepAwake: true
        default: false
        }
    }
}

/// Everything in the closed notch: the main activity and the glyph of a second one beside it.
struct ClosedContent: Equatable {
    var activity: ClosedActivity = .idle
    var secondary: CompactActivity?
}

/// Decides what the closed notch shows. The main activity goes by priority: notices, which take
/// turns (see `NoticeQueue`), a new track, a running timer (the focus timer or a named one, whichever
/// ends soonest, then the stopwatch), a download, then music that's playing. The most important of
/// the others that has a compact form shows beside it: the mute badge, what's being held back,
/// timers, a download, Keep Awake, the Focus, music.
@MainActor
final class LiveActivityCenter: ObservableObject {
    static let shared = LiveActivityCenter()

    @Published private(set) var content = ClosedContent()
    /// The last few notices that were worth keeping, newest first. In memory only.
    @Published private(set) var recents: [RecentNotice] = []
    /// How many of those have come since the list was last looked at.
    @Published private(set) var unseenRecents = 0

    /// The main activity.
    var activity: ClosedActivity { content.activity }

    static let mostRecents = 10

    private var queue = NoticeQueue()
    private var clock: Task<Void, Never>?
    /// Notches glancing right now, so a notice stays while the pointer is on it.
    private var glancers = 0
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
            QuickToggles.shared.$isKeepingAwake.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher()
        )
        // @Published fires before the value changes; read it on the next turn.
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.recompute() }
        .store(in: &cancellables)
        QuietMonitor.shared.$reason
            .map { $0 != nil }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] quiet in self?.quietChanged(quiet) }
            .store(in: &cancellables)
    }

    func post(_ notice: LiveNotice, for duration: TimeInterval = 2.6) {
        remember(notice)
        QuietMonitor.shared.look()
        queue.post(NoticeQueue.Entry(notice: notice, duration: duration), isQuiet: QuietMonitor.shared.isQuiet, now: .now)
        settle()
    }

    func showMeter(key: String, symbol: String, level: Double) {
        guard AppSettings.shared.liveHUD else { return }
        queue.showMeter(LiveNotice(key: key, symbol: symbol, tint: .white, kind: .meter(level)), for: 1.6, now: .now)
        settle()
    }

    /// Takes the notice showing off the notch, once a button on it has done its job.
    func dismissNotice() {
        queue.dismiss(now: .now)
        settle()
    }

    /// A notch started or stopped glancing. A notice stays while the pointer is on it.
    func glanceChanged(isGlancing: Bool) {
        glancers = max(glancers + (isGlancing ? 1 : -1), 0)
        queue.setHeldByPointer(glancers > 0, now: .now)
        settle()
    }

    func markRecentsSeen() {
        if unseenRecents != 0 { unseenRecents = 0 }
    }

    func peekTrack() {
        guard AppSettings.shared.trackPeek, !QuietMonitor.shared.isQuiet else { return }
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

    // MARK: Snapshots

    func loadSample(recents: [RecentNotice], unseen: Int) {
        self.recents = recents
        unseenRecents = unseen
    }

    // MARK: Private

    private func quietChanged(_ quiet: Bool) {
        if quiet {
            queue.goQuiet(now: .now)
        } else {
            queue.endQuiet(now: .now)
        }
        settle()
    }

    /// Shows what's current, and wakes for the next change.
    private func settle() {
        recompute()
        clock?.cancel()
        guard let next = queue.nextChange else { return }
        clock = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(next.timeIntervalSinceNow, 0.01)))
            guard !Task.isCancelled else { return }
            self?.queue.tick(now: .now)
            self?.settle()
        }
    }

    func remember(_ notice: LiveNotice) {
        let title: String
        var detail: String?
        switch notice.recall {
        case .nothing:
            return
        case .whole:
            title = notice.text.isEmpty ? notice.detail ?? "" : notice.text
            detail = notice.text.isEmpty ? nil : notice.detail
        case .name(let name):
            title = name
        }
        unseenRecents = min(unseenRecents + 1, Self.mostRecents)
        // Several in a row from one place are one line.
        if recents.first?.title == title, recents.first?.detail == detail {
            recents[0].count += 1
            recents[0].date = .now
            return
        }
        recents.insert(RecentNotice(id: UUID(), symbol: notice.symbol, tint: notice.tint, title: title, detail: detail,
                                    date: .now, actions: notice.actions.keptForLater), at: 0)
        if recents.count > Self.mostRecents { recents.removeLast(recents.count - Self.mostRecents) }
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
        if let notice = queue.visible {
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
        if !queue.held.isEmpty { compact.append(.held(queue.held.count)) }
        compact += timers.map(\.compact)
        if downloading { compact.append(.download) }
        if settings.liveKeepAwake, QuickToggles.shared.isKeepingAwake { compact.append(.keepAwake) }
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
