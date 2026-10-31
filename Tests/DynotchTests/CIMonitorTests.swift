import Darwin
import Foundation
import Testing
@testable import Dynotch

/// Stands in for `gh`: answers each call with the next of what it's given, and remembers the calls.
private final class FakeGitHub: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [GitHubAnswer] = []
    private var calls: [[String]] = []
    private var running = 0
    private var mostRunning = 0
    private var isHolding = false
    private var held: [CheckedContinuation<Void, Never>] = []
    /// The answer to a look with nothing lined up.
    var standing = GitHubAnswer.finished(status: 0, output: Data("[]".utf8), error: "")
    var reviews = GitHubAnswer.finished(status: 0, output: Data("[]".utf8), error: "")

    var allCalls: [[String]] { lock.withLock { calls } }
    var looks: Int { lock.withLock { calls.filter { $0.first == "run" }.count } }
    var counts: Int { lock.withLock { calls.filter { $0.first == "search" }.count } }
    var mostAtOnce: Int { lock.withLock { mostRunning } }

    var runner: GitHubCLI.Runner { { [self] in await answer($0) } }

    func says(_ answer: GitHubAnswer) { lock.withLock { answers.append(answer) } }
    func says(_ runs: GitHubRun...) { says(Self.success(runs)) }

    /// Calls wait until `letGo`, as `gh` does on a slow network.
    func hold() { lock.withLock { isHolding = true } }

    func letGo() {
        let waiting = lock.withLock {
            isHolding = false
            defer { held = [] }
            return held
        }
        waiting.forEach { $0.resume() }
    }

    private func answer(_ arguments: [String]) async -> GitHubAnswer {
        let holds = lock.withLock {
            calls.append(arguments)
            guard arguments.first == "run" else { return false }
            running += 1
            mostRunning = max(mostRunning, running)
            return isHolding
        }
        if holds { await withCheckedContinuation { continuation in lock.withLock { held.append(continuation) } } }
        return lock.withLock {
            guard arguments.first == "run" else { return reviews }
            running -= 1
            return answers.isEmpty ? standing : answers.removeFirst()
        }
    }

    /// The JSON `gh` prints, keys and all.
    static func success(_ runs: [GitHubRun]) -> GitHubAnswer {
        let fields: [[String: Any]] = runs.map {
            ["databaseId": $0.databaseId, "status": $0.status, "conclusion": $0.conclusion ?? "", "workflowName": $0.workflowName ?? "",
             "displayTitle": $0.displayTitle ?? "", "headSha": $0.headSha, "url": $0.url, "createdAt": $0.createdAt ?? ""]
        }
        return .finished(status: 0, output: (try? JSONSerialization.data(withJSONObject: fields)) ?? Data(), error: "")
    }
}

private let head = "0123456789abcdef0123456789abcdef01234567"
private let older = "fedcba9876543210fedcba9876543210fedcba98"
private let start = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

private func run(_ id: Int = 1, _ workflow: String = "Build", status: String = "in_progress", conclusion: String = "",
                 sha: String = head, url: String? = nil, createdAt: TimeInterval = -600) -> GitHubRun {
    GitHubRun(databaseId: id, status: status, conclusion: conclusion, workflowName: workflow, displayTitle: "Add the thing",
              headSha: sha, url: url ?? "https://github.com/acme/app/actions/runs/\(id)",
              createdAt: ISO8601DateFormatter().string(from: at(createdAt)))
}

private func done(_ id: Int = 1, _ workflow: String = "Build", _ conclusion: String = "success", sha: String = head) -> GitHubRun {
    run(id, workflow, status: "completed", conclusion: conclusion, sha: sha)
}

private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<300 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// Everything touching the settings, in one place, so nothing else can move them mid-test.
@MainActor
@Suite(.serialized)
struct CIMonitorTests {
    private final class Posted {
        var notices: [(notice: LiveNotice, seconds: TimeInterval)] = []
        var last: LiveNotice? { notices.last?.notice }
    }

    private func monitor() -> (CIMonitor, FakeGitHub, Posted, EnergyCoordinator) {
        SnapshotRenderer.useScratchDefaults()
        AppSettings.shared.liveCI = true
        AppSettings.shared.hasAskedForCI = false
        let gh = FakeGitHub(), posted = Posted(), coordinator = EnergyCoordinator()
        return (CIMonitor(runner: gh.runner, post: { posted.notices.append(($0, $1)) }, coordinator: coordinator), gh, posted, coordinator)
    }

    private func request(_ fields: [String: Any]) throws -> SocketRequest {
        var fields = fields
        fields["op"] = "ci"
        return try #require(SocketRequest(line: JSONSerialization.data(withJSONObject: fields)))
    }

    private func watch(_ monitor: CIMonitor, repo: String = "acme/app", branch: String = "main", sha: String? = head,
                       now: Date = start) throws -> [String: Any] {
        var fields: [String: Any] = ["repo": repo, "branch": branch]
        fields["sha"] = sha
        return monitor.apply(try request(fields), now: now)
    }

    private func isOK(_ answer: [String: Any]) -> Bool { answer["ok"] as? Bool == true }

    // MARK: One run

    @Test func aRunGoingShows() async throws {
        let (monitor, gh, _, _) = monitor()
        _ = try watch(monitor)
        gh.says(run(7, "Build", createdAt: -134))
        await monitor.look(now: at(0))
        let shown = try #require(monitor.run)
        #expect(shown.id == 7)
        #expect(shown.repository == "acme/app")
        #expect(shown.branch == "main")
        #expect(shown.workflow == "Build")
        #expect(shown.phase == .running)
        #expect(shown.seconds == 134)
        #expect(shown.url?.absoluteString == "https://github.com/acme/app/actions/runs/7")
    }

    @Test func aQueuedRunSaysSo() async throws {
        let (monitor, gh, _, _) = monitor()
        _ = try watch(monitor)
        gh.says(run(status: "queued"))
        await monitor.look(now: at(0))
        #expect(monitor.run?.phase == .queued)
        #expect(monitor.run?.statusText == "Queued")
    }

