import Combine
import DynotchShared
import SwiftUI

/// A GitHub Actions run being watched.
struct CIRun: Identifiable, Equatable {
    enum Phase: Equatable {
        case queued
        /// Held for an approval or a protected environment.
        case waiting
        case running
    }

    let id: Int
    var repository: String
    var branch: String
    var workflow: String
    /// Nil if GitHub's link didn't pass `CIMonitor.checkedURL`, and then there's no button.
    var url: URL?
    var phase = Phase.running
    /// How long it's been going as of the last look, so nothing ticks between looks.
    var seconds = 0
    /// The runs this push started, and how many of those are over.
    var total = 1
    var finished = 0

    /// The right ear: how far along the push is, or how long it's taken, or a word.
    var statusText: String {
        switch phase {
        case .queued: "Queued"
        case .waiting: "Waiting"
        case .running: total > 1 ? "\(finished) of \(total)" : seconds < 60 ? "Running" : elapsedText
        }
    }

    /// "40s", "2m", "1h 5m"
    var elapsedText: String {
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }

    /// The glance's second line: "main · 2m · 3 runs"
    var summary: String {
        "\(branch) · \(elapsedText) · \(total == 1 ? "1 run" : "\(total) runs")"
    }

    /// The glance's button.
    var openAction: NoticeAction? {
        url.map { NoticeAction(title: "Open", kind: .openURL($0)) }
    }
}

/// Watches GitHub Actions through `gh`, only while a run is active. Dynotch stores no token: `gh`
/// uses the user's own login. A watch starts from `dynotch ci`, which can name only a repository, a
/// branch and a commit, each of them checked here, since `gh` runs with whatever Dynotch may hold.
///
/// A push can start several workflows. Every run for its head commit counts: one failing fails the
/// push straight away, and otherwise the push is over when they all are. A skipped or neutral run
/// decides nothing, and a cancelled one means the push neither passed nor failed.
///
/// Asking again for a branch that's being watched replaces that watch, since a new push supersedes
/// the last. Any other branch or repository is added, up to `mostWatches`.
@MainActor
final class CIMonitor: ObservableObject {
    static let shared = CIMonitor()

    static let mostWatches = 4
    nonisolated static let longestBranch = 255
    /// A run takes a few seconds to appear after a push. Past this, nothing is coming.
    static let grace: TimeInterval = 120
    /// A run can sit queued for as long as there's no runner. GitHub ends a job after six hours.
    static let longestWatch: TimeInterval = 6 * 3600
    /// Looks in a row that can fail before giving up. A count rather than a time, so that a Mac
    /// that slept through a failure doesn't give up on waking.
    static let mostFailures = 20
    /// Runs all over this soon after they were made might not be all there is: another workflow of
    /// the same push may not have appeared yet, so they get one more look.
    static let settling: TimeInterval = 30

    static let reviewsPage = URL(string: "https://github.com/pulls/review-requested")!
    /// Bright enough to read on the black.
    nonisolated static let tint = Color(red: 1.0, green: 0.78, blue: 0.28)

    /// The run on show, while one is active.
    @Published private(set) var run: CIRun?
    /// Other pushes with a run going.
    @Published private(set) var others = 0
    /// Pull requests waiting for your review.
    @Published private(set) var reviewCount = 0

    /// One push being watched.
    private struct Watch {
        let id = UUID()
        let repository: String
        let branch: String
        /// Its head commit. With none named, the newest run on the branch settles which it is.
        var sha: String?
        let askedAt: Date
        var lastSeen: Date
        /// Its runs at the last look, oldest first.
        var runs: [GitHubRun] = []
        var failures = 0
        var hasSettled = false
        var shown: CIRun?

        func owns(_ run: GitHubRun) -> Bool {
            sha.map { run.headSha.lowercased().hasPrefix($0) } ?? false
        }

        func isOn(_ repository: String, _ branch: String) -> Bool {
            self.repository.lowercased() == repository.lowercased() && self.branch == branch
        }
    }

    private var watches: [Watch] = []
    private var poll: Poll?
    private var reviewPoll: Poll?
    private var isLooking = false
    private var needsLook = false
    private var isCounting = false
    private var cancellables = Set<AnyCancellable>()
    private let runner: GitHubCLI.Runner
    private let post: @MainActor (LiveNotice, TimeInterval) -> Void
    private let coordinator: EnergyCoordinator

