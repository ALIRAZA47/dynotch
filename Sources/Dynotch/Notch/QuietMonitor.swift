import AppKit
import Combine

/// Whether the notch should keep to itself: a call is on, or something fills the screen, like a
/// presentation or a film. Peeks and the like wait until it's over. It all comes from things that
/// announce themselves, so it adds no polls. Dynotch can't tell when the screen is shared, so a call
/// counts whether it's shared or not.
@MainActor
final class QuietMonitor: ObservableObject {
    static let shared = QuietMonitor()

    enum Reason: Equatable {
        case call, fullScreen
    }

    @Published private(set) var reason: Reason?

    var isQuiet: Bool { reason != nil }

    private var isStarted = false
    private var isOnCall = false
    private var isFullScreen = false
    private var lookAgain: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    func start() {
        isStarted = true
        // A moment of the mic or a camera is no call: Siri, a dictated word, the Mirror winding down.
        Publishers.CombineLatest(MicMonitor.shared.$micInUse, MicMonitor.shared.$cameraInUse)
            .map { $0 || $1 }
            .removeDuplicates()
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] inUse in
                self?.isOnCall = inUse
                self?.update()
            }
            .store(in: &cancellables)
        AppSettings.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.update() }
            .store(in: &cancellables)

        // macOS reports the frontmost app's options here, whichever app it is.
        NSApp.publisher(for: \.currentSystemPresentationOptions)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.readScreen() }
            .store(in: &cancellables)
        let workspace = NSWorkspace.shared.notificationCenter
        Publishers.Merge(workspace.publisher(for: NSWorkspace.activeSpaceDidChangeNotification),
                         workspace.publisher(for: NSWorkspace.didActivateApplicationNotification))
            .sink { [weak self] _ in self?.lookAtScreen() }
            .store(in: &cancellables)
        readScreen()
    }

    /// Looks again just before something shows, in case what's on screen changed without saying so.
    func look() {
        if isStarted { readScreen() }
    }

    /// Now, and again once a change of Space has finished sliding.
    private func lookAtScreen() {
        readScreen()
        lookAgain?.cancel()
        lookAgain = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            self?.readScreen()
        }
    }

    private func readScreen() {
        let options = NSApp.currentSystemPresentationOptions
        // A maximized window isn't this: only full screen, or a slideshow hiding the menu bar, is.
        isFullScreen = options.contains(.fullScreen) || options.contains(.hideMenuBar)
        update()
    }

    private func update() {
        let settings = AppSettings.shared
        let next: Reason? = settings.quietInFullScreen && isFullScreen ? .fullScreen
            : settings.quietOnCalls && isOnCall ? .call : nil
        if next != reason { reason = next }
    }
}