    @Test func passingSaysSoAndEnds() async throws {
        let (monitor, gh, posted, _) = monitor()
        _ = try watch(monitor)
        gh.says(run())
        await monitor.look(now: at(0))
        gh.says(done())
        await monitor.look(now: at(15))
        #expect(monitor.run == nil)
        #expect(!monitor.isWatching)
        let (notice, seconds) = try #require(posted.notices.first)
        #expect(posted.notices.count == 1)
        #expect(notice.key == "ci")
        #expect(notice.text == "Passed")
        #expect(notice.detail == "Build · main")
        #expect(notice.tint == .green)
        #expect(notice.timing == .waits)
        #expect(notice.recall == .whole)
        #expect(!notice.fromScript)
        #expect(notice.actions.first?.title == "Open Run")
        #expect(notice.actions.first?.kind == .openURL(URL(string: "https://github.com/acme/app/actions/runs/1")!))
        #expect(seconds == 4)
    }

    @Test func failingSaysSoForLonger() async throws {
        let (monitor, gh, posted, _) = monitor()
        _ = try watch(monitor)
        gh.says(done(1, "Build", "failure"))
        await monitor.look(now: at(0))
        let (notice, seconds) = try #require(posted.notices.first)
        #expect(notice.text == "Failed")
        #expect(notice.tint == .red)
        #expect(!notice.fromScript)
        #expect(seconds > 4)
    }

    @Test func aRunsPhaseFollowsItsStatus() {
        #expect(run(status: "queued").phase == .queued)
        #expect(run(status: "requested").phase == .queued)
        #expect(run(status: "pending").phase == .queued)
        #expect(run(status: "waiting").phase == .waiting)
        #expect(run(status: "in_progress").phase == .running)
    }

    @Test(arguments: [("success", GitHubRun.Verdict.passed), ("failure", .failed), ("timed_out", .failed), ("startup_failure", .failed),
                      ("action_required", .failed), ("cancelled", .cancelled), ("stale", .cancelled), ("skipped", .skipped),
                      ("neutral", .skipped), ("something new", .cancelled)])
    func aConclusionHasAReading(conclusion: String, verdict: GitHubRun.Verdict) {
        #expect(run(status: "completed", conclusion: conclusion).verdict == verdict)
    }

    @Test func aRunNotOverHasNoVerdict() {
        #expect(run().verdict == nil)
        #expect(!run().isOver)
    }

    // MARK: Several runs

    @Test func everyRunForTheCommitCounts() async throws {
        let (monitor, gh, _, _) = monitor()
        _ = try watch(monitor)
        gh.says(run(1, "Build", createdAt: -60), done(2, "Docs", sha: head), run(3, "Lint", status: "queued", createdAt: -30))
        await monitor.look(now: at(0))
        #expect(monitor.run?.total == 3)
        #expect(monitor.run?.finished == 1)
        #expect(monitor.run?.workflow == "Build")
        #expect(monitor.run?.statusText == "1 of 3")
    }

    @Test func oneFailingFailsThePushWithoutWaitingForTheRest() async throws {
        let (monitor, gh, posted, coordinator) = monitor()
        _ = try watch(monitor)
        gh.says(run(1, "Build"), done(2, "Tests", "failure"), done(3, "Docs"))
        await monitor.look(now: at(0))
        #expect(!monitor.isWatching)
        #expect(posted.last?.text == "Failed")
        #expect(posted.last?.detail == "Tests · main")
        #expect(posted.last?.actions.first?.kind == .openURL(URL(string: "https://github.com/acme/app/actions/runs/2")!))
        #expect(!coordinator.scheduled.contains(.ciRun))
    }

    @Test func allSucceedingPasses() async throws {
        let (monitor, gh, posted, _) = monitor()
        _ = try watch(monitor)
        gh.says(done(1, "Build"), done(2, "Docs"))
        await monitor.look(now: at(0))
        #expect(posted.last?.text == "Passed")
        #expect(posted.last?.detail == "Build and Docs · main")
    }

    @Test func threeWorkflowsAreNamedShortly() async throws {
        let (monitor, gh, posted, _) = monitor()
        _ = try watch(monitor)
        gh.says(done(1, "Build"), done(2, "Docs"), done(3, "Lint"))
        await monitor.look(now: at(0))
        #expect(posted.last?.detail == "Build and 2 more · main")
    }

    @Test func aSkippedRunDecidesNothing() async throws {
        let (monitor, gh, posted, _) = monitor()
        _ = try watch(monitor)
        gh.says(done(1, "Build"), done(2, "Deploy", "skipped"), done(3, "Label", "neutral"))
        await monitor.look(now: at(0))
        #expect(posted.last?.text == "Passed")
    }

    @Test func aCancelledRunIsNeitherPassNorFail() async throws {
        let (monitor, gh, posted, _) = monitor()
        _ = try watch(monitor)
        gh.says(done(1, "Build"), done(2, "Docs", "cancelled"))
        await monitor.look(now: at(0))
        #expect(posted.last?.text == "Cancelled")
        #expect(posted.last?.detail == "Docs · main")
        #expect(posted.last?.tint == .gray)
    }

    @Test func aFailureOutweighsACancelledRun() {
        #expect(GitHubRun.verdict(of: [done(1, "A", "cancelled"), done(2, "B", "failure")]) == .failed)
    }

    @Test func nothingButSkippedRunsIsSaidPlainly() async throws {
        let (monitor, gh, posted, _) = monitor()
        _ = try watch(monitor)
        gh.says(done(1, "Build", "skipped"))
        await monitor.look(now: at(0))
        #expect(posted.last?.text == "Skipped")
    }

    @Test func otherCommitsOnTheBranchDontCount() async throws {
        let (monitor, gh, _, _) = monitor()
        _ = try watch(monitor)
        gh.says(run(1, "Build"), done(2, "Build", "failure", sha: older))
        await monitor.look(now: at(0))
        #expect(monitor.isWatching)
        #expect(monitor.run?.total == 1)
    }

    @Test func theStartOfACommitsHashIsEnough() async throws {
        let (monitor, gh, _, _) = monitor()
        _ = try watch(monitor, sha: String(head.prefix(7)).uppercased())
        gh.says(run(1, "Build"))
        await monitor.look(now: at(0))
        #expect(monitor.run != nil)
    }

    @Test func withNoCommitNamedTheNewestRunSettlesIt() async throws {
        let (monitor, gh, _, _) = monitor()
        _ = try watch(monitor, sha: nil)
        gh.says(run(2, "Build", sha: head), done(1, "Build", "failure", sha: older))
        await monitor.look(now: at(0))
        #expect(monitor.run?.id == 2)
        #expect((monitor.statusReport(at: at(0))["watching"] as? [[String: Any]])?.first?["sha"] as? String == head)
    }

