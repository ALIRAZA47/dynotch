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
}

/// What the closed notch is showing.
enum ClosedActivity: Equatable {
    case idle
    case music
    case trackPeek
    case timer
    case notice(LiveNotice)
}

/// Decides what the closed notch shows, by priority: notices, a new track,
/// a running focus timer, then music that's playing.
@MainActor
final class LiveActivityCenter: ObservableObject {
    static let shared = LiveActivityCenter()

    @Published private(set) var activity: ClosedActivity = .idle

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
        let next: ClosedActivity
        if let notice {
            next = .notice(notice)
        } else if trackPeekActive, settings.liveMusic, media.track != nil {
            next = .trackPeek
        } else if settings.liveTimer, PomodoroTimer.shared.isRunning {
            next = .timer
        } else if settings.liveMusic, media.isPlaying, media.track != nil {
            next = .music
        } else {
            next = .idle
        }
        guard next != activity else { return }
        withAnimation(.notchActivity) { activity = next }
    }
}
