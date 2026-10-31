import AppKit
import Combine
import ScreenCaptureKit
import SwiftUI

/// Records a region of a display. The file is written under a hidden name in the Tray's own folder,
/// which needs no folder permission and has nothing watching it, and lands in the Screenshot app's
/// folder and the Tray once it's whole. However a recording ends, it comes through `end`, and what
/// was recorded is finished and kept.
@MainActor
final class ScreenRecorder: ObservableObject {
    static let shared = ScreenRecorder(makeSource: { ScreenStreamSource() }, tray: nil, saveFolder: nil, isParked: false,
                                       notify: ImageActions.show)

    enum State: Equatable {
        case idle, starting
        case recording(since: Date)
        case saving
    }

    /// Why a recording ended. Only the first reason counts.
    enum Ending: Equatable {
        /// The user's own stop, from anywhere, macOS's stop control included.
        case asked
        case displayGone
        /// macOS stopped the stream, and not because anyone asked.
        case stopped
        case quitting
        case sleeping
        /// What went wrong, in words.
        case writerFailed(String)

        /// What a stream's error means. Only macOS's own stop control is an ordinary stop.
        init(streamError error: Error) {
            let error = error as NSError
            let isUsers = error.domain == SCStreamErrorDomain && error.code == SCStreamError.Code.userStopped.rawValue
            self = isUsers ? .asked : .stopped
        }
    }

    /// One recording, from Record until its file has landed.
    private final class Session {
        let request: RecordingRequest
        let plan: RecordingPlan
        let source: RecordingSource
        let writer: RecordingWriter
        /// The hidden file being written.
        let staged: URL
        let date: Date
        /// `source.start` has come back, so an ending can go ahead.
        var hasStarted = false
        var ending: Ending?
        var conversion: Task<Void, Error>?

        init(request: RecordingRequest, plan: RecordingPlan, source: RecordingSource, writer: RecordingWriter, staged: URL, date: Date) {
            self.request = request
            self.plan = plan
            self.source = source
            self.writer = writer
            self.staged = staged
            self.date = date
        }
    }

    /// Only a stuck writer gets this far: finishing a 1.5 GB file took under a tenth of a second.
    nonisolated static let quitLimit: TimeInterval = 5

    @Published private(set) var state = State.idle
    /// Moves once a second while recording, for what shows the time.
    @Published private(set) var now = Date.now
    /// What's being recorded, for the glance.
    @Published private(set) var plan: RecordingPlan?
    @Published private(set) var format = RecordFormat.mp4

    /// Off screen and never the real source, or else the real one. See `init`.
    private let makeSource: () -> RecordingSource
    private let injectedTray: TrayStore?
    private let saveFolder: URL?
    private let isParked: Bool
    private let notify: ImageActions.Notify
    /// Turns the finished MP4 into a GIF. A test can make it fail.
    var convert: @Sendable (URL, URL) async throws -> Void = { try await RecordingGif.make(from: $0, to: $1) }

    private var session: Session?
    private var clock: Poll?
    private(set) var outline: RecordingOutline?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var isQuitting = false
    /// Called once when nothing's going on any more, for quitting.
    private var waiters: [@MainActor () -> Void] = []
    /// What's going on now, for a test to wait on.
    private(set) var starting: Task<Void, Never>?
    private(set) var saving: Task<Void, Never>?

    private var tray: TrayStore { injectedTray ?? .shared }

    /// Everything a recording reaches for, so a test can give it its own. Nil is the real Tray and the
    /// Screenshot app's folder. `isParked` keeps the outline off screen.
    init(makeSource: @escaping () -> RecordingSource, tray: TrayStore?, saveFolder: URL?, isParked: Bool = true,
         notify: @escaping ImageActions.Notify) {
        self.makeSource = makeSource
        injectedTray = tray
        self.saveFolder = saveFolder
        self.isParked = isParked
        self.notify = notify
    }

    /// A recording is going, or starting to. Stop means something now.
    var isRunning: Bool {
        guard session != nil else { return false }
        switch state {
        case .starting, .recording: return true
        case .idle, .saving: return false
        }
    }

    /// There's a recording or its file to wait for, so the app can't just quit.
    var isBusy: Bool { session != nil }

    /// The clock only exists while a recording runs.
    var isTicking: Bool { clock != nil }

    /// The writer of the recording going on, for a test.
    var writer: RecordingWriter? { session?.writer }

    /// Anything to show in the notch. A sample counts here, and in `isRunning` it doesn't.
    var isActive: Bool { state != .idle }

    /// How long it's been going, by the clock. From the start date, so it's right after a quiet spell.
    var elapsed: TimeInterval {
        guard case .recording(let since) = state else { return 0 }
        return max(now.timeIntervalSince(since), 0)
    }

    // MARK: Starting