    @Test func aRunFinishedMomentsAgoGetsOneMoreLook() async throws {
        let (monitor, gh, posted, _) = monitor()
        _ = try watch(monitor)
        // A quick workflow, with another of the same push not there yet.
        gh.says(run(1, "Docs", status: "completed", conclusion: "success", createdAt: -5))
        await monitor.look(now: at(0))
        #expect(posted.notices.isEmpty)
        #expect(monitor.isWatching)
        gh.says(run(1, "Docs", status: "completed", conclusion: "success", createdAt: -5), run(2, "Tests", createdAt: 10))
        await monitor.look(now: at(15))
        #expect(posted.notices.isEmpty)
        gh.says(run(1, "Docs", status: "completed", conclusion: "success", createdAt: -5),
                run(2, "Tests", status: "completed", conclusion: "failure", createdAt: 10))
        await monitor.look(now: at(30))
        #expect(posted.last?.text == "Failed")
    }

    @Test func oneMoreLookIsAllItGets() async throws {
        let (monitor, gh, posted, _) = monitor()
        _ = try watch(monitor)
        gh.standing = FakeGitHub.success([run(1, "Docs", status: "completed", conclusion: "success", createdAt: -5)])
        await monitor.look(now: at(0))
        // A clock that disagrees with GitHub's can't keep it waiting.
        await monitor.look(now: at(1))
        #expect(posted.last?.text == "Passed")
    }

    // MARK: Runs appearing

    @Test func aRunThatAppearsLateIsPickedUp() async throws {
        let (monitor, gh, posted, _) = monitor()
        _ = try watch(monitor)
        await monitor.look(now: at(0))
        await monitor.look(now: at(15))
        #expect(monitor.run == nil)
        #expect(monitor.isWatching)
        gh.says(run())
        await monitor.look(now: at(30))
        #expect(monitor.run != nil)
        #expect(posted.notices.isEmpty)
    }

    @Test func noRunAppearingEndsItQuietly() async throws {
        let (monitor, _, posted, coordinator) = monitor()
        _ = try watch(monitor)
        #expect(coordinator.scheduled.contains(.ciRun))
        await monitor.look(now: at(CIMonitor.grace - 1))
        #expect(monitor.isWatching)
        await monitor.look(now: at(CIMonitor.grace))
        #expect(!monitor.isWatching)
        #expect(posted.notices.isEmpty)
        #expect(!coordinator.scheduled.contains(.ciRun))
    }

    @Test func aRepositoryWithNoWorkflowsLeavesNoPollRunning() async throws {
        let (monitor, gh, _, coordinator) = monitor()
        _ = try watch(monitor)
        for second in stride(from: 0.0, through: CIMonitor.grace, by: 15) { await monitor.look(now: at(second)) }
        #expect(gh.looks == 9)
        #expect(coordinator.scheduled == [.ciReviews])
    }

    @Test func aRunThatLastsForeverIsLetGo() async throws {
        let (monitor, gh, posted, _) = monitor()
        _ = try watch(monitor)
        gh.standing = FakeGitHub.success([run(1, "Deploy", status: "queued")])
        await monitor.look(now: at(CIMonitor.longestWatch - 1))
        #expect(monitor.isWatching)
        await monitor.look(now: at(CIMonitor.longestWatch))
        #expect(!monitor.isWatching)
        #expect(posted.last?.text == "Still running")
        #expect(posted.last?.actions.count == 1)
    }

    // MARK: When gh can't answer

    @Test func gitHubsNotBeingInstalledIsSaidOnceAndStops() async throws {
        let (monitor, gh, posted, coordinator) = monitor()
        _ = try watch(monitor)
        _ = try watch(monitor, branch: "other")
        gh.standing = .notInstalled
        gh.reviews = .notInstalled
        await monitor.look(now: at(0))
        #expect(posted.notices.count == 1)
        #expect(posted.last?.text == "Needs gh")
        #expect(posted.last?.key == "ci")
        #expect(!monitor.isWatching)
        #expect(!coordinator.scheduled.contains(.ciRun))
    }

    @Test func beingSignedOutIsSaidOnceAndStops() async throws {
        let (monitor, gh, posted, _) = monitor()
        _ = try watch(monitor)
        _ = try watch(monitor, branch: "other")
        gh.standing = .finished(status: 4, output: Data(), error: "To get started with GitHub CLI, please run:  gh auth login\n")
        await monitor.look(now: at(0))
        #expect(posted.notices.count == 1)
        #expect(posted.last?.text == "Signed out")
        #expect(posted.last?.detail == "Run gh auth login to follow CI")
        #expect(!monitor.isWatching)
    }

    @Test func aRepositoryGhCantSeeStopsOnlyThatOne() async throws {
        let (monitor, gh, posted, _) = monitor()
        _ = try watch(monitor)
        _ = try watch(monitor, branch: "other")
        gh.says(.finished(status: 1, output: Data(), error: "failed to get runs: HTTP 404: Not Found (https://api.github.com/repos/acme/app)\n"))
        gh.says(run())
        await monitor.look(now: at(0))
        #expect(posted.notices.count == 1)
        #expect(posted.last?.text == "Not found")
        #expect(posted.last?.detail == "gh can't see acme/app")
        #expect(monitor.isWatching)
    }

    @Test(arguments: [
        (GitHubAnswer.notInstalled, GitHubAnswer.Problem?.some(.notInstalled)),
        (.timedOut, .transient),
        (.finished(status: 0, output: Data(), error: ""), nil),
        (.finished(status: 4, output: Data(), error: ""), .signedOut),
        (.finished(status: 1, output: Data(), error: "HTTP 401: Bad credentials (https://api.github.com/)\nTry authenticating with:  gh auth login\n"), .signedOut),
        (.finished(status: 1, output: Data(), error: "failed to get runs: HTTP 404: Not Found\n"), .notFound),
        (.finished(status: 1, output: Data(), error: "failed to get runs: Get \"https://api.github.com\": dial tcp: lookup api.github.com: no such host\n"), .transient),
        (.finished(status: 1, output: Data(), error: "HTTP 502: Bad Gateway\n"), .transient),
        (.finished(status: 1, output: Data(), error: "HTTP 403: API rate limit exceeded\n"), .transient),
    ])
    func whatGoesWrongIsToldApart(answer: GitHubAnswer, problem: GitHubAnswer.Problem?) {
        #expect(answer.problem == problem)
    }

