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

    // MARK: Private

    private func watch() {
        stop()
        for folder in Self.folders() {
            guard let names = listing(of: folder) else { continue }
            let descriptor = open(folder.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
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

        // The save location can change in the Screenshot app's Options menu, and nothing announces it.
        locationPoll = EnergyCoordinator.shared.schedule(.screenshotFolder) { [weak self] in
            guard let self else { return }
            let current = Self.folders().map(\.path)
            if current != self.watches.map(\.folder.path) { self.watch() }
        }
    }

    private func stop() {
        watches.forEach { $0.source.cancel() }
        watches.removeAll()
        locationPoll?.cancel()
        locationPoll = nil
    }

    private func scan(_ watch: Watch) {
        guard let names = listing(of: watch.folder) else { return }
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
        TrayStore.shared.add(fresh)
        let recording = fresh.count == 1 && Self.isScreenRecording(fresh[0])
        let detail = fresh.count > 1 ? "\(fresh.count) screen captures added to the Tray"
            : recording ? "Screen recording added to the Tray" : "Screenshot added to the Tray"
        LiveActivityCenter.shared.post(LiveNotice(key: "screenshot", symbol: recording ? "record.circle" : "camera.viewfinder",
                                                  tint: .white, detail: detail), for: 2.6)
    }

    /// The visible files in a folder, or nil if it can't be read.
    private func listing(of folder: URL) -> [String]? {
        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            access = .granted
            return names.filter { !$0.hasPrefix(".") }
        } catch CocoaError.fileReadNoPermission {
            access = .denied
            return nil
        } catch {
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
