import AppKit
import Combine
import SwiftUI

/// Files arriving in ~/Downloads. Safari's `.download` bundles keep the bytes so far and the
/// total in their Info.plist, so they get a real percentage; Chrome's `.crdownload`, Firefox's
/// `.part` and Opera's `.opdownload` files only grow, so they show their size. When one
/// finishes, the notch says so, and the file can go straight into the Tray.
@MainActor
final class DownloadMonitor: ObservableObject {
    static let shared = DownloadMonitor()

    /// A download that's moving.
    struct Download: Identifiable, Equatable {
        /// The partial file's or bundle's name.
        let id: String
        var received: Int64
        var total: Int64?
    }

    enum Access: Equatable {
        case unknown, granted, denied
    }

    @Published private(set) var downloads: [Download] = []
    @Published private(set) var access: Access = .unknown

    nonisolated static let tint = Color(red: 0.36, green: 0.62, blue: 1.0)

    /// The share of the bytes that have arrived, when every download knows its size.
    var fraction: Double? {
        let totals = downloads.compactMap(\.total)
        guard !downloads.isEmpty, totals.count == downloads.count else { return nil }
        let total = totals.reduce(0, +)
        return total > 0 ? min(1, Double(received) / Double(total)) : nil
    }

    var received: Int64 { downloads.reduce(0) { $0 + $1.received } }