    @Test func aNetworkErrorIsWaitedOut() async throws {
        let (monitor, gh, posted, _) = monitor()
        _ = try watch(monitor)
        gh.says(run())
        await monitor.look(now: at(0))
        gh.standing = .finished(status: 1, output: Data(), error: "dial tcp: connection refused\n")
        for look in 1..<CIMonitor.mostFailures { await monitor.look(now: at(Double(look) * 15)) }
        // The run stays on show through it, as it was last seen.
        #expect(monitor.run != nil)
        #expect(posted.notices.isEmpty)
        gh.standing = FakeGitHub.success([done()])
        await monitor.look(now: at(600))
        #expect(posted.last?.text == "Passed")
    }

    @Test func aGoodLookStartsThePatienceAgain() async throws {
        let (monitor, gh, posted, _) = monitor()
        _ = try watch(monitor)
        let down = GitHubAnswer.timedOut
        for look in 0..<(CIMonitor.mostFailures - 1) { gh.says(down); await monitor.look(now: at(Double(look))) }
        gh.says(run())
        await monitor.look(now: at(30))
        for look in 0..<(CIMonitor.mostFailures - 1) { gh.says(down); await monitor.look(now: at(40 + Double(look))) }
        #expect(monitor.isWatching)
        #expect(posted.notices.isEmpty)
    }

    @Test func aNetworkThatStaysDownEndsIt() async throws {
        let (monitor, gh, posted, coordinator) = monitor()
        _ = try watch(monitor)
        gh.says(run())
        await monitor.look(now: at(0))
        gh.standing = .timedOut
        for look in 1...CIMonitor.mostFailures { await monitor.look(now: at(Double(look) * 15)) }
        #expect(!monitor.isWatching)
        #expect(posted.notices.count == 1)
        #expect(posted.last?.text == "No answer")
        #expect(posted.last?.actions.first?.title == "Open Run")
        #expect(!coordinator.scheduled.contains(.ciRun))
    }

    @Test func anAnswerThatCantBeReadCountsAsAFailure() async throws {
        let (monitor, gh, posted, _) = monitor()
        _ = try watch(monitor)
        gh.standing = .finished(status: 0, output: Data("not json".utf8), error: "")
        for look in 0..<CIMonitor.mostFailures { await monitor.look(now: at(Double(look))) }
        #expect(!monitor.isWatching)
        #expect(posted.last?.text == "No answer")
    }

    // MARK: Polling

    @Test func thePollRunsOnlyWhileSomethingIsWatched() async throws {
        let (monitor, gh, _, coordinator) = monitor()
        #expect(coordinator.scheduled.isEmpty)
        _ = try watch(monitor)
        #expect(coordinator.scheduled.contains(.ciRun))
        gh.says(done())
        await monitor.look(now: at(0))
        #expect(!coordinator.scheduled.contains(.ciRun))
    }

    @Test func nothingIsLeftWithTheSwitchOff() async throws {
        let (monitor, gh, _, coordinator) = monitor()
        monitor.start(on: SocketRouter())
        _ = try watch(monitor)
        gh.says(run())
        await monitor.look(now: at(0))
        AppSettings.shared.liveCI = false
        defer { AppSettings.shared.liveCI = true }
        #expect(coordinator.scheduled.isEmpty)
        #expect(monitor.run == nil)
        #expect(!monitor.isWatching)
    }

    @Test func twoLooksNeverRunAtOnce() async throws {
        let (monitor, gh, _, _) = monitor()
        _ = try watch(monitor)
        _ = try watch(monitor, branch: "other")
        gh.hold()
        let first = Task { await monitor.look(now: at(0)) }
        await waitUntil { gh.looks == 1 }
        // This one finds a look under way and leaves it.
        await monitor.look(now: at(1))
        gh.letGo()
        await waitUntil { gh.looks == 2 }
        gh.letGo()
        await first.value
        #expect(gh.looks == 2)
        #expect(gh.mostAtOnce == 1)
    }

    @Test func whatGhSaysAboutAWatchThatStoppedIsDropped() async throws {
        let (monitor, gh, posted, _) = monitor()
        _ = try watch(monitor)
        gh.hold()
        gh.says(done())
        let look = Task { await monitor.look(now: at(0)) }
        await waitUntil { gh.looks == 1 }
        _ = monitor.apply(try request(["stop": true]))
        gh.letGo()
        await look.value
        #expect(posted.notices.isEmpty)
        #expect(monitor.run == nil)
    }

    @Test func aPushWhileALookIsUnderWayGetsItsOwnLook() async throws {
        let (monitor, gh, _, _) = monitor()
        _ = try watch(monitor)
        gh.hold()
        gh.says(done(1, "Stale"))
        let look = Task { await monitor.look(now: at(0)) }
        await waitUntil { gh.looks == 1 }
        _ = try watch(monitor, sha: older, now: at(1))
        gh.letGo()
        gh.standing = FakeGitHub.success([run(2, "Build", sha: older)])
        await waitUntil { gh.looks == 2 }
        await look.value
        #expect(monitor.run?.id == 2)
    }

    // MARK: Asking again

    @Test func aNewPushToTheBranchReplacesTheWatch() async throws {
        let (monitor, gh, posted, _) = monitor()
        _ = try watch(monitor, sha: older)
        gh.says(run(1, "Build", sha: older))
        await monitor.look(now: at(0))
        _ = try watch(monitor, sha: head, now: at(5))
        #expect(monitor.run == nil)
        gh.says(run(1, "Build", status: "completed", conclusion: "cancelled", sha: older), run(2, "Build", sha: head))
        await monitor.look(now: at(15))
        #expect(monitor.run?.id == 2)
        #expect(posted.notices.isEmpty)
        #expect((monitor.statusReport(at: at(15))["watching"] as? [[String: Any]])?.count == 1)
    }

    @Test func askingAboutTheSamePushTwiceChangesNothing() async throws {
        let (monitor, gh, _, _) = monitor()
        _ = try watch(monitor)
        gh.says(run())
        await monitor.look(now: at(0))
        let shown = monitor.run
        #expect(shown != nil)
        #expect(isOK(try watch(monitor, now: at(5))))
        #expect(monitor.run == shown)
    }