    func start(_ request: RecordingRequest) {
        guard session == nil else {
            notify(Self.problem("Still saving", detail: "The last recording isn't done yet"), 3)
            return
        }
        guard let plan = RecordingPlan(region: request.region, scale: request.scale, frameRate: request.format.frameRate) else {
            notify(Self.problem("Too small", detail: "A recording needs a bigger region than that"), 3)
            return
        }
        let staged = tray.folder.appendingPathComponent(".recording-\(UUID().uuidString).mp4")
        let writer: RecordingWriter
        do {
            writer = try RecordingWriter(url: staged, plan: plan)
        } catch {
            NSLog("Dynotch: couldn't start a recording: %@", error.localizedDescription)
            notify(Self.problem("Not recorded", detail: "The file couldn't be started"), 4)
            return
        }
        let source = makeSource()
        let session = Session(request: request, plan: plan, source: source, writer: writer, staged: staged, date: .now)
        self.session = session
        self.plan = plan
        format = request.format
        state = .starting
        wire(session)
        watch(session)
        starting = Task {
            do {
                try await source.start(request, plan: plan)
                self.started(session)
            } catch {
                NSLog("Dynotch: couldn't start a recording: %@", error.localizedDescription)
                if session.ending == nil { session.ending = .stopped }
                self.started(session)
            }
        }
    }

