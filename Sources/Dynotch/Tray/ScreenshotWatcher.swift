import AppKit
import Combine

/// Adds new screenshots and screen recordings to the Tray as macOS saves them.
@MainActor
final class ScreenshotWatcher: ObservableObject {
    static let shared = ScreenshotWatcher()

    enum Access {
        case unknown, granted, denied
    }

    /// Whether the save folder can be read. macOS asks the first time for the Desktop, Documents and Downloads.
    @Published private(set) var access = Access.unknown

    /// A folder being watched and the files that were already in it.
    private final class Watch {
        let folder: URL
        let source: DispatchSourceFileSystemObject
        var seen: Set<String>
        var isRetrying = false

        init(folder: URL, source: DispatchSourceFileSystemObject, seen: Set<String>) {
            self.folder = folder
            self.source = source
            self.seen = seen
        }
    }

    private static let domain = "com.apple.screencapture" as CFString
    private var watches: [Watch] = []
    private var locationPoll: Poll?
    private var cancellable: AnyCancellable?
    private let queue = DispatchQueue(label: "app.dynotch.screenshots", qos: .utility)
    /// Goes up whenever watching stops, so a first look that comes back after that is dropped.
    private var generation = 0

    private enum Listing {
        case names([String]), denied, unreadable
    }

    private init() {}

    func start() {
        cancellable = AppSettings.shared.$screenshotsToTray
            .removeDuplicates()
            .sink { [weak self] enabled in
                if enabled { self?.watch() } else { self?.stop() }
            }
    }

    /// Starts over, which asks for folder access again if macOS hasn't been asked yet.
    func restart() {
        guard AppSettings.shared.screenshotsToTray else { return }
        watch()
    }

    /// Where macOS saves screenshots and screen recordings: the Screenshot app's choices, or the Desktop.
    static func folders() -> [URL] {
        CFPreferencesAppSynchronize(domain)
        let screenshots = folder(preferring: "location-screenshot")
        let recordings = folder(preferring: "location-screenrecording")
        return screenshots.path == recordings.path ? [screenshots] : [screenshots, recordings]
    }

    /// "Desktop", or "Documents and Movies" when screenshots and recordings go to different folders.
    static var folderNames: String {
        folders().map { FileManager.default.displayName(atPath: $0.path) }.joined(separator: " and ")
    }

    /// Where the Screenshot app saves screenshots, which is where Dynotch's own captures go too.
    static func saveFolder() -> URL {
        CFPreferencesAppSynchronize(domain)
        return folder(preferring: "location-screenshot")
    }

    // MARK: Private

    private func watch() {
        stop()
        let folders = Self.folders()
        let started = generation
        // Off the main thread: macOS holds the first look at a folder until its prompt is answered,
        // and the notch would freeze meanwhile.
        queue.async {
            let listings = folders.map { ($0, Self.list($0)) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard started == self.generation else { return }
                    for (folder, listing) in listings {
                        if let names = self.files(in: listing) { self.startWatching(folder, seen: names) }
                    }
                }
            }
        }

        // The save location can change in the Screenshot app's Options menu, and nothing announces it.
        locationPoll = EnergyCoordinator.shared.schedule(.screenshotFolder) { [weak self] in
            guard let self else { return }
            let current = Self.folders().map(\.path)
            if current != self.watches.map(\.folder.path) { self.watch() }
        }
    }

    private func startWatching(_ folder: URL, seen names: [String]) {
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        let watch = Watch(folder: folder, source: source, seen: Set(names))
        source.setEventHandler { [weak self, weak watch] in
            MainActor.assumeIsolated {
                guard let self, let watch else { return }
                self.scan(watch)
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watches.append(watch)
    }

    private func stop() {
        generation += 1
        watches.forEach { $0.source.cancel() }
        watches.removeAll()
        locationPoll?.cancel()
        locationPoll = nil
    }

    private func scan(_ watch: Watch) {
        guard let names = files(in: Self.list(watch.folder)) else { return }
        var fresh: [URL] = []
        var waiting = false
        for name in names where !watch.seen.contains(name) {
            let url = watch.folder.appendingPathComponent(name)
            if Self.isScreenCapture(url) {
                watch.seen.insert(name)
                fresh.append(url)
            } else if Self.age(of: url) < 10 {
                // The tag can arrive a moment after the file; look again shortly.
                waiting = true
            } else {
                watch.seen.insert(name)
            }
        }
        watch.seen.formIntersection(names)
        if waiting, !watch.isRetrying {
            watch.isRetrying = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak watch] in
                MainActor.assumeIsolated {
                    guard let self, let watch else { return }
                    watch.isRetrying = false
                    self.scan(watch)
                }
            }
        }
        guard !fresh.isEmpty else { return }
        TrayStore.shared.add(fresh, automatically: true)
        let recording = fresh.count == 1 && Self.isScreenRecording(fresh[0])
        let detail = fresh.count > 1 ? "\(fresh.count) screen captures added to the Tray"
            : recording ? "Screen recording added to the Tray" : "Screenshot added to the Tray"
        var actions = [NoticeAction(title: "Show", kind: .openTab(.tray))]
        if fresh.count == 1 { actions.append(NoticeAction(title: "Open", kind: .openFile(fresh[0]))) }
        LiveActivityCenter.shared.post(LiveNotice(key: "screenshot", symbol: recording ? "record.circle" : "camera.viewfinder",
                                                  tint: .white, detail: detail, actions: actions, timing: .waits,
                                                  recall: .whole), for: 2.6)
    }

    /// The visible files in a folder.
    nonisolated private static func list(_ folder: URL) -> Listing {
        do {
            return .names(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") })
        } catch CocoaError.fileReadNoPermission {
            return .denied
        } catch {
            return .unreadable
        }
    }

    /// A listing's files, or nil if the folder couldn't be read. Notes whether it could.
    private func files(in listing: Listing) -> [String]? {
        switch listing {
        case .names(let names):
            access = .granted
            return names
        case .denied:
            access = .denied
            return nil
        case .unreadable:
            return nil
        }
    }

    private static func folder(preferring key: String) -> URL {
        for key in [key, "location"] {
            guard let path = CFPreferencesCopyAppValue(key as CFString, domain) as? String, !path.isEmpty else { continue }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return url
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// macOS tags screenshots with kMDItemIsScreenCapture and screen recordings with kMDItemIsScreenRecording.
    private static func isScreenCapture(_ url: URL) -> Bool {
        hasAttribute("com.apple.metadata:kMDItemIsScreenCapture", url) || isScreenRecording(url)
    }

    private static func isScreenRecording(_ url: URL) -> Bool {
        hasAttribute("com.apple.metadata:kMDItemIsScreenRecording", url)
    }

    private static func hasAttribute(_ name: String, _ url: URL) -> Bool {
        getxattr(url.path, name, nil, 0, 0, 0) > 0
    }

    private static func age(of url: URL) -> TimeInterval {
        let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
        return Date.now.timeIntervalSince(created)
    }
}