    @Test func anotherBranchIsAdded() async throws {
        let (monitor, gh, _, _) = monitor()
        _ = try watch(monitor)
        _ = try watch(monitor, repo: "acme/site", branch: "main", sha: older)
        gh.says(run(1, "Build"))
        gh.says(run(2, "Pages", sha: older))
        await monitor.look(now: at(0))
        #expect(monitor.run?.workflow == "Build")
        #expect(monitor.others == 1)
        #expect(gh.looks == 2)
    }

    @Test func theRepositorysCaseDoesntMakeItAnotherOne() throws {
        let (monitor, _, _, _) = monitor()
        _ = try watch(monitor, repo: "acme/app")
        _ = try watch(monitor, repo: "ACME/App", sha: older)
        #expect((monitor.statusReport(at: start)["watching"] as? [[String: Any]])?.count == 1)
    }

    @Test func thereAreOnlySoManyAtOnce() throws {
        let (monitor, _, _, _) = monitor()
        for index in 0..<CIMonitor.mostWatches { #expect(isOK(try watch(monitor, branch: "branch-\(index)"))) }
        let answer = try watch(monitor, branch: "one-too-many")
        #expect(!isOK(answer))
        #expect(answer["error"] as? String == "4 branches are being watched already")
        // One already watched can still move on to a new push.
        #expect(isOK(try watch(monitor, branch: "branch-0", sha: older)))
    }

    @Test func stoppingSaysNothingAndEndsThePoll() async throws {
        let (monitor, gh, posted, coordinator) = monitor()
        _ = try watch(monitor)
        gh.says(run())
        await monitor.look(now: at(0))
        let answer = monitor.apply(try request(["stop": true]))
        #expect(answer["stopped"] as? Int == 1)
        #expect(monitor.run == nil)
        #expect(posted.notices.isEmpty)
        #expect(!coordinator.scheduled.contains(.ciRun))
    }

    @Test func stoppingCanBeNarrowed() throws {
        let (monitor, _, _, _) = monitor()
        _ = try watch(monitor, branch: "one")
        _ = try watch(monitor, branch: "two")
        #expect(monitor.apply(try request(["stop": true, "branch": "one"]))["stopped"] as? Int == 1)
        #expect(monitor.apply(try request(["stop": true, "repo": "other/repo"]))["stopped"] as? Int == 0)
        #expect(monitor.isWatching)
    }

    // MARK: What a request can name

    @Test(arguments: ["", "acme", "acme/", "/app", "acme/app/extra", "-acme/app", "acme/-app", "../..", "./app", "acme/..",
                      "acme/app\n", "ac me/app", "acme/a;b", "acme/$(reboot)", "acme/a`b`", "acme/ａｐｐ", "acme/a|b",
                      String(repeating: "a", count: 200) + "/app"])
    func aRepositoryThatIsntOneIsRefused(repository: String) throws {
        let (monitor, gh, _, coordinator) = monitor()
        let answer = try watch(monitor, repo: repository)
        #expect(!isOK(answer))
        #expect(!monitor.isWatching)
        #expect(!AppSettings.shared.hasAskedForCI)
        #expect(coordinator.scheduled.isEmpty)
        #expect(gh.allCalls.isEmpty)
    }

    @Test(arguments: ["acme/app", "ACME-co/app.js", "a_b/c-d.e", "ALIRAZA47/dynotch"])
    func aRepositoryIsTaken(repository: String) {
        #expect(CIMonitor.isRepository(repository))
    }

    @Test(arguments: ["", "-delete", "--repo", "a b", "a\nb", "a\u{0}b", "a\tb", "a\u{1B}[0m", "a..b", "a~1", "a^b", "a:b", "a?b", "a*b",
                      "a[b", "a\\b", "/a", "a/", "a//b", "a.", "a.lock", "a@{b", String(repeating: "a", count: 256)])
    func aBranchThatIsntOneIsRefused(branch: String) throws {
        let (monitor, _, _, _) = monitor()
        #expect(!isOK(try watch(monitor, branch: branch)))
        #expect(!monitor.isWatching)
    }

    @Test(arguments: ["main", "fix/login-redirect", "release-1.2", "feature/ünï", "a@b", "UPPER_case"])
    func aBranchIsTaken(branch: String) {
        #expect(CIMonitor.isBranch(branch))
    }

    @Test(arguments: ["", "abc", "not-hex", "0123456789abcdeg", "0123456 ", "0123456\n", "-123456", "１２３４５６７",
                      String(repeating: "a", count: 65)])
    func aCommitThatIsntOneIsRefused(sha: String) throws {
        let (monitor, _, _, _) = monitor()
        #expect(!isOK(try watch(monitor, sha: sha)))
        #expect(!monitor.isWatching)
    }

    @Test(arguments: ["0123456", head, head.uppercased(), String(repeating: "a", count: 64)])
    func aCommitIsTaken(sha: String) {
        #expect(CIMonitor.isCommit(sha))
    }

    @Test func fieldsOfTheWrongTypeAreRefused() throws {
        let (monitor, _, _, _) = monitor()
        #expect(!isOK(monitor.apply(try request(["repo": 7, "branch": "main"]))))
        #expect(!isOK(monitor.apply(try request(["repo": "acme/app", "branch": ["main"]]))))
        #expect(!isOK(monitor.apply(try request([:]))))
    }

    @Test func aRequestCantAddToWhatsRun() async throws {
        let (monitor, gh, _, _) = monitor()
        let answer = monitor.apply(try request(["repo": "acme/app", "branch": "main", "gh": "/tmp/evil", "path": "/tmp",
                                                "PATH": "/tmp", "arguments": ["pr", "create"]]))
        #expect(isOK(answer))
        await monitor.look(now: at(0))
        #expect(gh.looks == 1)
        #expect(gh.allCalls.allSatisfy { $0 == GitHubCLI.listArguments(repository: "acme/app", branch: "main") || $0 == GitHubCLI.reviewArguments })
    }

    @Test func noCallCanChangeAnythingOnGitHub() {
        let list = GitHubCLI.listArguments(repository: "acme/app", branch: "main")
        #expect(list == ["run", "list", "--repo", "acme/app", "--branch", "main", "--limit", "10", "--json",
                         "databaseId,status,conclusion,workflowName,displayTitle,headSha,url,createdAt"])
        #expect(GitHubCLI.reviewArguments == ["search", "prs", "--review-requested=@me", "--state=open", "--json", "number", "--limit", "100"])
    }

    // MARK: Links

    @Test(arguments: ["https://github.com/acme/app/actions/runs/1", "HTTPS://GitHub.com/acme/app"])
    func aLinkToGitHubIsTaken(link: String) {
        #expect(CIMonitor.checkedURL(link) != nil)
    }

    @Test(arguments: ["http://github.com/acme/app", "https://github.com.evil.example/a", "https://evil.example/github.com",
                      "https://github.com@evil.example/", "https://user:pass@github.com/", "https://github.com:8443/a",
                      "https://gist.github.com/a", "file:///etc/passwd", "javascript:alert(1)", "dynotch://close", "", "not a url"])
    func anyOtherLinkIsRefused(link: String) {
        #expect(CIMonitor.checkedURL(link) == nil)
    }

    @Test func aLinkThatFailsTheCheckLeavesTheButtonOut() async throws {
        let (monitor, gh, posted, _) = monitor()
        _ = try watch(monitor)
        let bad = "https://evil.example/runs/1"
        gh.says(run(1, url: bad))
        await monitor.look(now: at(0))
        #expect(monitor.run != nil)
        #expect(monitor.run?.url == nil)
        #expect(monitor.run?.openAction == nil)
        gh.says(run(1, status: "completed", conclusion: "success", url: bad))
        await monitor.look(now: at(15))
        #expect(posted.last?.text == "Passed")
        #expect(posted.last?.actions.isEmpty == true)
    }

    // MARK: Reviews

    private func reviews(_ count: Int) -> GitHubAnswer {
        let list = (0..<count).map { ["number": $0] }
        return .finished(status: 0, output: (try? JSONSerialization.data(withJSONObject: list)) ?? Data(), error: "")
    }

    @Test func noReviewsAreCountedForSomeoneWhoNeverAsked() async {
        let (monitor, gh, _, coordinator) = monitor()
        monitor.start(on: SocketRouter())
        await monitor.countReviews()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(gh.allCalls.isEmpty)
        #expect(coordinator.scheduled.isEmpty)
    }

    @Test func askingOnceStartsTheCountAndIsRemembered() async throws {
        let (monitor, gh, _, coordinator) = monitor()
        monitor.start(on: SocketRouter())
        gh.reviews = reviews(3)
        _ = try watch(monitor)
        #expect(AppSettings.shared.hasAskedForCI)
        #expect(UserDefaults.dynotch.bool(forKey: "hasAskedForCI"))
        #expect(coordinator.scheduled.contains(.ciReviews))
        await waitUntil { monitor.reviewCount == 3 }
        #expect(monitor.reviewCount == 3)
        #expect(gh.counts == 1)
    }

    @Test func theCountGoesOnAfterARestart() async {
        let (monitor, gh, _, coordinator) = monitor()
        AppSettings.shared.hasAskedForCI = true
        gh.reviews = reviews(2)
        monitor.start(on: SocketRouter())
        #expect(coordinator.scheduled == [.ciReviews])
        await waitUntil { monitor.reviewCount == 2 }
        #expect(monitor.reviewCount == 2)
    }

    @Test func stoppingDoesntCountAsAsking() throws {
        let (monitor, _, _, _) = monitor()
        _ = monitor.apply(try request(["stop": true]))
        #expect(!AppSettings.shared.hasAskedForCI)
    }

    @Test func withTheSwitchOffNothingCallsGitHub() async throws {
        let (monitor, gh, _, coordinator) = monitor()
        AppSettings.shared.hasAskedForCI = true
        AppSettings.shared.liveCI = false
        defer { AppSettings.shared.liveCI = true }
        monitor.start(on: SocketRouter())
        let answer = try watch(monitor)
        #expect(!isOK(answer))
        #expect(answer["error"] as? String == "CI runs are switched off in Settings")
        await monitor.countReviews()
        await monitor.look(now: at(0))
        #expect(gh.allCalls.isEmpty)
        #expect(coordinator.scheduled.isEmpty)
    }

    @Test func aRequestRefusedWithTheSwitchOffDoesntCountAsAsking() throws {
        let (monitor, _, _, _) = monitor()
        AppSettings.shared.liveCI = false
        defer { AppSettings.shared.liveCI = true }
        _ = try watch(monitor)
        #expect(!AppSettings.shared.hasAskedForCI)
    }

    @Test func theSwitchTakesTheCountAwayAndBringsItBack() async {
        let (monitor, gh, _, coordinator) = monitor()
        AppSettings.shared.hasAskedForCI = true
        gh.reviews = reviews(3)
        monitor.start(on: SocketRouter())
        await waitUntil { monitor.reviewCount == 3 }
        AppSettings.shared.liveCI = false
        #expect(monitor.reviewCount == 0)
        #expect(coordinator.scheduled.isEmpty)
        AppSettings.shared.liveCI = true
        #expect(coordinator.scheduled == [.ciReviews])
        await waitUntil { monitor.reviewCount == 3 }
        #expect(monitor.reviewCount == 3)
    }

    @Test func aPassingFailureLeavesTheCountAlone() async {
        let (monitor, gh, _, _) = monitor()
        AppSettings.shared.hasAskedForCI = true
        gh.reviews = reviews(3)
        await monitor.countReviews()
        #expect(monitor.reviewCount == 3)
        gh.reviews = .timedOut
        await monitor.countReviews()
        #expect(monitor.reviewCount == 3)
    }

    @Test func beingSignedOutClearsTheCountWithoutANotice() async {
        let (monitor, gh, posted, _) = monitor()
        AppSettings.shared.hasAskedForCI = true
        gh.reviews = reviews(3)
        await monitor.countReviews()
        gh.reviews = .finished(status: 4, output: Data(), error: "gh auth login")
        await monitor.countReviews()
        #expect(monitor.reviewCount == 0)
        #expect(posted.notices.isEmpty)
    }

    @Test func reviewsReadInWords() {
        #expect(CIMonitor.reviewsText(1) == "1 review")
        #expect(CIMonitor.reviewsText(3) == "3 reviews")
    }

    // MARK: Status

    @Test func statusReportsWhatsWatched() async throws {
        let (monitor, gh, _, _) = monitor()
        gh.reviews = reviews(0)
        _ = try watch(monitor)
        gh.says(run(1, "Build"), done(2, "Docs"))
        await monitor.look(now: at(40))
        let report = monitor.statusReport(at: at(40))
        let watching = try #require(report["watching"] as? [[String: Any]])
        #expect(watching.count == 1)
        #expect(watching[0]["repository"] as? String == "acme/app")
        #expect(watching[0]["branch"] as? String == "main")
        #expect(watching[0]["sha"] as? String == head)
        #expect(watching[0]["workflow"] as? String == "Build")
        #expect(watching[0]["runs"] as? Int == 2)
        #expect(watching[0]["finished"] as? Int == 1)
        #expect(watching[0]["secondsWatching"] as? Int == 40)
        #expect(JSONSerialization.isValidJSONObject(report))
    }

    @Test func aWatchWithNothingYetIsValidJSON() throws {
        let (monitor, _, _, _) = monitor()
        _ = try watch(monitor, sha: nil)
        let report = monitor.statusReport(at: start)
        #expect(JSONSerialization.isValidJSONObject(report))
        #expect((report["watching"] as? [[String: Any]])?.first?["workflow"] is NSNull)
    }

    @Test func statusForReadingSaysWhatsWatched() {
        let summary = CommandLineClient.summary(of: [
            "version": "1.6", "ci": ["reviews": 3, "watching": [["repository": "acme/app", "branch": "main", "workflow": "Build"],
                                                                ["repository": "acme/site", "branch": "dev", "workflow": NSNull()]]],
        ])
        #expect(summary == "Dynotch 1.6\nCI: acme/app on main · Build\nCI: acme/site on dev\nReviews waiting: 3\n")
    }

    @Test func theSocketReachesIt() throws {
        let (monitor, gh, _, _) = monitor()
        let router = SocketRouter()
        monitor.start(on: router)
        #expect(router.ops == ["ci"])
        #expect(router.status["ci"] != nil)
        #expect(gh.allCalls.isEmpty)
    }

    // MARK: The notch

    @Test func aRunTakesTheNotchWhenNothingElseIsOn() {
        SnapshotRenderer.useScratchDefaults()
        AppSettings.shared.liveCI = true
        let shown = CIRun(id: 1, repository: "acme/app", branch: "main", workflow: "Build")
        CIMonitor.shared.loadSample(shown)
        defer {
            CIMonitor.shared.clearSample()
            LiveActivityCenter.shared.dismissNotice()
        }
        // Works out what the closed notch shows, with nothing to dismiss.
        LiveActivityCenter.shared.dismissNotice()
        #expect(LiveActivityCenter.shared.content.activity == .ci(shown))
        AppSettings.shared.liveCI = false
        LiveActivityCenter.shared.dismissNotice()
        #expect(LiveActivityCenter.shared.content.activity == .idle)
        AppSettings.shared.liveCI = true
    }
}

