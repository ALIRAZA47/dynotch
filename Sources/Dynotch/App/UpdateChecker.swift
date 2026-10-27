import AppKit
import Combine

/// Looks up Dynotch's newest release on GitHub and compares it with this build. It checks by
/// itself once a day while "Check automatically" is on, and on request from Settings → About or
/// the menu bar menu. Nothing is installed from here: Download opens the release's disk image in
/// the browser, and the README says how to swap the app.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    /// Where releases are published.
    static let repository = "ALIRAZA47/dynotch"
    static let releasesPage = URL(string: "https://github.com/\(repository)/releases/latest")!
    /// This build's version, from Info.plist. A bare `swift build` binary has none and passes as 1.0.
    static let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"

    struct Release: Equatable {
        /// "1.1.0": the tag without its "v".
        var version: String
        var title: String
        /// The release notes, as Markdown.
        var notes: String
        /// The release's page on GitHub.
        var page: URL
        /// The disk image, when the release has one.
        var download: URL?
        var publishedAt: Date?
    }

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case failed(String)
    }

    @Published private(set) var status = Status.idle
    @Published private(set) var lastChecked: Date? = UserDefaults.dynotch.object(forKey: "updateLastChecked") as? Date

    /// Once a day, while someone's looking; a day that passes while the Mac sleeps counts on waking.
    private static let cadence = Cadence(name: "Update check", every: 24 * 3600, onBattery: 24 * 3600, lowPower: 24 * 3600)
    private static let endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    private var poll: Poll?
    private var launchCheck: Task<Void, Never>?
    private var running: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    /// The version the notch has announced, so each one is announced once.
    private var noticedVersion: String? = UserDefaults.dynotch.string(forKey: "updateNoticedVersion")

    private init() {}

    func start() {
        AppSettings.shared.$checksForUpdates
            .removeDuplicates()
            .sink { [weak self] on in self?.setAutomatic(on) }
            .store(in: &cancellables)
    }

    /// Asks GitHub now. A check already under way is waited for instead of starting another.
    func check() async {
        if let running {
            await running.value
            return
        }
        let task = Task { await self.perform() }
        running = task
        await task.value
        running = nil
    }

    // MARK: Automatic checks

    private func setAutomatic(_ on: Bool) {
        poll?.cancel()
        poll = nil
        launchCheck?.cancel()
        launchCheck = nil
        guard on else { return }
        poll = EnergyCoordinator.shared.schedule(Self.cadence) { [weak self] in self?.checkQuietly() }
        // A little after launch if a day has passed, so starting up never waits on the network.
        let due = lastChecked.map { Date.now.timeIntervalSince($0) > Self.cadence.every - 3600 } ?? true
        guard due else { return }
        launchCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.checkQuietly()
        }
    }

    /// A check nobody asked for: a new version is announced in the notch, once; a failure stays quiet.
    private func checkQuietly() {
        Task { [weak self] in
            guard let self else { return }
            await check()
            guard case .available(let release) = status, noticedVersion != release.version else { return }
            noticedVersion = release.version
            UserDefaults.dynotch.set(release.version, forKey: "updateNoticedVersion")
            LiveActivityCenter.shared.post(LiveNotice(key: "update", symbol: "arrow.down.circle.fill",
                                                      tint: NotchAccent.lavender.color, text: "Update",
                                                      detail: "Dynotch \(release.version) is ready to download"), for: 5)
        }
    }

    // MARK: The check

    private func perform() async {
        status = .checking
        do {
            let release = try await Self.fetchLatest()
            lastChecked = .now
            UserDefaults.dynotch.set(lastChecked, forKey: "updateLastChecked")
            status = Self.isNewer(release.version, than: Self.currentVersion) ? .available(release) : .upToDate
        } catch {
            status = .failed(Self.describe(error))
        }
    }

    private struct Payload: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: URL
        }

        let tagName: String
        let name: String?
        let body: String?
        let htmlUrl: URL
        let publishedAt: Date?
        let assets: [Asset]
    }

    private enum CheckError: Error {
        case noReleases, rateLimited, badResponse, status(Int)
    }

    private static func fetchLatest() async throws -> Release {
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Dynotch/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CheckError.badResponse }
        switch http.statusCode {
        case 200: break
        case 404: throw CheckError.noReleases
        case 403, 429: throw CheckError.rateLimited
        default: throw CheckError.status(http.statusCode)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(Payload.self, from: data)
        let version = Self.versionText(of: payload.tagName)
        return Release(version: version,
                       title: payload.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Dynotch \(version)",
                       notes: payload.body ?? "",
                       page: payload.htmlUrl,
                       download: payload.assets.first { $0.name.lowercased().hasSuffix(".dmg") }?.browserDownloadUrl
                           ?? payload.assets.first { $0.name.lowercased().hasSuffix(".zip") }?.browserDownloadUrl,
                       publishedAt: payload.publishedAt)
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case CheckError.noReleases: "No release is published yet."
        case CheckError.rateLimited: "GitHub is limiting requests from this Mac for now. Try again in an hour."
        case CheckError.badResponse: "GitHub's answer couldn't be read."
        case CheckError.status(let code): "GitHub answered with an error (HTTP \(code))."
        case let error as URLError where error.code == .timedOut: "GitHub took too long to answer. Try again."
        case is URLError: "Couldn't reach GitHub. Check your connection and try again."
        case is DecodingError: "GitHub's answer couldn't be read."
        default: error.localizedDescription
        }
    }

    // MARK: Versions

    /// Whether `candidate` is a later version than `current`: "1.2.0" is newer than "1.1.9" and "v1.2".
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = components(of: a), y = components(of: b)
        for index in 0..<max(x.count, y.count) {
            let l = index < x.count ? x[index] : 0, r = index < y.count ? y[index] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// "v1.2.3" without the "v"; a suffix like "-beta.1" or "+42" is left off.
    static func versionText(of tag: String) -> String {
        var text = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        if let cut = text.firstIndex(where: { $0 == "-" || $0 == "+" }) { text = String(text[..<cut]) }
        return text
    }

    private static func components(of version: String) -> [Int] {
        versionText(of: version).split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
    }

    /// "just now", "5 minutes ago", "yesterday".
    static func describe(_ date: Date, from now: Date = .now) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        return date.formatted(.relative(presentation: .named))
    }
}