    let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]

    /// A download that hasn't grown for this long leaves the notch until it moves again.
    private static let idleTimeout: TimeInterval = 20
    nonisolated private static let partialExtensions: Set<String> = ["download", "crdownload", "part", "opdownload"]

    private struct Partial {
        var received: Int64
        var total: Int64?
        var modified: Date
    }

    private struct Tracked {
        var received: Int64
        var total: Int64?
        var lastGrowth: Date
    }

    private enum Listing {
        case listed(names: Set<String>, partials: [String: Partial])
        case denied
        case unavailable
    }

    private let queue = DispatchQueue(label: "app.dynotch.downloads", qos: .utility)
    private var tracked: [String: Tracked] = [:]
    private var names: Set<String> = []
    private var isWatching = false
    private var isScanning = false
    private var needsScan = false
    private var source: DispatchSourceFileSystemObject?
    private var poll: Timer?
    private var pollInterval: TimeInterval = 0
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    /// Watches while the activity or the Tray option is on. The first look at the folder is
    /// what makes macOS ask for access.
    func start() {
        let settings = AppSettings.shared
        Publishers.CombineLatest(settings.$liveDownloads, settings.$downloadsToTray)
            .map { $0 || $1 }
            .removeDuplicates()
            .sink { [weak self] on in on ? self?.watch() : self?.stopWatching() }
            .store(in: &cancellables)
    }

    /// Looks again, and opens System Settings when access was turned down.
    func requestAccess() {
        if access == .denied { CalendarService.openPrivacySettings("Privacy_FilesAndFolders") }
        scan()
    }

    // MARK: Watching

    private func watch() {
        guard !isWatching else { return }
        isWatching = true
        scan()
    }

    private func stopWatching() {
        isWatching = false
        source?.cancel()
        source = nil
        setPolling(nil)
        tracked = [:]
        names = []
        downloads = []
    }

    private func scan() {
        guard !isScanning else {
            needsScan = true
            return
        }
        isScanning = true
        let folder = folder
        // Off the main thread: macOS can hold the first look until its prompt is answered.
        queue.async {
            let listing = Self.list(folder)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.apply(listing) }
            }
        }
    }

    private func apply(_ listing: Listing) {
        isScanning = false
        switch listing {
        case .listed(let names, let partials):
            access = .granted
            if isWatching { update(names: names, partials: partials) }
        case .denied:
            access = .denied
            stopWatchingFolder()
        case .unavailable:
            stopWatchingFolder()
        }
        if needsScan {
            needsScan = false
            scan()
        }
    }

    private func stopWatchingFolder() {
        source?.cancel()
        source = nil
        setPolling(nil)
        tracked = [:]
        downloads = []
    }

    private func update(names newNames: Set<String>, partials: [String: Partial]) {
        let now = Date.now
        var next: [String: Tracked] = [:]
        for (name, partial) in partials {
            if var known = tracked[name] {
                if partial.received != known.received || partial.total != known.total { known.lastGrowth = now }
                known.received = partial.received
                known.total = partial.total
                next[name] = known
            } else {
                // Seen for the first time: it's moving if it changed lately.
                next[name] = Tracked(received: partial.received, total: partial.total, lastGrowth: partial.modified)
            }
        }

        // Partials that are gone finished or were cancelled; a finished one leaves its file behind.
        let appeared = newNames.subtracting(names).filter { !Self.isPartial($0) }
        for (name, known) in tracked where next[name] == nil && now.timeIntervalSince(known.lastGrowth) < 120 {
            if let file = finishedFile(for: name, appeared: appeared, in: newNames) { didFinish(file) }
        }
        tracked = next
        names = newNames

        let moving = next
            .filter { now.timeIntervalSince($0.value.lastGrowth) < Self.idleTimeout }
            .map { Download(id: $0.key, received: $0.value.received, total: $0.value.total) }
            .sorted { $0.id < $1.id }
        if moving != downloads { downloads = moving }

        if source == nil { openSource() }
        // A growing file doesn't change the folder, so look often while one is moving and now and
        // then while a stalled one sits there.
        let recent = next.values.contains { now.timeIntervalSince($0.lastGrowth) < 120 }
        setPolling(next.isEmpty ? nil : recent ? 1 : 10)
    }

    /// The file a partial download turned into: its name without the partial extension, or for
    /// Chrome's "Unconfirmed 123.crdownload", the one file that just appeared.
    private func finishedFile(for partial: String, appeared: Set<String>, in names: Set<String>) -> URL? {
        let expected = (partial as NSString).deletingPathExtension
        guard let name = names.contains(expected) ? expected : appeared.count == 1 ? appeared.first : nil else { return nil }
        let url = folder.appendingPathComponent(name)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]) else { return nil }
        // Firefox leaves an empty placeholder behind when a download is cancelled.
        return values.isDirectory == true || (values.fileSize ?? 0) > 0 ? url : nil
    }

    private func didFinish(_ file: URL) {
        let settings = AppSettings.shared
        if settings.liveDownloads {
            LiveActivityCenter.shared.post(LiveNotice(key: "download", symbol: "arrow.down.circle.fill", tint: Self.tint,
                                                      text: "Downloaded", detail: file.lastPathComponent), for: 4)
        }
        if settings.downloadsToTray { TrayStore.shared.add([file]) }
    }

    private func openSource() {
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scan() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    private func setPolling(_ interval: TimeInterval?) {
        guard interval != (poll == nil ? nil : pollInterval) else { return }
        poll?.invalidate()
        poll = nil
        guard let interval else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan() }
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
        pollInterval = interval
    }

    // MARK: Reading the folder

    nonisolated private static func isPartial(_ name: String) -> Bool {
        partialExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    nonisolated private static func list(_ folder: URL) -> Listing {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            return .denied
        } catch {
            return .unavailable
        }
        var partials: [String: Partial] = [:]
        for name in names where isPartial(name) {
            if let partial = measure(folder.appendingPathComponent(name)) { partials[name] = partial }
        }
        return .listed(names: Set(names), partials: partials)
    }

    nonisolated private static func measure(_ url: URL) -> Partial? {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        guard values.isDirectory == true else {
            return Partial(received: Int64(values.fileSize ?? 0), total: nil, modified: values.contentModificationDate ?? .distantPast)
        }
        // A Safari bundle: the progress is in Info.plist, the data in the one big file beside it.
        let info = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist"))
        let inside = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys))) ?? []
        let files = inside.compactMap { try? $0.resourceValues(forKeys: keys) }
        let largest = Int64(files.compactMap(\.fileSize).max() ?? 0)
        let soFar = (info?["DownloadEntryProgressBytesSoFar"] as? NSNumber)?.int64Value ?? 0
        let total = (info?["DownloadEntryProgressTotalToLoad"] as? NSNumber)?.int64Value
        let modified = ([values] + files).compactMap(\.contentModificationDate).max() ?? .distantPast
        return Partial(received: max(soFar, largest), total: total.flatMap { $0 > 0 ? $0 : nil }, modified: modified)
    }

    // MARK: Snapshots

    func loadSample(knowsSize: Bool) {
        downloads = knowsSize
            ? [Download(id: "Keynote Themes.zip.download", received: 61_400_000, total: 136_000_000)]
            : [Download(id: "Ubuntu Desktop.iso.crdownload", received: 482_300_000, total: nil)]
        access = .granted
    }
}
