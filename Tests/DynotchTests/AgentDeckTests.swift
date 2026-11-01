import Darwin
import Foundation
import SwiftUI
import Testing
@testable import Dynotch
@testable import DynotchCommand
import DynotchShared

/// A socket path of its own, never the real one.
private struct Scratch {
    let folder = NSTemporaryDirectory() + "dyn-" + UUID().uuidString.prefix(8)
    var path: String { folder + "/run/s.sock" }
}

/// What a hook heard back.
private final class Answers {
    var all: [[String: Any]] = []
    var decisions: [String] { all.compactMap { $0["decision"] as? String } }
    func add(_ answer: [String: Any]) { all.append(answer) }
}

private final class Posted {
    var notices: [(notice: LiveNotice, seconds: TimeInterval)] = []
}

private func waitUntil(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<500 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// The real `scripts/dynotch hook` and the real binary, with a hook's JSON on its stdin.
private final class HookProcess {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let binary = root.appendingPathComponent(".build/debug/DynotchCommand").path
    static var hasBinary: Bool { FileManager.default.isExecutableFile(atPath: binary) }

    private let process = Process()
    private let output = Pipe()

    init(input: Data, socket: String) throws {
        process.executableURL = Self.root.appendingPathComponent("scripts/dynotch")
        process.arguments = ["hook"]
        process.environment = ["DYNOTCH_BIN": Self.binary, "DYNOTCH_SOCKET": socket, "PATH": "/usr/bin:/bin", "TERM_PROGRAM": "ghostty"]
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(input)
        try stdin.fileHandleForWriting.close()
    }

    var isRunning: Bool { process.isRunning }

    /// How Claude Code stops a hook when its session ends.
    func terminate() {
        process.terminate()
    }

    /// Waits for it to end, and says how it did.
    func finish() async -> (code: Int32, reason: Process.TerminationReason, output: String) {
        await waitUntil { !self.process.isRunning }
        // One that's still going would never reach the end of its output.
        if process.isRunning {
            Issue.record("The hook is still running")
            process.terminate()
            process.waitUntilExit()
        }
        let data = output.fileHandleForReading.availableData
        return (process.terminationStatus, process.terminationReason, String(decoding: data, as: UTF8.self))
    }
}

@MainActor
@Suite(.serialized)
struct AgentDeckTests {
    private let start = Date.now
    private let answers = Answers()

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func deck() -> (AgentDeck, Posted) {
        SnapshotRenderer.useScratchDefaults()
        AppSettings.shared.liveAgents = true
        let posted = Posted()
        return (AgentDeck(post: { posted.notices.append(($0, $1)) }), posted)
    }

    /// Goes through what `dynotch hook` sends, so nothing here sees what the real deck wouldn't.
    private func request(_ event: String, _ changes: [String: Any] = [:], session: String = HookPayloads.session) throws -> SocketRequest {
        let payload = HookPayloads.payload(event, changes.merging(["session_id": session]) { first, _ in first })
        let fields = AgentHook.request(from: payload, environment: ["TERM_PROGRAM": "ghostty"])
        return try #require(SocketRequest(line: JSONSerialization.data(withJSONObject: fields)))
    }

    @discardableResult
    private func send(_ deck: AgentDeck, _ event: String, _ changes: [String: Any] = [:], session: String = HookPayloads.session,
                      after seconds: TimeInterval = 0) throws -> UUID? {
        let answers = answers
        return deck.apply(try request(event, changes, session: session), now: at(seconds)) { answers.add($0) }
    }

    private func bash(_ command: String, id: String = "toolu_1") -> [String: Any] {
        ["tool_name": "Bash", "tool_input": ["command": command], "tool_use_id": id]
    }

    /// A guard for `approval` that's been on screen for a while.
    private func armed(for approval: AgentApproval?) -> ApprovalGuard {
        var shown = ApprovalGuard()
        shown.show(approval?.id, at: at(-60))
        return shown
    }

    private func state(_ deck: AgentDeck) -> AgentSession.State? { deck.sessions.first?.state }

    // MARK: States

    @Test func aStartedSessionIsReadyAndNamedAfterItsFolder() throws {
        let (deck, _) = deck()
        try send(deck, "SessionStart")
        #expect(deck.sessions.map(\.project) == ["lantern"])
        #expect(state(deck) == .ready)
        #expect(deck.hasSessions)
        #expect(answers.all.count == 1)
        #expect(answers.decisions.isEmpty)
    }

    @Test func aSessionWithoutAFolderStillHasAName() {
        #expect(AgentDeck.project(of: nil) == "Claude Code")
        #expect(AgentDeck.project(of: "") == "Claude Code")
        #expect(AgentDeck.project(of: "/") != "")
    }

    @Test func aFolderNameCantCarryAnOverride() {
        #expect(AgentDeck.project(of: "/work/evil\u{202E}name") == "evil<U+202E>name")
    }

    @Test func thePromptStartsItWorking() throws {
        let (deck, _) = deck()
        try send(deck, "SessionStart")
        try send(deck, "UserPromptSubmit")
        #expect(state(deck) == .working(nil))
    }

    @Test func aToolSaysWhatItsDoingWithoutItsArguments() throws {
        let (deck, _) = deck()
        try send(deck, "UserPromptSubmit")
        try send(deck, "PreToolUse", bash("TOKEN=hunter2 swift build --flag hunter2"))
        #expect(state(deck) == .working("Running swift build"))
    }

    @Test func itsLineSaysHowLong() throws {
        let (deck, _) = deck()
        try send(deck, "UserPromptSubmit")
        try send(deck, "PreToolUse", bash("swift build"))
        let session = try #require(deck.sessions.first)
        #expect(session.line(at: at(30)) == "Running swift build")
        #expect(session.line(at: at(4 * 60 + 5)) == "Running swift build · 4 min")
        #expect(session.line(at: at(2 * 3600)) == "Running swift build · 2 hr")
    }

    @Test func aFinishedToolGoesBackToWorking() throws {
        let (deck, _) = deck()
        try send(deck, "UserPromptSubmit")
        try send(deck, "PreToolUse", bash("swift build"))
        try send(deck, "PostToolUse", bash("swift build"))
        #expect(state(deck) == .working(nil))
    }

    @Test func aParallelToolFinishingLeavesTheNewerOneShowing() throws {
        let (deck, _) = deck()
        try send(deck, "UserPromptSubmit")
        try send(deck, "PreToolUse", bash("swift build", id: "toolu_1"))
        try send(deck, "PreToolUse", bash("swift test", id: "toolu_2"))
        try send(deck, "PostToolUse", bash("swift build", id: "toolu_1"))
        #expect(state(deck) == .working("Running swift test"))
    }

    @Test func aPermissionRequestMakesItWait() throws {
        let (deck, _) = deck()
        try send(deck, "UserPromptSubmit")
        try send(deck, "PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "npm run screens -- --token hunter2"]])
        #expect(state(deck) == .waiting("Wants to run: npm run screens"))
        #expect(deck.approvals.count == 1)
        #expect(deck.waitingCount == 1)
    }

    @Test func aStopFinishesItAndSaysWhen() throws {
        let (deck, _) = deck()
        try send(deck, "UserPromptSubmit")
        try send(deck, "Stop", after: 90)
        #expect(state(deck) == .done(at(90)))
        let session = try #require(deck.sessions.first)
        #expect(session.line(at: at(100)) == "Done just now")
        #expect(session.line(at: at(90 + 120)) == "Done 2 min ago")
    }

    @Test func aSessionEndRemovesIt() throws {
        let (deck, _) = deck()
        try send(deck, "SessionStart")
        try send(deck, "SessionEnd")
        #expect(deck.sessions.isEmpty)
        #expect(!deck.hasSessions)
    }

    @Test func compactingLeavesAWorkingSessionAlone() throws {
        let (deck, _) = deck()
        try send(deck, "UserPromptSubmit")
        try send(deck, "SessionStart", ["source": "compact"])
        #expect(state(deck) == .working(nil))
    }

    @Test func aSessionFirstHeardOfMidTurnIsWorking() throws {
        let (deck, _) = deck()
        try send(deck, "PostToolUse", bash("ls"))
        #expect(state(deck) == .working(nil))
    }

    @Test func aSessionFirstHeardOfAtItsStopIsDone() throws {
        let (deck, _) = deck()
        try send(deck, "Stop")
        #expect(state(deck) == .done(at(0)))
    }

    @Test func eachSessionHasItsOwnRow() throws {
        let (deck, _) = deck()
        try send(deck, "UserPromptSubmit", session: "one")
        try send(deck, "Stop", session: "two")
        #expect(deck.sessions.map(\.id) == ["one", "two"])
    }

    @Test func theProjectIsKeptThroughACd() throws {
        let (deck, _) = deck()
        try send(deck, "SessionStart")
        try send(deck, "PreToolUse", bash("ls").merging(["cwd": "/elsewhere/deep"]) { $1 })
        #expect(deck.sessions.map(\.project) == ["lantern"])
    }

    @Test func itKeepsWhereItCameFrom() throws {
        let (deck, _) = deck()
        try send(deck, "SessionStart")
        #expect(deck.sessions.first?.origin.program == "ghostty")
    }

    @Test func aRequestWithoutASessionIsAnsweredAndForgotten() throws {
        let (deck, _) = deck()
        let line = try JSONSerialization.data(withJSONObject: ["op": "hook", "hook_event_name": "PermissionRequest"])
        let held = deck.apply(try #require(SocketRequest(line: line)), now: at(0)) { self.answers.add($0) }
        #expect(held == nil)
        #expect(deck.approvals.isEmpty)
        #expect(answers.all.count == 1)
    }

    @Test func anEventItDoesntKnowChangesNothing() throws {
        let (deck, _) = deck()
        try send(deck, "UserPromptSubmit")
        try send(deck, "SessionStart", ["hook_event_name": "SomethingNew"])
        #expect(state(deck) == .working(nil))
    }

    // MARK: Out of order

    @Test func aLatePostToolUseDoesntUndoAStop() throws {
        let (deck, _) = deck()
        try send(deck, "UserPromptSubmit")
        try send(deck, "Stop")
        try send(deck, "PostToolUse", bash("ls"), after: 1)
        #expect(state(deck) == .done(at(0)))
    }

    @Test func aPreToolUseAfterItsPostToolUseIsIgnored() throws {
        let (deck, _) = deck()
        try send(deck, "UserPromptSubmit")
        try send(deck, "PostToolUse", bash("ls"))
        try send(deck, "PreToolUse", bash("ls"))
        #expect(state(deck) == .working(nil))
    }

    @Test func aLatePreToolUseDoesntStopItWaiting() throws {
        let (deck, _) = deck()
        try send(deck, "UserPromptSubmit")
        let approval = bash("swift build")
        try send(deck, "PermissionRequest", approval)
        try send(deck, "PreToolUse", approval)
        #expect(state(deck) == .waiting("Wants to run: swift build"))
        #expect(deck.approvals.count == 1)
    }

    @Test func whatASessionSaysAfterItEndedDoesntBringItBack() throws {
        let (deck, _) = deck()
        try send(deck, "UserPromptSubmit")
        try send(deck, "SessionEnd")
        try send(deck, "Stop", after: 1)
        try send(deck, "PostToolUse", bash("ls"), after: 1)
        #expect(deck.sessions.isEmpty)
    }

    @Test func aResumedSessionComesBack() throws {
        let (deck, _) = deck()
        try send(deck, "SessionEnd")
        try send(deck, "SessionStart", ["source": "resume"], after: 1)
        #expect(deck.sessions.count == 1)
    }

    @Test func aNewPromptBringsItBackToo() throws {
        let (deck, _) = deck()
        try send(deck, "SessionEnd")
        try send(deck, "UserPromptSubmit", after: 1)
        #expect(state(deck) == .working(nil))
    }

    // MARK: Waiting without an approval

    @Test func aPermissionPromptShowsWaitingForASessionWhoseRequestDidntArrive() throws {
        let (deck, posted) = deck()
        try send(deck, "UserPromptSubmit")
        try send(deck, "Notification")
        #expect(state(deck) == .waiting("Needs your permission"))
        #expect(deck.approvals.isEmpty)
        #expect(deck.waitingCount == 1)
        #expect(posted.notices.count == 1)
    }

    @Test func aPermissionPromptAddsNothingToAnApproval() throws {
        let (deck, posted) = deck()
        try send(deck, "PermissionRequest", bash("swift build"))
        try send(deck, "Notification", after: 6)
        #expect(state(deck) == .waiting("Wants to run: swift build"))
        #expect(deck.waitingCount == 1)
        #expect(posted.notices.count == 1)
    }

    @Test func aPermissionPromptOnlySaysSoOnce() throws {
        let (deck, posted) = deck()
        try send(deck, "Notification")
        try send(deck, "Notification", after: 30)
        #expect(posted.notices.count == 1)
    }

    @Test func aPermissionPromptJustAfterAnAnswerIsAboutThatAnswer() throws {
        let (deck, _) = deck()
        try send(deck, "UserPromptSubmit")
        try send(deck, "PermissionRequest", bash("swift build"))
        let approval = try #require(deck.approvals.first)
        deck.allow(approval, shown: armed(for: approval), pressedAt: at(5.9))
        try send(deck, "Notification", after: 6)
        #expect(state(deck) == .working("Running swift build"))
    }

    @Test func aQuestionShowsWaitingToo() throws {
        let (deck, _) = deck()
        try send(deck, "Notification", ["notification_type": "elicitation_dialog"])
        #expect(state(deck) == .waiting("Has a question for you"))
    }

    @Test(arguments: ["PreToolUse", "PostToolUse", "UserPromptSubmit", "Stop"])
    func whatItDoesNextEndsTheWait(event: String) throws {
        let (deck, _) = deck()
        try send(deck, "UserPromptSubmit")
        try send(deck, "Notification")
        try send(deck, event, bash("ls"), after: 8)
        guard case .waiting = state(deck) else { return }
        Issue.record("Still waiting")
    }

    @Test func goingIdleEndsATurnWhoseStopNeverCame() throws {
        let (deck, _) = deck()
        try send(deck, "UserPromptSubmit")
        try send(deck, "Notification", ["notification_type": "idle_prompt"], after: 60)
        #expect(state(deck) == .done(at(60)))
    }

    @Test func goingIdleEndsAWait() throws {
        let (deck, _) = deck()
        try send(deck, "UserPromptSubmit")
        try send(deck, "Notification")
        try send(deck, "Notification", ["notification_type": "idle_prompt"], after: 60)
        #expect(state(deck) == .done(at(60)))
        #expect(deck.waitingCount == 0)
    }

    /// A No at the keyboard ends the turn with no Stop, so going idle is all that says so.
    @Test func goingIdleRetiresWhatWasAnsweredAtTheKeyboard() throws {
        let (deck, _) = deck()
        try send(deck, "UserPromptSubmit")
        try send(deck, "PermissionRequest", bash("rm x"))
        try send(deck, "Notification", ["notification_type": "idle_prompt"], after: 60)
        #expect(deck.approvals.isEmpty)
        #expect(answers.decisions.isEmpty)
        #expect(deck.waitingCount == 0)
        #expect(state(deck) == .done(at(60)))
    }

    @Test func aToolThatFailedRetiresItsApproval() throws {
        let (deck, _) = deck()
        try send(deck, "UserPromptSubmit")
        try send(deck, "PermissionRequest", bash("swift build"))
        try send(deck, "PostToolUseFailure", bash("swift build"))
        #expect(deck.approvals.isEmpty)
        #expect(answers.decisions.isEmpty)
    }

    @Test func waitingWithNoApprovalDoesntLastForHours() throws {
        let (deck, _) = deck()
        try send(deck, "PermissionRequest", bash("rm x"))
        deck.expire(now: at(AgentDeck.approvalBackstop))
        #expect(deck.waitingCount == 1)
        deck.expire(now: at(AgentDeck.doneHiddenAfter))
        #expect(deck.sessions.isEmpty)
        #expect(deck.waitingCount == 0)
    }

    // MARK: Where it runs

    @Test func anApprovalNamesWhereItRunsNotWhereTheSessionStarted() throws {
        let (deck, _) = deck()
        try send(deck, "SessionStart", ["cwd": "/Users/sample/lantern"])
        try send(deck, "PermissionRequest", bash("rm -rf *").merging(["cwd": "/Users/sample"]) { $1 })
        let approval = try #require(deck.approvals.first)
        #expect(approval.project == "sample")
        #expect(approval.lines.first == ApprovalLine(text: "/Users/sample", tone: .folder))
        #expect(approval.command == "rm -rf *")
        #expect(deck.sessions.first?.project == "lantern")
    }

    @Test func onlyACommandSaysWhereItRuns() throws {
        let (deck, _) = deck()
        try send(deck, "PermissionRequest", ["tool_name": "Write", "tool_input": ["file_path": "/a/b.txt", "content": "hi"], "cwd": "/a"])
        #expect(deck.approvals.first?.lines.contains { $0.tone == .folder } == false)
    }

    // MARK: Questions

    @Test(arguments: ["AskUserQuestion", "ExitPlanMode"])
    func aToolThatWantsMoreThanAYesStaysInClaudeCode(tool: String) throws {
        let (deck, _) = deck()
        var replied: [[String: Any]] = []
        let request = try #require(SocketRequest(line: JSONSerialization.data(withJSONObject: [
            "op": "hook", "hook_event_name": "PermissionRequest", "session_id": "s", "cwd": "/a/b", "tool_name": tool, "tool_input": [:],
        ])))
        #expect(deck.apply(request, now: at(0)) { replied.append($0) } == nil)
        #expect(deck.approvals.isEmpty)
        #expect(replied.count == 1)
        #expect(replied.first?["decision"] == nil)
        #expect(answers.decisions.isEmpty)
        #expect(deck.sessions.first?.state == .waiting("Has a question for you"))
    }

    // MARK: Review

    @Test func reviewBringsThatSessionsApprovalForward() throws {
        let (deck, _) = deck()
        try send(deck, "PermissionRequest", bash("first").merging(["session_id": "one"]) { $1 })
        try send(deck, "PermissionRequest", bash("second").merging(["session_id": "two"]) { $1 })
        #expect(deck.approvals.first?.sessionID == "one")
        deck.bringForward(session: "two")
        #expect(deck.approvals.map(\.sessionID) == ["two", "one"])
    }

    @Test func anIdleSessionStaysAsItWas() throws {
        let (deck, _) = deck()
        try send(deck, "Stop")
        try send(deck, "Notification", ["notification_type": "idle_prompt"], after: 60)
        #expect(state(deck) == .done(at(0)))
    }

    // MARK: Retiring

    @Test func theSameToolAndInputFinishingRetiresIt() throws {
        let (deck, _) = deck()
        try send(deck, "UserPromptSubmit")
        try send(deck, "PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "swift build", "description": "Build"]])
        try send(deck, "PostToolUse", bash("swift build"))
        #expect(deck.approvals.isEmpty)
        #expect(state(deck) == .working(nil))
        #expect(answers.decisions.isEmpty)
        #expect(answers.all.count == 3)
    }

    @Test func aDifferentCommandFinishingLeavesItWaiting() throws {
        let (deck, _) = deck()
        try send(deck, "PermissionRequest", bash("swift build"))
        try send(deck, "PostToolUse", bash("swift test"))
        #expect(deck.approvals.count == 1)
    }

    @Test func aDifferentToolFinishingLeavesItWaiting() throws {
        let (deck, _) = deck()
        try send(deck, "PermissionRequest", ["tool_name": "Write", "tool_input": ["file_path": "/a", "content": "x"]])
        try send(deck, "PostToolUse", ["tool_name": "Edit", "tool_input": ["file_path": "/a"]])
        #expect(deck.approvals.count == 1)
    }

    @Test func theSameFileWrittenRetiresItThoughOnlyThePathCameBack() throws {
        let (deck, _) = deck()
        try send(deck, "PermissionRequest", ["tool_name": "Write", "tool_input": ["file_path": "/a", "content": "x"]])
        try send(deck, "PostToolUse", ["tool_name": "Write", "tool_input": ["file_path": "/a", "content": "x"]])
        #expect(deck.approvals.isEmpty)
    }

    @Test func anotherSessionsToolFinishingLeavesItWaiting() throws {
        let (deck, _) = deck()
        try send(deck, "PermissionRequest", bash("swift build"), session: "one")
        try send(deck, "PostToolUse", bash("swift build"), session: "two")
        #expect(deck.approvals.count == 1)
    }

    @Test(arguments: ["UserPromptSubmit", "Stop", "SessionEnd"])
    func whatEndsTheQuestionRetiresIt(event: String) throws {
        let (deck, _) = deck()
        try send(deck, "PermissionRequest", bash("swift build"))
        try send(deck, "PermissionRequest", bash("swift test"))
        try send(deck, event)
        #expect(deck.approvals.isEmpty)
        #expect(answers.decisions.isEmpty)
    }

    @Test(arguments: ["UserPromptSubmit", "Stop", "SessionEnd"])
    func anotherSessionsEndLeavesItWaiting(event: String) throws {
        let (deck, _) = deck()
        try send(deck, "PermissionRequest", bash("swift build"), session: "one")
        try send(deck, event, session: "two")
        #expect(deck.approvals.count == 1)
    }

    @Test func theBackstopRetiresItALittlePastTheHooksLimit() throws {
        let (deck, _) = deck()
        try send(deck, "PermissionRequest", bash("swift build"))
        #expect(AgentDeck.approvalBackstop > 600 && AgentDeck.approvalBackstop <= 660)
        deck.expire(now: at(AgentDeck.approvalBackstop - 1))
        #expect(deck.approvals.count == 1)
        deck.expire(now: at(AgentDeck.approvalBackstop))
        #expect(deck.approvals.isEmpty)
        #expect(answers.decisions.isEmpty)
        // Claude Code may still be asking in its own window.
        #expect(state(deck) == .waiting("Needs your permission"))
    }

    @Test func turningTheSwitchOffRetiresIt() throws {
        let (deck, _) = deck()
        try send(deck, "PermissionRequest", bash("swift build"))
        AppSettings.shared.liveAgents = false
        deck.settingChanged()
        AppSettings.shared.liveAgents = true
        #expect(deck.approvals.isEmpty)
        #expect(deck.sessions.isEmpty)
        #expect(deck.waitingCount == 0)
        #expect(answers.decisions.isEmpty)
    }

    @Test func pastTheLimitClaudeCodeAsksForItself() throws {
        let (deck, _) = deck()
        for index in 0..<AgentDeck.mostApprovals { try send(deck, "PermissionRequest", bash("cmd \(index)")) }
        #expect(answers.all.isEmpty)
        let held = try send(deck, "PermissionRequest", bash("one too many"))
        #expect(held == nil)
        #expect(deck.approvals.count == AgentDeck.mostApprovals)
        #expect(answers.all.count == 1)
        #expect(answers.decisions.isEmpty)
    }

    // MARK: Allow and Deny

    @Test func allowAnswersIt() throws {
        let (deck, _) = deck()
        try send(deck, "UserPromptSubmit")
        try send(deck, "PermissionRequest", bash("swift build"))
        let approval = try #require(deck.approvals.first)
        deck.allow(approval, shown: armed(for: approval), pressedAt: at(5))
        #expect(answers.decisions == ["allow"])
        #expect(deck.approvals.isEmpty)
        #expect(state(deck) == .working("Running swift build"))
    }

    @Test func denyAnswersIt() throws {
        let (deck, _) = deck()
        try send(deck, "UserPromptSubmit")
        try send(deck, "PermissionRequest", bash("swift build"))
        let approval = try #require(deck.approvals.first)
        deck.deny(approval, shown: armed(for: approval), pressedAt: at(5))
        #expect(answers.decisions == ["deny"])
        #expect(deck.approvals.isEmpty)
        #expect(state(deck) == .working(nil))
    }

    @Test func neitherWorksBeforeTheGuardSaysSo() throws {
        let (deck, _) = deck()
        try send(deck, "PermissionRequest", bash("swift build"))
        let approval = try #require(deck.approvals.first)
        var justShown = ApprovalGuard()
        justShown.show(approval.id, at: at(0))
        deck.allow(approval, shown: justShown, pressedAt: at(0.3))
        deck.deny(approval, shown: justShown, pressedAt: at(0.3))
        #expect(answers.decisions.isEmpty)
        #expect(deck.approvals.count == 1)
    }

    @Test func aGuardForAnotherApprovalDoesntCount() throws {
        let (deck, _) = deck()
        try send(deck, "PermissionRequest", bash("swift build"))
        try send(deck, "PermissionRequest", bash("swift test"))
        let first = try #require(deck.approvals.first)
        let second = try #require(deck.approvals.last)
        deck.allow(first, shown: armed(for: second), pressedAt: at(5))
        #expect(answers.decisions.isEmpty)
    }

    @Test func onlyTheFrontOneCanBeAnswered() throws {
        let (deck, _) = deck()
        try send(deck, "PermissionRequest", bash("swift build"))
        try send(deck, "PermissionRequest", bash("swift test"))
        let second = try #require(deck.approvals.last)
        deck.allow(second, shown: armed(for: second), pressedAt: at(5))
        #expect(answers.decisions.isEmpty)
        #expect(deck.approvals.count == 2)
    }

    @Test func aDoubleClickOnAllowLeavesTheOneBehindItAlone() throws {
        let (deck, _) = deck()
        try send(deck, "PermissionRequest", bash("swift build"))
        try send(deck, "PermissionRequest", bash("rm -rf ~"))
        let first = try #require(deck.approvals.first)
        let second = try #require(deck.approvals.last)
        var shown = armed(for: first)
        deck.allow(first, shown: shown, pressedAt: at(5))
        // The glance has moved on to the next by the second click, a moment later.
        shown.show(second.id, at: at(5))
        deck.allow(second, shown: shown, pressedAt: at(5.2))
        #expect(answers.decisions == ["allow"])
        #expect(deck.approvals.map(\.id) == [second.id])
        // Before the view has caught up, the guard still names the first.
        deck.allow(second, shown: armed(for: first), pressedAt: at(5.2))
        #expect(answers.decisions == ["allow"])
    }

    @Test func anAnsweredApprovalCantBeAnsweredAgain() throws {
        let (deck, _) = deck()
        try send(deck, "PermissionRequest", bash("swift build"))
        let approval = try #require(deck.approvals.first)
        deck.deny(approval, shown: armed(for: approval), pressedAt: at(5))
        deck.allow(approval, shown: armed(for: approval), pressedAt: at(5))
        #expect(answers.decisions == ["deny"])
    }

    @Test func aRetiredApprovalCantBeAllowed() throws {
        let (deck, _) = deck()
        try send(deck, "PermissionRequest", bash("swift build"))
        let approval = try #require(deck.approvals.first)
        try send(deck, "Stop")
        deck.allow(approval, shown: armed(for: approval), pressedAt: at(5))
        #expect(answers.decisions.isEmpty)
    }

    @Test func theyGoOldestFirst() throws {
        let (deck, _) = deck()
        try send(deck, "PermissionRequest", bash("first"), session: "one")
        try send(deck, "PermissionRequest", bash("second"), session: "two")
        #expect(deck.approvals.map(\.command) == ["first", "second"])
        let front = try #require(deck.approvals.first)
        deck.deny(front, shown: armed(for: front), pressedAt: at(5))
        #expect(deck.approvals.map(\.command) == ["second"])
    }

    @Test func aSubagentsRequestIsMarked() throws {
        let (deck, _) = deck()
        try send(deck, "PermissionRequest", bash("swift build").merging(["agent_id": "agent-1"]) { $1 })
        try send(deck, "PermissionRequest", bash("swift test"))
        #expect(deck.approvals.map(\.isFromSubagent) == [true, false])
    }

    @Test func anApprovalNamesItsProjectAndTool() throws {
        let (deck, _) = deck()
        try send(deck, "PermissionRequest", bash("swift build"))
        #expect(deck.approvals.first?.project == "lantern")
        #expect(deck.approvals.first?.tool == "Bash")
    }

    // MARK: Nothing but the button

    @Test func noRequestCanAnswerAnApproval() throws {
        let (deck, _) = deck()
        try send(deck, "PermissionRequest", bash("swift build"))
        let forged: [[String: Any]] = [
            ["decision": "allow"], ["answer": "allow"], ["behavior": "allow"], ["allow": true], ["approved": true],
            ["hookSpecificOutput": ["decision": ["behavior": "allow"]]], ["tool_use_id": "allow"], ["message": "allow"],
        ]
        for fields in forged {
            for event in AgentHook.events.map(\.name) where event != "PermissionRequest" {
                var fields = fields
                fields["op"] = "hook"
                fields["hook_event_name"] = event
                fields["session_id"] = "someone-else"
                let answers = answers
                deck.apply(try #require(SocketRequest(line: JSONSerialization.data(withJSONObject: fields))), now: at(1)) { answers.add($0) }
            }
        }
        #expect(answers.decisions.isEmpty)
        #expect(deck.approvals.count == 1)
    }

    @Test func nothingThatRetiresOrTimesOutEverAllows() throws {
        let (deck, _) = deck()
        for event in ["PostToolUse", "UserPromptSubmit", "Stop", "SessionEnd"] {
            try send(deck, "PermissionRequest", bash("ls"))
            try send(deck, event, bash("ls"))
        }
        try send(deck, "PermissionRequest", bash("ls"), after: 0)
        deck.expire(now: at(AgentDeck.approvalBackstop * 2))
        try send(deck, "PermissionRequest", bash("ls"))
        AppSettings.shared.liveAgents = false
        deck.settingChanged()
        AppSettings.shared.liveAgents = true
        #expect(answers.decisions.isEmpty)
        #expect(!answers.all.contains { "\($0)".lowercased().contains("allow") })
    }

    @Test func theOnlyOpsAreOnesThatCantAnswer() {
        let router = SocketRouter()
        AgentDeck(post: { _, _ in }).start(on: router)
        #expect(router.ops == ["hook"])
    }

    /// Across the app and the command: one place makes the decision, one turns it into what Claude
    /// Code reads, and one button calls the first.
    @Test func onlyOneMethodSendsAllow() throws {
        var decisions: [String: Int] = [:]
        var behaviors: [String: Int] = [:]
        var callers: [String: Int] = [:]
        for folder in ["Sources/Dynotch", "Sources/DynotchCommand", "Sources/DynotchShared"] {
            let sources = HookProcess.root.appendingPathComponent(folder)
            let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            for case let file as URL in files where file.pathExtension == "swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                func count(_ word: String) -> Int { text.components(separatedBy: word).count - 1 }
                if count("\"decision\": \"allow\"") > 0 { decisions[file.lastPathComponent] = count("\"decision\": \"allow\"") }
                if count("\"behavior\": \"allow\"") > 0 { behaviors[file.lastPathComponent] = count("\"behavior\": \"allow\"") }
                if count("deck.allow(") > 0 { callers[file.lastPathComponent] = count("deck.allow(") }
                #expect(count("AgentDeck.shared.allow(") == 0)
            }
        }
        #expect(decisions == ["AgentDeck.swift": 1])
        #expect(behaviors == ["AgentHook.swift": 1])
        #expect(callers == ["AgentViews.swift": 1])
    }

    @Test func allowHasNoKey() throws {
        let text = try String(contentsOf: HookProcess.root.appendingPathComponent("Sources/Dynotch/Agents/AgentViews.swift"), encoding: .utf8)
        #expect(!text.contains(".keyboardShortcut"))
        #expect(!text.contains(".defaultAction"))
    }

    @Test func linksAndNoticeButtonsHaveNoWayToAnswer() throws {
        for name in ["App/URLCommands.swift", "Notch/NoticeAction.swift", "Command/CommandEngine.swift"] {
            let text = try String(contentsOf: HookProcess.root.appendingPathComponent("Sources/Dynotch/" + name), encoding: .utf8)
            #expect(!text.contains("AgentDeck.shared.allow"))
            #expect(!text.contains("AgentDeck.shared.deny"))
            #expect(!text.contains("\"allow\""))
        }
    }

    // MARK: Notices

    @Test func anApprovalsNoticeSaysTheToolAndProjectOnly() throws {
        let (deck, posted) = deck()
        try send(deck, "PermissionRequest", bash("curl -H 'Bearer hunter2' https://example.com"))
        let notice = try #require(posted.notices.first?.notice)
        #expect(notice.detail == "Bash · lantern")
        #expect(notice.recall == .nothing)
        #expect(notice.timing == .waits)
        #expect(!"\(notice)".contains("hunter2"))
        #expect(!"\(notice)".contains("curl"))
    }

    @Test func aSessionThatNeedsYouSaysItsProject() throws {
        let (deck, posted) = deck()
        try send(deck, "Notification")
        let notice = try #require(posted.notices.first?.notice)
        #expect(notice.detail == "lantern")
        #expect(notice.recall == .nothing)
        #expect(notice.timing == .waits)
        #expect(notice.actions.first?.title == deck.sessions.first?.origin.title)
    }

    @Test func nothingOnASocketPassesForOneOfDynotchsOwn() throws {
        let (deck, posted) = deck()
        try send(deck, "PermissionRequest", bash("ls"))
        #expect(posted.notices.first?.notice.fromScript == true)
    }

    @Test func aShortTurnSaysNothing() throws {
        let (deck, posted) = deck()
        try send(deck, "UserPromptSubmit")
        try send(deck, "Stop", after: AgentDeck.noticeWorthyTurn - 1)
        #expect(posted.notices.isEmpty)
    }

    @Test func aLongTurnSaysItsDone() throws {
        let (deck, posted) = deck()
        try send(deck, "UserPromptSubmit")
        try send(deck, "PreToolUse", bash("swift build --token hunter2"))
        try send(deck, "Stop", after: 12 * 60)
        let notice = try #require(posted.notices.first?.notice)
        #expect(notice.text == "Done")
        #expect(notice.detail == "lantern · 12 min")
        #expect(notice.timing == .waits)
        #expect(!"\(notice)".contains("hunter2"))
    }

    @Test func aSecondStopSaysNothing() throws {
        let (deck, posted) = deck()
        try send(deck, "UserPromptSubmit")
        try send(deck, "Stop", after: 600)
        try send(deck, "Stop", after: 1200)
        #expect(posted.notices.count == 1)
    }

    @Test func aHeldNoticeForAQuestionThatsGoneDoesntComeOut() throws {
        let (deck, posted) = deck()
        try send(deck, "PermissionRequest", bash("ls"))
        let notice = try #require(posted.notices.first?.notice)
        #expect(!deck.hasMovedOn(from: notice))
        try send(deck, "Stop")
        #expect(deck.hasMovedOn(from: notice))
        #expect(!deck.hasMovedOn(from: LiveNotice(key: "other", symbol: "bell", tint: .white)))
    }

    // MARK: Going away by itself

    @Test func aFinishedSessionLeavesAfterAWhile() throws {
        let (deck, _) = deck()
        try send(deck, "Stop")
        deck.expire(now: at(AgentDeck.doneHiddenAfter - 1))
        #expect(deck.sessions.count == 1)
        deck.expire(now: at(AgentDeck.doneHiddenAfter))
        #expect(deck.sessions.isEmpty)
    }

    @Test func aSessionThatNeverDidAnythingLeavesLikeOneThatFinished() throws {
        let (deck, _) = deck()
        try send(deck, "SessionStart")
        deck.expire(now: at(AgentDeck.doneHiddenAfter))
        #expect(deck.sessions.isEmpty)
    }

    @Test func aSilentWorkingSessionGoesAfterHours() throws {
        let (deck, _) = deck()
        try send(deck, "UserPromptSubmit")
        deck.expire(now: at(AgentDeck.silentDroppedAfter - 1))
        #expect(deck.sessions.count == 1)
        deck.expire(now: at(AgentDeck.silentDroppedAfter))
        #expect(deck.sessions.isEmpty)
    }

    @Test func hearingFromItStartsTheClockAgain() throws {
        let (deck, _) = deck()
        try send(deck, "UserPromptSubmit")
        try send(deck, "PreToolUse", bash("ls"), after: AgentDeck.silentDroppedAfter - 10)
        deck.expire(now: at(AgentDeck.silentDroppedAfter))
        #expect(deck.sessions.count == 1)
    }

    @Test func aSessionWithAnApprovalWaitingStays() throws {
        let (deck, _) = deck()
        try send(deck, "PermissionRequest", bash("ls"))
        deck.expire(now: at(AgentDeck.approvalBackstop - 1))
        #expect(deck.sessions.count == 1)
    }

    @Test func thereAreNeverTooManySessions() throws {
        let (deck, _) = deck()
        try send(deck, "PermissionRequest", bash("ls"), session: "asking")
        for index in 0..<(AgentDeck.mostSessions + 5) { try send(deck, "Stop", session: "s\(index)", after: Double(index + 1)) }
        #expect(deck.sessions.count == AgentDeck.mostSessions)
        #expect(deck.sessions.contains { $0.id == "asking" })
        #expect(!deck.sessions.contains { $0.id == "s0" })
    }

    // MARK: Lists and status

    @Test func waitingSortsFirstThenWorkingThenTheRest() throws {
        let (deck, _) = deck()
        try send(deck, "Stop", session: "done")
        try send(deck, "UserPromptSubmit", session: "busy")
        try send(deck, "PermissionRequest", bash("ls"), session: "asking")
        #expect(deck.ordered.map(\.id) == ["asking", "busy", "done"])
    }

    @Test func waitingSessionsGoInTheOrderOfTheGlance() throws {
        let (deck, _) = deck()
        try send(deck, "PermissionRequest", bash("ls"), session: "second-in-the-list-by-name-z")
        try send(deck, "PermissionRequest", bash("ls"), session: "a-later-one", after: 5)
        #expect(deck.ordered.map(\.id) == ["second-in-the-list-by-name-z", "a-later-one"])
    }

    @Test func aRowOnlyHasReviewWithAnApprovalToReview() throws {
        let (deck, _) = deck()
        try send(deck, "PermissionRequest", bash("ls"), session: "asking")
        try send(deck, "Notification", session: "elsewhere")
        #expect(deck.hasApproval(forSession: "asking"))
        #expect(!deck.hasApproval(forSession: "elsewhere"))
    }

    @Test func statusReportsCountsAndNothingAboutACommand() throws {
        let (deck, _) = deck()
        let router = SocketRouter()
        deck.start(on: router)
        try send(deck, "PermissionRequest", bash("curl --token hunter2"), session: "asking")
        try send(deck, "UserPromptSubmit", session: "busy")
        try send(deck, "PreToolUse", bash("swift build --token hunter2"), session: "busy")
        try send(deck, "Stop", session: "finished")
        try send(deck, "SessionStart", session: "new")
        let report = try #require(router.status["agents"] as? [String: Int])
        #expect(report == ["sessions": 4, "approvals": 1, "ready": 1, "working": 1, "waiting": 1, "done": 1])
        #expect(!"\(router.status)".contains("hunter2"))
        #expect(!"\(router.status)".contains("swift"))
    }

    @Test func statusForReadingSaysHowMany() {
        let text = CommandLineClient.summary(of: ["version": "1.5", "agents": ["sessions": 3, "waiting": 1, "working": 2, "ready": 0, "done": 0]])
        #expect(text == "Dynotch 1.5\nClaude Code: 1 waiting, 2 working\n")
    }

    @Test func statusForReadingLeavesItOutWithNoSessions() {
        #expect(CommandLineClient.summary(of: ["version": "1.5", "agents": ["sessions": 0]]) == "Dynotch 1.5\n")
    }

    // MARK: The switch

    @Test func withTheSwitchOffItAnswersAtOnceAndShowsNothing() throws {
        let (deck, posted) = deck()
        AppSettings.shared.liveAgents = false
        defer { AppSettings.shared.liveAgents = true }
        let held = try send(deck, "PermissionRequest", bash("swift build"))
        try send(deck, "UserPromptSubmit")
        try send(deck, "Notification")
        #expect(held == nil)
        #expect(answers.all.count == 3)
        #expect(answers.decisions.isEmpty)
        #expect(deck.sessions.isEmpty)
        #expect(deck.approvals.isEmpty)
        #expect(posted.notices.isEmpty)
    }

    // MARK: The notch

    private func viewModel() -> NotchViewModel {
        NotchViewModel(geometry: NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                                               closedSize: CGSize(width: 185, height: 32), hasHardwareNotch: true))
    }

    private func sample(_ command: String = "swift build") -> AgentApproval {
        AgentApproval(sessionID: "s", project: "lantern", tool: "Bash", input: ["command": command])
    }

    @Test func anApprovalWidensTheGlanceAndTakesItOver() {
        SnapshotRenderer.useScratchDefaults()
        AppSettings.shared.liveAgents = true
        AgentDeck.shared.loadSample(sessions: [], approvals: [sample()])
        defer { AgentDeck.shared.clearSample() }
        let viewModel = viewModel()
        viewModel.stage(phase: .glance, activity: .idle)
        defer { viewModel.close() }
        #expect(viewModel.metrics.width == ApprovalGlance.width)
        #expect(viewModel.noticeHasActions)
        guard case .approval = viewModel.glanceContent else {
            Issue.record("The glance shows something else")
            return
        }
    }

    @Test func aLongCommandMakesTheGlanceTallerUpToAPoint() {
        let one = ApprovalGlance.extraHeight(for: sample())
        let three = ApprovalGlance.extraHeight(for: sample("a\nb\nc"))
        let many = ApprovalGlance.extraHeight(for: sample(Array(repeating: "line", count: 500).joined(separator: "\n")))
        let ten = ApprovalGlance.extraHeight(for: sample(Array(repeating: "line", count: 10).joined(separator: "\n")))
        #expect(three > one)
        #expect(many > three)
        #expect(many == ten)
    }

    @Test func aFullWellStillFitsThePanel() {
        SnapshotRenderer.useScratchDefaults()
        let tallest = 32 + ApprovalGlance.extraHeight(for: sample(Array(repeating: "line", count: 500).joined(separator: "\n")))
        #expect(tallest <= NotchViewModel.tallestOpenHeight(closedHeight: 32))
    }

    @Test func reviewTurnsTheOpenNotchToTheGlance() {
        SnapshotRenderer.useScratchDefaults()
        AppSettings.shared.liveAgents = true
        AgentDeck.shared.loadSample(sessions: [], approvals: [sample()])
        defer { AgentDeck.shared.clearSample() }
        let viewModel = viewModel()
        viewModel.stage(phase: .open, activity: .idle)
        var turned = false
        viewModel.onTurnToGlance = { turned = true }
        viewModel.showApproval()
        #expect(viewModel.isGlancing)
        #expect(turned)
        // The click that did it shouldn't count as a click on what appears.
        #expect(!viewModel.acceptsNoticeButtons)
        viewModel.close()
    }

    @Test func theSwitchOffHidesAnApprovalFromTheGlance() {
        SnapshotRenderer.useScratchDefaults()
        AppSettings.shared.liveAgents = false
        defer { AppSettings.shared.liveAgents = true }
        AgentDeck.shared.loadSample(sessions: [], approvals: [sample()])
        defer { AgentDeck.shared.clearSample() }
        let viewModel = viewModel()
        #expect(!viewModel.noticeHasActions)
    }

    // MARK: Over a real socket

    private func listening() -> (AgentDeck, SocketRouter, Scratch) {
        let (deck, _) = deck()
        let router = SocketRouter()
        let scratch = Scratch()
        deck.start(on: router)
        router.start(path: scratch.path)
        return (deck, router, scratch)
    }

    @Test(.enabled(if: HookProcess.hasBinary)) func allowGoesAllTheWayThroughTheRealCommand() async throws {
        let (deck, router, scratch) = listening()
        defer {
            router.stop()
            try? FileManager.default.removeItem(atPath: scratch.folder)
        }
        let hook = try HookProcess(input: HookPayloads.data("PermissionRequest"), socket: scratch.path)
        await waitUntil { !deck.approvals.isEmpty }
        let approval = try #require(deck.approvals.first)
        #expect(approval.command == "swift build --product Lantern")
        #expect(deck.sessions.first?.origin.program == "ghostty")
        deck.allow(approval, shown: armed(for: approval), pressedAt: .now)
        let result = await hook.finish()
        #expect(result.code == 0)
        let parsed = try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: [String: Any]]
        #expect((parsed?["hookSpecificOutput"]?["decision"] as? [String: String]) == ["behavior": "allow"])
        #expect(parsed?["hookSpecificOutput"]?["hookEventName"] as? String == "PermissionRequest")
    }

    @Test(.enabled(if: HookProcess.hasBinary)) func denyGoesAllTheWayThroughTheRealCommand() async throws {
        let (deck, router, scratch) = listening()
        defer {
            router.stop()
            try? FileManager.default.removeItem(atPath: scratch.folder)
        }
        let hook = try HookProcess(input: HookPayloads.data("PermissionRequest"), socket: scratch.path)
        await waitUntil { !deck.approvals.isEmpty }
        let approval = try #require(deck.approvals.first)
        deck.deny(approval, shown: armed(for: approval), pressedAt: .now)
        let result = await hook.finish()
        #expect(result.code == 0)
        let parsed = try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: [String: Any]]
        #expect((parsed?["hookSpecificOutput"]?["decision"] as? [String: String])?["behavior"] == "deny")
    }

    @Test(.enabled(if: HookProcess.hasBinary)) func aRetiredApprovalLeavesTheRealCommandSilent() async throws {
        let (deck, router, scratch) = listening()
        defer {
            router.stop()
            try? FileManager.default.removeItem(atPath: scratch.folder)
        }
        let hook = try HookProcess(input: HookPayloads.data("PermissionRequest"), socket: scratch.path)
        await waitUntil { !deck.approvals.isEmpty }
        let stop = try HookProcess(input: HookPayloads.data("Stop"), socket: scratch.path)
        let result = await hook.finish()
        let stopped = await stop.finish()
        #expect(result.code == 0)
        #expect(result.output.isEmpty)
        #expect(stopped.code == 0)
        #expect(stopped.output.isEmpty)
        #expect(deck.approvals.isEmpty)
        #expect(state(deck) == .done(deck.sessions.first.flatMap {
            if case .done(let date) = $0.state { return date }
            return nil
        } ?? .distantPast))
    }

    @Test(.enabled(if: HookProcess.hasBinary)) func aKilledHookTakesItsApprovalWithIt() async throws {
        let (deck, router, scratch) = listening()
        defer {
            router.stop()
            try? FileManager.default.removeItem(atPath: scratch.folder)
        }
        let hook = try HookProcess(input: HookPayloads.data("PermissionRequest"), socket: scratch.path)
        await waitUntil { !deck.approvals.isEmpty }
        #expect(deck.approvals.count == 1)
        hook.terminate()
        await waitUntil { deck.approvals.isEmpty }
        #expect(deck.approvals.isEmpty)
        #expect(state(deck) == .waiting("Needs your permission"))
        let result = await hook.finish()
        #expect(result.reason == .uncaughtSignal)
        #expect(result.output.isEmpty)
    }

    @Test(.enabled(if: HookProcess.hasBinary)) func aBigWriteReachesTheGlanceWhole() async throws {
        let (deck, router, scratch) = listening()
        defer {
            router.stop()
            try? FileManager.default.removeItem(atPath: scratch.folder)
        }
        let content = (1...60_000).map { "line \($0)" }.joined(separator: "\n") + "\nthe very end"
        let input = HookPayloads.data("PermissionRequest", ["tool_name": "Write", "tool_input": ["file_path": "/tmp/big.txt", "content": content]])
        let hook = try HookProcess(input: input, socket: scratch.path)
        await waitUntil { !deck.approvals.isEmpty }
        let approval = try #require(deck.approvals.first)
        #expect(approval.lines.count == 60_002)
        #expect(approval.lines.last?.text == "the very end")
        #expect(approval.wrappedLines > ApprovalLine.mostShown)
        deck.deny(approval, shown: armed(for: approval), pressedAt: .now)
        #expect(await hook.finish().code == 0)
    }

    @Test(.enabled(if: HookProcess.hasBinary)) func everyEventGetsThroughTheRealCommand() async throws {
        let (deck, router, scratch) = listening()
        defer {
            router.stop()
            try? FileManager.default.removeItem(atPath: scratch.folder)
        }
        for (event, check) in [("SessionStart", AgentSession.State.ready), ("UserPromptSubmit", .working(nil)),
                               ("PreToolUse", .working("Running swift build")), ("PostToolUse", .working(nil))] {
            let result = await (try HookProcess(input: HookPayloads.data(event), socket: scratch.path)).finish()
            #expect(result.code == 0)
            #expect(result.output.isEmpty)
            await waitUntil { state(deck) == check }
            #expect(state(deck) == check)
        }
        _ = await (try HookProcess(input: HookPayloads.data("SessionEnd"), socket: scratch.path)).finish()
        await waitUntil { deck.sessions.isEmpty }
        #expect(deck.sessions.isEmpty)
    }

    @Test(.enabled(if: HookProcess.hasBinary), arguments: Array(HookPayloads.texts.keys))
    func aDeadSocketLeavesTheRealCommandSilent(event: String) async throws {
        let scratch = Scratch()
        let result = await (try HookProcess(input: HookPayloads.data(event), socket: scratch.path)).finish()
        #expect(result.code == 0)
        #expect(result.output.isEmpty)
    }

    @Test(.enabled(if: HookProcess.hasBinary)) func withTheSwitchOffTheRealCommandReturnsAtOnce() async throws {
        let (deck, router, scratch) = listening()
        AppSettings.shared.liveAgents = false
        defer {
            AppSettings.shared.liveAgents = true
            router.stop()
            try? FileManager.default.removeItem(atPath: scratch.folder)
        }
        let result = await (try HookProcess(input: HookPayloads.data("PermissionRequest"), socket: scratch.path)).finish()
        #expect(result.code == 0)
        #expect(result.output.isEmpty)
        #expect(deck.sessions.isEmpty)
    }

    @Test func noOpOverTheSocketCanAnswerAHeldApproval() async throws {
        let (deck, router, scratch) = listening()
        defer {
            router.stop()
            try? FileManager.default.removeItem(atPath: scratch.folder)
        }
        let scripts = ScriptActivityStore(post: { _, _ in })
        scripts.start(on: router)
        let path = scratch.path
        let waiting = Task {
            let answer = try? await offThePool {
                try SocketClient(path: path).send(["op": "hook", "hook_event_name": "PermissionRequest", "session_id": "s",
                                                   "tool_name": "Bash", "tool_input": ["command": "ls"]], timeout: nil)
            }
            return answer?["decision"] as? String
        }
        await waitUntil { !deck.approvals.isEmpty }
        for op in router.ops + ["status", "allow", "deny", "approve", "answer", "decision"] {
            _ = try await offThePool {
                try SocketClient(path: path).send(["op": op, "decision": "allow", "key": "x", "state": "allow"])
            }
        }
        #expect(deck.approvals.count == 1)
        // Now retire it, which is how the wait ends without an answer.
        deck.expire(now: .now.addingTimeInterval(AgentDeck.approvalBackstop + 1))
        #expect(await waiting.value == nil)
        withExtendedLifetime(scripts) {}
    }
}