/// Those that don't touch the settings.
struct CIRunTextTests {
    @Test func theRightEarSaysHowItsGoing() {
        func text(_ phase: CIRun.Phase = .running, seconds: Int = 0, total: Int = 1, finished: Int = 0) -> String {
            CIRun(id: 1, repository: "a/b", branch: "main", workflow: "CI", phase: phase, seconds: seconds, total: total, finished: finished).statusText
        }
        #expect(text(.queued, seconds: 300) == "Queued")
        #expect(text(.waiting) == "Waiting")
        #expect(text(seconds: 40) == "Running")
        #expect(text(seconds: 134) == "2m")
        #expect(text(seconds: 134, total: 3, finished: 1) == "1 of 3")
    }

    @Test func timeIsShort() {
        func text(_ seconds: Int) -> String {
            CIRun(id: 1, repository: "a/b", branch: "main", workflow: "CI", seconds: seconds).elapsedText
        }
        #expect(text(40) == "40s")
        #expect(text(60) == "1m")
        #expect(text(3599) == "59m")
        #expect(text(3600) == "1h")
        #expect(text(3900) == "1h 5m")
    }

    @Test func theGlancesLineSaysWhereHowLongAndHowMany() {
        var shown = CIRun(id: 1, repository: "a/b", branch: "main", workflow: "CI", seconds: 134)
        #expect(shown.summary == "main · 2m · 1 run")
        shown.total = 3
        #expect(shown.summary == "main · 2m · 3 runs")
    }