    /// Tests hand in their own `gh`, and never reach the real one.
    init(runner: @escaping GitHubCLI.Runner = { await GitHubCLI.run($0) },
         post: @escaping @MainActor (LiveNotice, TimeInterval) -> Void = { LiveActivityCenter.shared.post($0, for: $1) },
         coordinator: EnergyCoordinator? = nil) {
        self.runner = runner
        self.post = post
        self.coordinator = coordinator ?? .shared
    }

    func start(on router: SocketRouter? = nil) {
        let router = router ?? .shared
        router.handle("ci") { [weak self] request, connection in
            guard let self else { return }
            connection.reply(self.apply(request))
            self.lookSoon()
        }
        router.reportsStatus("ci") { [weak self] in self?.statusReport(at: .now) ?? [:] }
        AppSettings.shared.$liveCI
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] isOn in
                if !isOn { self?.stopWatching() }
                self?.followReviews(liveCI: isOn)
            }
            .store(in: &cancellables)
        followReviews()
    }

    var isWatching: Bool { !watches.isEmpty }

    // MARK: Requests

    /// Carries out a `ci` request, and says how it went.
    func apply(_ request: SocketRequest, now: Date = .now) -> [String: Any] {
        if request.fields["stop"] as? Bool == true {
            return ["ok": true, "stopped": stopWatching(repository: request.string("repo"), branch: request.string("branch"))]
        }
        guard AppSettings.shared.liveCI else { return Self.refusal("CI runs are switched off in Settings") }
        guard let repository = request.string("repo"), GitHubName.isRepository(repository) else {
            return Self.refusal("That isn't a repository: it should look like OWNER/NAME")
        }
        guard let branch = request.string("branch"), Self.isBranch(branch) else { return Self.refusal("That isn't a branch") }
        let sha = request.string("sha")?.lowercased()
        if let sha, !Self.isCommit(sha) { return Self.refusal("That isn't a commit") }

        let watch = Watch(repository: repository, branch: branch, sha: sha, askedAt: now, lastSeen: now)
        if let index = watches.firstIndex(where: { $0.isOn(repository, branch) }) {
            // Asked twice about one push, as by the hook and by hand: the look under way goes on.
            guard sha == nil || watches[index].sha != sha else { return ["ok": true] }
            watches[index] = watch
        } else {
            guard watches.count < Self.mostWatches else { return Self.refusal("\(Self.mostWatches) branches are being watched already") }
            watches.append(watch)
        }
        if !AppSettings.shared.hasAskedForCI { AppSettings.shared.hasAskedForCI = true }
        needsLook = isLooking
        followReviews()
        publish()
        return ["ok": true]
    }

    private static func refusal(_ reason: String) -> [String: Any] { ["ok": false, "error": reason] }

    /// Stops without a word, all of it unless narrowed. How many watches stopped.
    @discardableResult
    private func stopWatching(repository: String? = nil, branch: String? = nil) -> Int {
        let count = watches.count
        watches.removeAll { watch in
            (repository.map { $0.lowercased() == watch.repository.lowercased() } ?? true) && (branch.map { $0 == watch.branch } ?? true)
        }
        publish()
        return count - watches.count
    }

    // MARK: Checks

    /// A name git would take for a branch, with nothing that could pass for an option.
    static func isBranch(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= longestBranch, !text.hasPrefix("-"), !text.hasPrefix("/"), !text.hasSuffix("/"),
              !text.hasSuffix("."), !text.hasSuffix(".lock"), !text.contains(".."), !text.contains("@{"), !text.contains("//") else {
            return false
        }
        let refused = CharacterSet.controlCharacters.union(.whitespacesAndNewlines).union(CharacterSet(charactersIn: "~^:?*[\\"))
        return text.unicodeScalars.allSatisfy { !refused.contains($0) }
    }

    /// A commit's hash, or the start of one.
    static func isCommit(_ text: String) -> Bool {
        (7...64).contains(text.utf8.count) && text.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }

    /// Only an https page on github.com itself gets a button, whatever came back from `gh`.
    static func checkedURL(_ text: String) -> URL? {
        guard let parts = URLComponents(string: text), parts.scheme?.lowercased() == "https", parts.host?.lowercased() == "github.com",
              parts.user == nil, parts.password == nil, parts.port == nil else { return nil }
        return parts.url
    }

    // MARK: Looking

    /// One look at GitHub for each push, one after another. A look under way is left to finish.
    func look(now: Date = .now) async {
        guard !isLooking else { return }
        isLooking = true
        for id in watches.map(\.id) {
            guard let watch = watches.first(where: { $0.id == id }) else { continue }
            let answer = await runner(GitHubCLI.listArguments(repository: watch.repository, branch: watch.branch))
            // It may have been stopped or replaced while `gh` ran.
            guard watches.contains(where: { $0.id == id }) else { continue }
            read(answer, for: id, now: now)
            publish()
        }
        isLooking = false
        if needsLook {
            needsLook = false
            await look(now: now)
        }
    }

    private func lookSoon() {
        Task { [weak self] in await self?.look() }
    }

    private func read(_ answer: GitHubAnswer, for id: UUID, now: Date) {
        guard let index = watches.firstIndex(where: { $0.id == id }) else { return }
        let watch = watches[index]
        switch answer.problem {
        case .notInstalled:
            stopWatching()
            say("Needs gh", "Install GitHub's gh command to follow CI")
        case .signedOut:
            stopWatching()
            say("Signed out", "Run gh auth login to follow CI")
        case .notFound:
            watches.remove(at: index)
            say("Not found", "gh can't see \(watch.repository)")
        case .transient:
            struggled(at: index)
        case nil:
            guard let runs = answer.output.flatMap(GitHubRun.list) else { return struggled(at: index) }
            see(runs, at: index, now: now)
        }
    }

    /// Something passing got in the way. It's fine for a while, as a network often comes back.
    private func struggled(at index: Int) {
        watches[index].failures += 1
        let watch = watches[index]
        guard watch.failures >= Self.mostFailures else { return }
        watches.remove(at: index)
        say("No answer", "Stopped following CI on \(watch.branch)", runs: watch.runs)
    }

    private func see(_ listed: [GitHubRun], at index: Int, now: Date) {
        var watch = watches[index]
        watch.failures = 0
        if watch.sha == nil { watch.sha = listed.first.map { $0.headSha.lowercased() } }
        let runs = listed.filter(watch.owns).sorted { ($0.created ?? .distantPast, $0.databaseId) < ($1.created ?? .distantPast, $1.databaseId) }
        guard !runs.isEmpty else {
            // Nothing yet. A repository with no workflows ends here, with nothing to say.
            if now.timeIntervalSince(watch.lastSeen) >= Self.grace {
                watches.remove(at: index)
            } else {
                watches[index] = watch
            }
            return
        }
        watch.runs = runs
        watch.lastSeen = now
        if runs.contains(where: { $0.verdict == .failed }) {
            return finish(at: index, watch, as: .failed)
        }
        if runs.allSatisfy(\.isOver) {
            let isFresh = runs.compactMap(\.created).max().map { now.timeIntervalSince($0) < Self.settling } ?? false
            guard isFresh, !watch.hasSettled else { return finish(at: index, watch, as: GitHubRun.verdict(of: runs)) }
            watch.hasSettled = true
        } else if now.timeIntervalSince(watch.askedAt) >= Self.longestWatch {
            watches.remove(at: index)
            return say("Still running", "Stopped following CI on \(watch.branch)", runs: runs)
        }
        watch.shown = Self.shown(runs, of: watch, now: now)
        watches[index] = watch
    }

    /// The run in the notch: the oldest one running, or else the oldest yet to start.
    private static func shown(_ runs: [GitHubRun], of watch: Watch, now: Date) -> CIRun {
        let going = runs.first { !$0.isOver && $0.phase == .running } ?? runs.first { !$0.isOver } ?? runs[0]
        let started = runs.compactMap(\.created).min() ?? watch.askedAt
        return CIRun(id: going.databaseId, repository: watch.repository, branch: watch.branch, workflow: going.name,
                     url: checkedURL(going.url), phase: going.phase, seconds: max(Int(now.timeIntervalSince(started)), 0),
                     total: runs.count, finished: runs.filter(\.isOver).count)
    }

    private func finish(at index: Int, _ watch: Watch, as verdict: GitHubRun.Verdict) {
        watches.remove(at: index)
        // A failure is about the runs that failed, and the same goes for a cancelled one.
        let named = verdict == .failed || verdict == .cancelled ? watch.runs.filter { $0.verdict == verdict } : watch.runs
        post(Self.notice(verdict, workflows: Self.names(of: named), branch: watch.branch, url: Self.firstLink(in: named)),
             verdict == .failed ? 6 : 4)
    }

    private static func firstLink(in runs: [GitHubRun]) -> URL? {
        runs.lazy.compactMap { checkedURL($0.url) }.first
    }

    private static func openRun(_ url: URL?) -> [NoticeAction] {
        url.map { [NoticeAction(title: "Open Run", kind: .openURL($0))] } ?? []
    }

    /// "CI", "CI and Docs", "CI and 2 more"
    private static func names(of runs: [GitHubRun]) -> String {
        var names: [String] = []
        for run in runs where !names.contains(run.name) { names.append(run.name) }
        switch names.count {
        case 0: return "Workflow"
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names[0]) and \(names.count - 1) more"
        }
    }

    /// What GitHub said about a push. No script's badge: Dynotch is reporting it, and what a request
    /// can make it say is limited to what `gh` returns for a checked repository.
    static func notice(_ verdict: GitHubRun.Verdict, workflows: String, branch: String, url: URL?) -> LiveNotice {
        let symbol: String, tint: Color, text: String
        switch verdict {
        case .passed: (symbol, tint, text) = ("checkmark.circle.fill", .green, "Passed")
        case .failed: (symbol, tint, text) = ("xmark.octagon.fill", .red, "Failed")
        case .cancelled: (symbol, tint, text) = ("stop.circle.fill", .gray, "Cancelled")
        case .skipped: (symbol, tint, text) = ("forward.circle.fill", .gray, "Skipped")
        }
        return LiveNotice(key: "ci", symbol: symbol, tint: tint, text: text, detail: "\(workflows) · \(branch)",
                          actions: openRun(url), timing: .waits, recall: .whole)
    }

    /// Why following a push stopped short.
    private func say(_ text: String, _ detail: String, runs: [GitHubRun] = []) {
        post(LiveNotice(key: "ci", symbol: "exclamationmark.triangle.fill", tint: .orange, text: text, detail: detail,
                        actions: Self.openRun(Self.firstLink(in: runs)), timing: .waits, recall: .whole), 6)
    }

    /// Shows what's current, and polls only while something's being watched.
    private func publish() {
        let shown = watches.compactMap(\.shown)
        if run != shown.first { run = shown.first }
        if others != max(shown.count - 1, 0) { others = max(shown.count - 1, 0) }
        if watches.isEmpty {
            poll?.cancel()
            poll = nil
        } else if poll == nil {
            poll = coordinator.schedule(.ciRun) { [weak self] in self?.lookSoon() }
        }
    }

    // MARK: Reviews

    /// Dynotch calls `gh` by itself only for someone who has asked for CI, and only with the switch on.
    private var countsReviews: Bool { AppSettings.shared.liveCI && AppSettings.shared.hasAskedForCI }

    /// Counts pull requests waiting for your review. A failure that can pass leaves the count as it was.
    func countReviews() async {
        guard countsReviews, !isCounting else { return }
        isCounting = true
        defer { isCounting = false }
        let answer = await runner(GitHubCLI.reviewArguments)
        guard countsReviews else { return }
        switch answer.problem {
        case nil:
            guard let data = answer.output,
                  let list = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return }
            setReviewCount(list.count)
        case .notInstalled, .signedOut:
            setReviewCount(0)
        case .notFound, .transient:
            break
        }
    }

    /// `liveCI` says what the switch is about to be, since a setting's publisher fires before it changes.
    private func followReviews(liveCI: Bool? = nil) {
        if liveCI ?? AppSettings.shared.liveCI, AppSettings.shared.hasAskedForCI {
            guard reviewPoll == nil else { return }
            reviewPoll = coordinator.schedule(.ciReviews) { [weak self] in self?.countSoon() }
            countSoon()
        } else {
            reviewPoll?.cancel()
            reviewPoll = nil
            setReviewCount(0)
        }
    }

    private func countSoon() {
        Task { [weak self] in await self?.countReviews() }
    }

    private func setReviewCount(_ count: Int) {
        if reviewCount != count { reviewCount = count }
    }

    /// "1 review", "3 reviews"
    static func reviewsText(_ count: Int) -> String { count == 1 ? "1 review" : "\(count) reviews" }

    // MARK: Status

    /// What `dynotch status` says.
    func statusReport(at now: Date) -> [String: Any] {
        let watching: [[String: Any]] = watches.map { watch in
            var report: [String: Any] = ["repository": watch.repository, "branch": watch.branch, "runs": watch.runs.count,
                                         "finished": watch.runs.filter(\.isOver).count,
                                         "secondsWatching": max(Int(now.timeIntervalSince(watch.askedAt)), 0)]
            report["sha"] = watch.sha ?? NSNull()
            report["workflow"] = watch.shown?.workflow ?? NSNull()
            return report
        }
        return ["reviews": reviewCount, "watching": watching]
    }

    // MARK: Snapshots

    func loadSample(_ run: CIRun?, others: Int = 0, reviewCount: Int = 0) {
        self.run = run
        self.others = others
        self.reviewCount = reviewCount
    }

    /// Back to nothing, between snapshot scenes.
    func clearSample() {
        loadSample(nil)
    }
}