    /// Frames go straight to the writer. What says it's over comes back here. These stay set for the
    /// source's life, since a stream that's stuck may still be reading them on its own queue, so they
    /// hold the session weakly.
    private func wire(_ session: Session) {
        let writer = session.writer
        session.source.onFrame = { writer.append($0) }
        session.source.onStop = { [weak self, weak session] error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let session, self?.session === session else { return }
                    self?.end(Ending(streamError: error))
                }
            }
        }
        writer.onFailure = { [weak self, weak session, url = session.staged] error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let session, self?.session === session else { return }
                    self?.end(.writerFailed(RecordingWriter.reason(for: error, at: url)))
                }
            }
        }
    }

    /// A stream can lose its display without saying so, and a closed lid takes the built-in one away.
    private func watch(_ session: Session) {
        let display = session.request.display
        let screens = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                             object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if Self.isGone(display, from: NSScreen.screens.map(\.displayID)) { self?.end(.displayGone) }
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        let sleep = workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.end(.sleeping) }
        }
        observers = [(NotificationCenter.default, screens), (workspace, sleep)]
    }

    /// Whether a display is no longer among the screens there are.
    nonisolated static func isGone(_ display: CGDirectDisplayID, from screens: [CGDirectDisplayID]) -> Bool {
        !screens.contains(display)
    }

    /// `source.start` is back, one way or the other. An ending that came meanwhile goes ahead now.
    private func started(_ session: Session) {
        guard self.session === session else { return }
        session.hasStarted = true
        guard session.ending == nil else {
            wrapUp(session)
            return
        }
        now = .now
        state = .recording(since: now)
        clock = EnergyCoordinator.shared.schedule(.recording) { [weak self] in self?.now = .now }
        let outline = RecordingOutline(around: session.request.place, isParked: isParked)
        outline.orderFrontRegardless()
        self.outline = outline
    }

    // MARK: Ending

    /// The user's own stop.
    func stop() {
        end(.asked)
    }

    /// Everything that ends a recording comes here. The first reason counts, and the rest find nothing
    /// to do, so two endings at once land one file and post one notice.
    func end(_ ending: Ending) {
        guard let session, session.ending == nil else { return }
        session.ending = ending
        if session.hasStarted { wrapUp(session) }
    }

    private func wrapUp(_ session: Session) {
        state = .saving
        clock?.cancel()
        clock = nil
        outline?.orderOut(nil)
        outline?.close()
        outline = nil
        observers.forEach { $0.0.removeObserver($0.1) }
        observers = []
        let source = session.source
        // On its own, so that a stream that's stuck can't hold up the file.
        Task { await source.stop() }
        saving = Task {
            await land(session)
            self.session = nil
            plan = nil
            state = .idle
            let waiters = waiters
            self.waiters = []
            waiters.forEach { $0() }
        }
    }

    /// Ends what's running for the app to quit, and calls `done` once its file has landed, or after
    /// `limit` if something's stuck, so that a stuck writer can't stop the Mac shutting down. A GIF
    /// gives way, and its MP4 lands instead.
    func finishBeforeQuitting(within limit: TimeInterval = quitLimit, then done: @escaping @MainActor () -> Void) {
        guard let session else {
            done()
            return
        }
        isQuitting = true
        end(.quitting)
        session.conversion?.cancel()
        var isDone = false
        let once: @MainActor () -> Void = {
            guard !isDone else { return }
            isDone = true
            done()
        }
        waiters.append(once)
        Task {
            try? await Task.sleep(for: .seconds(limit))
            once()
        }
    }

    // MARK: Landing

    private func land(_ session: Session) async {
        let ending = session.ending ?? .asked
        let outcome = await session.writer.finish()
        let fileName = Self.fileName(at: session.date)
        switch outcome {
        case .noFrames:
            notify(Self.nothingRecorded(ending), 4)
        case .failed(let reason):
            notify(Self.problem("Not saved", detail: "\(reason). Nothing could be kept"), 6)
        case .partial(let reason):
            let url = await place(session.staged, named: fileName + ".mp4")
            tray.add([url])
            notify(Self.landed(url, ending: .writerFailed(reason), gifFailed: false), 6)
        case .finished:
            var staged = session.staged
            var gifFailed = false
            if session.request.format == .gif, !isQuitting {
                if let gif = await makeGif(session) {
                    try? FileManager.default.removeItem(at: staged)
                    staged = gif
                } else {
                    gifFailed = true
                }
            }
            let url = await place(staged, named: fileName + "." + staged.pathExtension)
            tray.add([url])
            notify(Self.landed(url, ending: ending, gifFailed: gifFailed), 4)
        }
    }

    /// The GIF, under a hidden name beside the MP4, or nil if it couldn't be made.
    private func makeGif(_ session: Session) async -> URL? {
        let staged = session.staged
        let gif = staged.deletingPathExtension().appendingPathExtension("gif")
        let convert = convert
        let conversion = Task.detached(priority: .userInitiated) { try await convert(staged, gif) }
        session.conversion = conversion
        do {
            try await conversion.value
            return gif
        } catch {
            NSLog("Dynotch: couldn't make the GIF: %@", error.localizedDescription)
            try? FileManager.default.removeItem(at: gif)
            return nil
        }
    }

    /// Moves a finished file to where it's kept. It never overwrites: a name that's taken gets a number.
    /// If that folder can't be written it stays in the Tray's under the same name, and nothing is lost.
    private func place(_ staged: URL, named name: String) async -> URL {
        let folders = [saveFolder ?? ScreenshotFile.folder(), tray.folder]
        return await Task.detached(priority: .userInitiated) {
            for folder in folders {
                let target = FileActions.uniqueURL(for: folder.appendingPathComponent(name))
                do {
                    try FileManager.default.moveItem(at: staged, to: target)
                    return target
                } catch {
                    NSLog("Dynotch: couldn't move a recording to %@: %@", folder.path, error.localizedDescription)
                }
            }
            return staged
        }.value
    }

    /// "Screen Recording 2026-10-31 at 18.02.06", as macOS names its own.
    nonisolated static func fileName(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Screen Recording \(formatter.string(from: date))"
    }

    // MARK: Notices

    /// What a landed file's notice says. Where it isn't the user's own stop, the reason comes first.
    static func landed(_ url: URL, ending: Ending, gifFailed: Bool) -> LiveNotice {
        let name = url.lastPathComponent
        let actions = [NoticeAction(title: "Open", kind: .openFile(url)), NoticeAction(title: "Show", kind: .reveal(url))]
        let saved = "Saved as \(name)"
        let (text, detail): (String, String)
        switch ending {
        case _ where gifFailed && (ending == .asked || ending == .quitting):
            (text, detail) = ("No GIF", "It couldn't be made. \(saved)")
        case .asked, .quitting:
            (text, detail) = ("Saved", name)
        case .displayGone:
            (text, detail) = ("Display gone", saved)
        case .stopped:
            (text, detail) = ("Stopped by macOS", saved)
        case .sleeping:
            (text, detail) = ("Mac sleeping", saved)
        case .writerFailed(let reason):
            (text, detail) = ("Stopped", "\(reason). Kept \(name)")
        }
        let isOrdinary = ending == .asked || ending == .quitting
        return LiveNotice(key: "recording", symbol: isOrdinary ? "record.circle" : "exclamationmark.triangle.fill",
                          tint: isOrdinary ? .white : .orange, text: text, detail: detail, actions: actions, recall: .whole)
    }

    /// No frame ever came, so there's no file to speak of.
    private static func nothingRecorded(_ ending: Ending) -> LiveNotice {
        switch ending {
        case .asked, .quitting: problem("Not recorded", detail: "It stopped before the first frame")
        default: problem("Not recorded", detail: "The screen couldn't be read")
        }
    }

    private static func problem(_ text: String, detail: String) -> LiveNotice {
        LiveNotice(key: "recording", symbol: "exclamationmark.triangle.fill", tint: .orange, text: text, detail: detail, recall: .whole)
    }

    // MARK: Snapshots

    /// A recording to show, or nil for none. It holds nothing, and a stop finds nothing to end.
    func loadSample(_ state: State, plan: RecordingPlan? = nil, format: RecordFormat = .mp4, now: Date = .now) {
        self.state = state
        self.plan = plan
        self.format = format
        self.now = now
    }
}