    @Test func theSampleInSettingsKeepsCompiling() {
        let sample = CIRun(id: 1, repository: "acme/app", branch: "main", workflow: "Build", url: URL(string: "https://github.com")!)
        #expect(sample.total == 1)
    }

    @Test @MainActor func aRunsGlanceIsItsOwn() {
        let shown = CIRun(id: 1, repository: "a/b", branch: "main", workflow: "CI")
        #expect(GlanceContent(activity: .ci(shown)) == .ci(shown))
        #expect(ClosedActivity.ci(shown).statusName == "ci")
    }

    @Test func aRunsNameIsCleanedForOneLine() async {
        let dirty = GitHubRun(databaseId: 1, status: "queued", workflowName: " Build\n\u{1B}[31m ", headSha: head, url: "")
        #expect(await dirty.name == "Build[31m")
        let nameless = GitHubRun(databaseId: 1, status: "queued", workflowName: "", displayTitle: "Add the thing", headSha: head, url: "")
        #expect(await nameless.name == "Add the thing")
        let nothing = GitHubRun(databaseId: 1, status: "queued", headSha: head, url: "")
        #expect(await nothing.name == "Workflow")
    }
}

struct GitHubRunParsingTests {
    /// As `gh run list --json` prints it, with made-up values.
    private static let printed = """
    [{"conclusion":"","createdAt":"2026-10-31T13:04:12Z","databaseId":41000000001,"displayTitle":"Add the thing (#7)",\
    "headSha":"0123456789abcdef0123456789abcdef01234567","status":"in_progress",\
    "url":"https://github.com/acme/app/actions/runs/41000000001","workflowName":"Build"},\
    {"conclusion":"success","createdAt":"2026-10-31T13:04:10Z","databaseId":41000000002,"displayTitle":"Add the thing (#7)",\
    "headSha":"0123456789abcdef0123456789abcdef01234567","status":"completed",\
    "url":"https://github.com/acme/app/actions/runs/41000000002","workflowName":"Docs"}]
    """

    @Test func whatGhPrintsIsRead() throws {
        let runs = try #require(GitHubRun.list(from: Data(Self.printed.utf8)))
        #expect(runs.count == 2)
        #expect(runs[0].databaseId == 41_000_000_001)
        #expect(runs[0].status == "in_progress")
        #expect(runs[0].conclusion == "")
        #expect(!runs[0].isOver)
        #expect(runs[0].workflowName == "Build")
        #expect(runs[0].displayTitle == "Add the thing (#7)")
        #expect(runs[0].headSha == "0123456789abcdef0123456789abcdef01234567")
        #expect(runs[0].created == ISO8601DateFormatter().date(from: "2026-10-31T13:04:12Z"))
        #expect(runs[1].isOver)
        #expect(runs[1].verdict == .passed)
    }

    @Test func noRunsIsAnAnswer() {
        #expect(GitHubRun.list(from: Data("[]".utf8)) == [])
    }

    @Test func aNullConclusionIsFine() throws {
        let line = #"[{"databaseId":1,"status":"queued","conclusion":null,"headSha":"abc","url":"https://github.com"}]"#
        #expect(try #require(GitHubRun.list(from: Data(line.utf8))).first?.conclusion == nil)
    }

    @Test(arguments: ["", "not json", "{}", #"[{"status":"queued"}]"#])
    func anythingElseIsNot(text: String) {
        #expect(GitHubRun.list(from: Data(text.utf8)) == nil)
    }

    @Test func aDateItCantReadLeavesTheRunReadable() {
        let parsed = GitHubRun(databaseId: 1, status: "queued", headSha: "a", url: "", createdAt: "yesterday")
        #expect(parsed.created == nil)
    }
}

/// The real way of running a program, on harmless programs. Never `gh`.
struct GitHubCLITests {
    private final class Scratch {
        let folder = NSTemporaryDirectory() + "dyn-gh-" + UUID().uuidString.prefix(8)
        init() { try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(atPath: folder) }

        func program(_ name: String, mode: mode_t = 0o755) -> String {
            let path = folder + "/" + name
            FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8))
            chmod(path, mode)
            return path
        }
    }

    @Test func thePlacesAreAFixedListOfAbsolutePaths() {
        #expect(GitHubCLI.places.contains("/opt/homebrew/bin/gh"))
        #expect(GitHubCLI.places.contains("/usr/local/bin/gh"))
        #expect(GitHubCLI.places.allSatisfy { $0.hasPrefix("/") && $0.hasSuffix("/gh") })
    }

    @Test func theFirstPlaceWithAProgramWins() {
        let scratch = Scratch()
        let second = scratch.program("second"), third = scratch.program("third")
        #expect(GitHubCLI.find(in: [scratch.folder + "/missing", second, third]) == second)
    }

    @Test func somethingElseIsntFoundThere() {
        let scratch = Scratch()
        #expect(GitHubCLI.find(in: [scratch.folder + "/missing"]) == nil)
        #expect(GitHubCLI.find(in: [scratch.folder]) == nil)
        #expect(GitHubCLI.find(in: [scratch.program("plain", mode: 0o644)]) == nil)
    }

    @Test(arguments: [mode_t(0o777), 0o775, 0o757])
    func aProgramOthersCanChangeIsntTrusted(mode: mode_t) {
        let scratch = Scratch()
        #expect(GitHubCLI.find(in: [scratch.program("open", mode: mode)]) == nil)
    }

    @Test func aProgramInItsPlaceRuns() async {
        let answer = await GitHubCLI.run("/bin/echo", ["hello"])
        #expect(answer == .finished(status: 0, output: Data("hello\n".utf8), error: ""))
    }

    @Test func itsEnvironmentIsSmallAndFixed() async throws {
        let answer = await GitHubCLI.run("/usr/bin/env", [])
        let lines = String(decoding: try #require(answer.output), as: UTF8.self).split(separator: "\n").map(String.init).sorted()
        #expect(lines == ["HOME=\(NSHomeDirectory())", "PATH=/usr/bin:/bin:/usr/sbin:/sbin"])
    }

    @Test func argumentsReachItAsTheyAreWithNoShell() async throws {
        let argument = "$(id); `id` | a && b"
        let answer = await GitHubCLI.run("/bin/echo", [argument])
        let output = try #require(answer.output)
        #expect(String(decoding: output, as: UTF8.self) == argument + "\n")
    }

    @Test func whatItSaysOnFailureComesBack() async {
        let answer = await GitHubCLI.run("/bin/sh", ["-c", "echo no >&2; exit 4"])
        #expect(answer == .finished(status: 4, output: Data(), error: "no\n"))
        #expect(answer.problem == .signedOut)
    }

    @Test func oneThatRunsTooLongIsStopped() async {
        let started = Date.now
        let answer = await GitHubCLI.run("/bin/sleep", ["30"], timeout: 0.2)
        #expect(answer == .timedOut)
        // Well under the 30 seconds it asked for, with room for others ahead of it in the queue.
        #expect(Date.now.timeIntervalSince(started) < 15)
    }

    @Test func oneThatIgnoresBeingStoppedIsStoppedAnyway() async {
        let started = Date.now
        let answer = await GitHubCLI.run("/bin/sh", ["-c", "trap '' TERM; while :; do /bin/sleep 1; done"], timeout: 0.2)
        #expect(answer == .timedOut)
        #expect(Date.now.timeIntervalSince(started) < 15)
    }

    @Test func aLongAnswerDoesntStallIt() async throws {
        let answer = await GitHubCLI.run("/bin/sh", ["-c", "/usr/bin/yes hello | /usr/bin/head -c 300000"])
        #expect(try #require(answer.output).count == 300_000)
    }

    @Test func onlyOneRunsAtATime() async {
        let scratch = Scratch()
        let lock = scratch.folder + "/lock"
        // Fails if it finds the other one still running.
        let script = "/bin/mkdir '\(lock)' || exit 9; /bin/sleep 0.2; /bin/rmdir '\(lock)'"
        async let first = GitHubCLI.run("/bin/sh", ["-c", script])
        async let second = GitHubCLI.run("/bin/sh", ["-c", script])
        #expect(await [first, second].map(\.problem) == [nil, nil])
    }

    @Test func aProgramThatWontStartIsWorthAnotherTry() async {
        // Only `find` says it's not installed, so a hiccup can't tell someone to install it.
        #expect(await GitHubCLI.run("/nonexistent/gh", []).problem == .transient)
    }
}
