import AppKit
import Combine
import DynotchShared
import SwiftUI

/// A Claude Code session the hooks have told Dynotch about.
struct AgentSession: Identifiable, Equatable {
    enum State: Equatable {
        /// Started, with nothing asked of it yet.
        case ready
        /// What it's doing, such as "Running swift build", when that's known.
        case working(String?)
        /// It needs you, and this says what for.
        case waiting(String)
        case done(Date)
    }

    let id: String
    var project: String
    var state: State = .ready
    /// When it started on what it's working on now.
    var since: Date
    var origin = TerminalOrigin()

    /// The quiet line in its row. It names a command, never its arguments.
    func line(at now: Date) -> String {
        switch state {
        case .ready:
            return "Ready"
        case .working(let doing):
            let doing = doing ?? "Working"
            let minutes = Int(now.timeIntervalSince(since) / 60)
            return minutes < 1 ? doing : "\(doing) · \(Self.span(minutes: minutes))"
        case .waiting(let asking):
            return asking
        case .done(let date):
            let minutes = Int(now.timeIntervalSince(date) / 60)
            return minutes < 1 ? "Done just now" : "Done \(Self.span(minutes: minutes)) ago"
        }
    }

    /// "4 min", "2 hr"
    static func span(minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : "\(minutes / 60) hr"
    }
}

/// One line of what an approval would do. It holds no line break, and shows through `HonestText`.
struct ApprovalLine: Equatable {
    enum Tone: Equatable {
        case plain, path, removed, added
        /// The rest of a tool's input, under what matters.
        case quiet
        /// Where a command would run, which a command like `rm -rf *` depends on.
        case folder
    }

    var text: String
    var tone: Tone = .plain

    /// The most lines the well shows before it scrolls.
    static let mostShown = 10
    /// How wide the well's text is, in `NotchFont.mono`.
    private static let shownWidth: CGFloat = 512
    /// Too long to fit whatever it holds, so there's no need to lay it out.
    private static let longestMeasured = 2048

    /// How many lines these take in the well, on screen, counting no further than one past what it
    /// shows. Measured rather than worked out from their length, since markers run wider than what they replace.
    static func wrappedCount(of lines: [ApprovalLine]) -> Int {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)]
        func height(of text: String) -> CGFloat {
            (text as NSString).boundingRect(with: CGSize(width: shownWidth, height: .greatestFiniteMagnitude),
                                            options: .usesLineFragmentOrigin, attributes: attributes).height
        }
        let lineHeight = height(of: "x")
        var count = 0
        for line in lines {
            guard line.text.utf8.count <= longestMeasured else { return mostShown + 1 }
            let shown = HonestText.runs(line.text).map(\.text).joined()
            count += max(1, Int((height(of: shown) / lineHeight).rounded()))
            if count > mostShown { break }
        }
        return count
    }

    /// What a tool would do: the command for Bash, the path and what would change for Write and
    /// Edit, and the whole input for anything else, under the tool's full name if the header has a shorter one.
    static func lines(tool: String, input: [String: Any]) -> [ApprovalLine] {
        var rest = input
        var lines: [ApprovalLine] = []
        switch tool {
        case "Bash":
            if let command = rest.removeValue(forKey: "command") as? String { lines = plain(command) }
        case "Write":
            if let path = input["file_path"] as? String, let content = input["content"] as? String {
                rest["file_path"] = nil
                rest["content"] = nil
                lines = [ApprovalLine(text: path, tone: .path)] + plain(content)
            }
        case "Edit":
            if let path = input["file_path"] as? String, let old = input["old_string"] as? String, let new = input["new_string"] as? String {
                for key in ["file_path", "old_string", "new_string"] { rest[key] = nil }
                lines = [ApprovalLine(text: path, tone: .path)]
                    + HonestText.lines(of: old).map { ApprovalLine(text: "- " + $0, tone: .removed) }
                    + HonestText.lines(of: new).map { ApprovalLine(text: "+ " + $0, tone: .added) }
            }
        default:
            break
        }
        guard !lines.isEmpty else {
            let name = AgentWords.name(ofTool: tool) == tool ? [] : [ApprovalLine(text: tool, tone: .path)]
            return name + plain(json(input))
        }
        return lines + rest.keys.sorted().flatMap { key in
            HonestText.lines(of: "\(key): \(json(rest[key] ?? NSNull()))").map { ApprovalLine(text: $0, tone: .quiet) }
        }
    }

    private static func plain(_ text: String) -> [ApprovalLine] {
        HonestText.lines(of: text).map { ApprovalLine(text: $0) }
    }

    private static func json(_ value: Any) -> String {
        let options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: options) else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// A tool call waiting for an answer. What it would run stays in memory, and only the glance shows it.
struct AgentApproval: Identifiable, Equatable {
    let id: UUID
    var sessionID: String
    var project: String
    /// The tool, short enough for a notice: `github` for `mcp__github__create_issue`.
    var tool: String
    /// What it would do, in full.
    var lines: [ApprovalLine]
    /// How many lines of the well that takes. See `ApprovalLine.wrappedCount`.
    var wrappedLines: Int
    /// A subagent is asking, not the session itself.
    var isFromSubagent: Bool
    var origin: TerminalOrigin
    /// For its session's row: what it wants, with no arguments.
    var asking: String
    /// For the same row once it's allowed.
    var doing: String

    init(id: UUID = UUID(), sessionID: String, project: String, tool: String, input: [String: Any], folder: String? = nil,
         isFromSubagent: Bool = false, origin: TerminalOrigin = TerminalOrigin()) {
        self.id = id
        self.sessionID = sessionID
        self.project = project
        self.tool = AgentWords.name(ofTool: tool)
        self.isFromSubagent = isFromSubagent
        self.origin = origin
        let target = AgentHook.target(of: input)
        asking = AgentWords.wants(tool: tool, target: target)
        doing = AgentWords.doing(tool: tool, target: target)
        lines = ApprovalLine.lines(tool: tool, input: input)
        if tool == "Bash", let folder, !folder.isEmpty {
            lines.insert(ApprovalLine(text: (folder as NSString).abbreviatingWithTildeInPath, tone: .folder), at: 0)
        }
        wrappedLines = ApprovalLine.wrappedCount(of: lines)
    }

    /// Everything it would do, as plain text.
    var command: String { lines.filter { $0.tone != .folder }.map(\.text).joined(separator: "\n") }
}

/// Keeps Allow and Deny inert for a moment after an approval reaches the front, so a double click
/// meant for something else can't land on them: the click that brought the glance up, or the second
/// click on Allow for the approval before this one. One that takes another's place under the pointer
/// gets longer, to be seen as a different one. It's told the time, so it can be tested, and it's asked
/// about when a press began: one that began too soon, or on the approval before this one, doesn't
/// count, however late it's let go.
struct ApprovalGuard: Equatable {
    static let shortestDelay: TimeInterval = 0.6
    /// For one that follows another.
    static let nextDelay: TimeInterval = 1.2

    /// However long the user has set a double click to take, and never less than `shortestDelay`.
    static func delay(doubleClick: TimeInterval = NSEvent.doubleClickInterval) -> TimeInterval {
        max(doubleClick, shortestDelay)
    }

    /// The approval at the front when it was last told.
    private(set) var front: UUID?
    private var since = Date.distantFuture
    private var followsAnother = false
    var delay: TimeInterval = ApprovalGuard.delay()

    /// How long it's inert for the one at the front.
    var wait: TimeInterval { followsAnother ? max(delay, Self.nextDelay) : delay }

    /// `approval` is at the front now. The clock starts over for a different one, and only then.
    mutating func show(_ approval: UUID?, at now: Date) {
        guard approval != front else { return }
        followsAnother = front != nil && approval != nil
        front = approval
        since = now
    }

    /// Whether a press that began at `pressedAt` counts for `approval`. Never for one that isn't at the front.
    func accepts(_ approval: UUID, at pressedAt: Date) -> Bool {
        approval == front && pressedAt.timeIntervalSince(since) >= wait
    }
}

/// Every Claude Code session in the notch: what's working, what's waiting and what's done. Hooks tell
/// it what happens over the socket. A permission request stays open here until it's answered in the
/// glance or retired. Nothing it holds is written to disk.
///
/// The hook runs alongside Claude Code's own prompt, in the terminal and in the desktop app, and
/// whichever answers first wins. Answering at the keyboard doesn't stop the hook, so an approval can
/// outlive its question, and the deck retires it by what happens next. Retiring one sends no decision,
/// which is always safe: the prompt is still there.
@MainActor
final class AgentDeck: ObservableObject {
    typealias Reply = ([String: Any]) -> Void

    static let shared = AgentDeck()

    static let mostSessions = 40
    /// Each one holds a connection, of the socket's 64. Past this, Claude Code's own prompt deals with it.
    static let mostApprovals = 24
    static let longestProject = 60
    private static let longestID = 128
    /// A hook is stopped at 600 seconds, so past this one either went without a word or was never heard from again.
    static let approvalBackstop: TimeInterval = 610
    /// A finished session leaves the list after an hour. The desktop keeps idle sessions alive for days.
    static let doneHiddenAfter: TimeInterval = 3600
    /// One still working that's said nothing for six hours has gone without a SessionEnd, or can come back with its next event.
    static let silentDroppedAfter: TimeInterval = 6 * 3600
    /// A turn this long gets a notice when it stops. A shorter one you're probably still watching.
    static let noticeWorthyTurn: TimeInterval = 120
    /// A permission prompt notification this soon after an answer is about what was just answered.
    private static let answerEcho: TimeInterval = 2
    /// How long a session that ended stays over, as what it said last can arrive after that.
    private static let endEcho: TimeInterval = 60
    /// Finished calls to remember, as a PreToolUse can arrive after its PostToolUse.
    private static let mostFinished = 8

    /// Tools that put something to you and want more than a yes. An allow with nothing else in it does
    /// nothing for these, so the question stays in Claude Code's own window.
    private static let askingTools: Set = ["AskUserQuestion", "ExitPlanMode"]

    /// The color that says it needs you.
    static let tint = Color.orange
    private static let askingKey = "agents.asking."

    @Published private(set) var sessions: [AgentSession] = []
    /// Tool calls waiting for an answer, oldest first.
    @Published private(set) var approvals: [AgentApproval] = []
    /// How many things need you, for the closed notch: approvals, and sessions asking in their own window.
    @Published private(set) var waitingCount = 0
    /// For a snapshot of Allow and Deny before they wake up.
    private(set) var isSampleInert = false

    var hasSessions: Bool { !sessions.isEmpty }

    /// A session's tool call in flight.
    private struct Call {
        var id: String?
        var doing: String
        var since: Date
    }

    private enum Phase: Equatable {
        case ready, working
        case done(Date)
    }

    /// What's known about a session besides what it shows, so one that only says it's alive redraws nothing.
    private struct Memory {
        var lastHeard: Date
        var phase = Phase.ready
        var turnStartedAt: Date?
        /// The last call to start and not finish.
        var call: Call?
        var finished: [String] = []
        /// It's asking in its own window, with no approval here to answer. This says what for.
        var asking: String?
        var answeredAt: Date?
    }

    /// The hook behind an approval.
    private struct Waiter {
        let reply: Reply
        let tool: String
        let target: [String: String]
        let deadline: Date
    }

    private var memories: [String: Memory] = [:]
    private var waiters: [UUID: Waiter] = [:]
    /// When sessions that have ended did, for as long as they might still be heard from.
    private var endedAt: [String: Date] = [:]
    private var clock: Task<Void, Never>?
    private var scheduledWake: Date?
    private var cancellables = Set<AnyCancellable>()
    private let post: @MainActor (LiveNotice, TimeInterval) -> Void

    init(post: @escaping @MainActor (LiveNotice, TimeInterval) -> Void = { LiveActivityCenter.shared.post($0, for: $1) }) {
        self.post = post
    }

    func start(on router: SocketRouter? = nil) {
        let router = router ?? .shared
        router.handle("hook") { [weak self] request, connection in
            guard let self else { return connection.reply(["ok": true]) }
            self.receive(request, from: connection)
        }
        router.reportsStatus("agents") { [weak self] in self?.statusReport ?? [:] }
        // These publish before the value changes, so act on the next turn.
        AppSettings.shared.$liveAgents
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.settingChanged() }
            .store(in: &cancellables)
    }

    // MARK: Hooks

    private func receive(_ request: SocketRequest, from connection: SocketConnection) {
        guard let id = apply(request, reply: { connection.reply($0) }) else { return }
        connection.whenClientGoes { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.clientWent(id) }
            }
        }
    }

    /// Carries out a `hook` request. `reply` answers it, now, or later for an approval, whose id comes back.
    /// Nothing in a request can answer an approval, and none of the replies here carry a decision.
    @discardableResult
    func apply(_ request: SocketRequest, now: Date = .now, reply: @escaping Reply) -> UUID? {
        guard AppSettings.shared.liveAgents, let event = request.string("hook_event_name"),
              let id = ScriptActivityStore.cleaned(request.string("session_id"), limit: Self.longestID) else {
            reply(["ok": true])
            return nil
        }
        // What a session said last can arrive after it ended. Only these two mean it's back.
        if event == "SessionStart" || event == "UserPromptSubmit" {
            endedAt[id] = nil
        } else if let ended = endedAt[id], now.timeIntervalSince(ended) < Self.endEcho {
            reply(["ok": true])
            return nil
        }
        var held: UUID?
        switch event {
        case "SessionStart":
            // A known session is only compacting or resuming, and stays as it is.
            track(id, request, now: now)
        case "SessionEnd":
            retireApprovals(ofSession: id)
            remove(id)
            endedAt[id] = now
        case "UserPromptSubmit":
            track(id, request, now: now)
            retireApprovals(ofSession: id)
            memories[id]?.phase = .working
            memories[id]?.turnStartedAt = now
            memories[id]?.call = nil
            memories[id]?.asking = nil
            memories[id]?.finished = []
        case "PreToolUse":
            track(id, request, now: now)
            callStarted(in: id, request, now: now)
        case "PostToolUse", "PostToolUseFailure":
            track(id, request, now: now)
            callFinished(in: id, request, now: now)
        case "PermissionRequest":
            track(id, request, now: now)
            held = hold(request, in: id, now: now, reply: reply)
        case "Notification":
            track(id, request, now: now)
            notified(id, type: request.string("notification_type"), now: now)
        case "Stop":
            track(id, request, now: now)
            retireApprovals(ofSession: id)
            stopped(id, now: now)
        default:
            memories[id]?.lastHeard = now
        }
        show(id, now: now)
        wakeForNext()
        if held == nil { reply(["ok": true]) }
        return held
    }

    /// The session `request` is from, made if this is the first of it.
    private func track(_ id: String, _ request: SocketRequest, now: Date) {
        let origin = (request.fields["origin"] as? [String: Any]).map(TerminalOrigin.init(fields:))
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            if let origin, sessions[index].origin != origin { sessions[index].origin = origin }
        } else {
            if sessions.count >= Self.mostSessions { dropQuietest() }
            sessions.append(AgentSession(id: id, project: Self.project(of: request.string("cwd")), since: now,
                                         origin: origin ?? TerminalOrigin()))
        }
        memories[id, default: Memory(lastHeard: now)].lastHeard = now
    }

    /// The name of the folder it runs in. That's kept from its first event: a `cd` can change the rest.
    static func project(of folder: String?) -> String {
        HonestText.line(((folder ?? "") as NSString).lastPathComponent, limit: longestProject) ?? "Claude Code"
    }

    private func callStarted(in id: String, _ request: SocketRequest, now: Date) {
        guard var memory = memories[id] else { return }
        let call = request.string("tool_use_id")
        guard call == nil || !memory.finished.contains(call ?? "") else { return }
        let target = AgentHook.target(of: request.fields["tool_input"] as? [String: Any] ?? [:])
        memory.call = Call(id: call, doing: AgentWords.doing(tool: request.string("tool_name") ?? "", target: target), since: now)
        memory.asking = nil
        if memory.phase != .working {
            memory.phase = .working
            memory.turnStartedAt = memory.turnStartedAt ?? now
        }
        memories[id] = memory
    }

    private func callFinished(in id: String, _ request: SocketRequest, now: Date) {
        guard var memory = memories[id] else { return }
        let tool = request.string("tool_name") ?? ""
        let target = AgentHook.target(of: request.fields["tool_input"] as? [String: Any] ?? [:])
        for approval in approvals where approval.sessionID == id {
            if let waiter = waiters[approval.id], waiter.tool == tool, waiter.target == target { retire(approval.id) }
        }
        let call = request.string("tool_use_id")
        if memory.call?.id == nil || memory.call?.id == call { memory.call = nil }
        if let call { memory.finished = Array((memory.finished + [call]).suffix(Self.mostFinished)) }
        memory.asking = nil
        // First heard of partway through a turn. A session that's done stays done: this can arrive after its Stop.
        if memory.phase == .ready {
            memory.phase = .working
            memory.turnStartedAt = now
        }
        memories[id] = memory
    }

    private func hold(_ request: SocketRequest, in id: String, now: Date, reply: @escaping Reply) -> UUID? {
        guard approvals.count < Self.mostApprovals, let session = sessions.first(where: { $0.id == id }) else { return nil }
        let input = request.fields["tool_input"] as? [String: Any] ?? [:]
        let tool = request.string("tool_name") ?? ""
        if Self.askingTools.contains(tool) {
            memories[id]?.asking = "Has a question for you"
            announceAsking(session, tool: nil, actions: session.origin.action.map { [$0] } ?? [])
            return nil
        }
        // Where it runs now, which a `cd` may have moved on from where the session started.
        let folder = request.string("cwd")
        let approval = AgentApproval(sessionID: id, project: folder.map(Self.project(of:)) ?? session.project, tool: tool, input: input,
                                     folder: folder, isFromSubagent: request.string("agent_id") != nil, origin: session.origin)
        approvals.append(approval)
        waiters[approval.id] = Waiter(reply: reply, tool: tool, target: AgentHook.target(of: input),
                                      deadline: now.addingTimeInterval(Self.approvalBackstop))
        memories[id]?.asking = nil
        announceAsking(session, tool: approval.tool)
        return approval.id
    }

    private func notified(_ id: String, type: String?, now: Date) {
        guard var memory = memories[id], let session = sessions.first(where: { $0.id == id }) else { return }
        let hasApproval = approvals.contains { $0.sessionID == id }
        switch type {
        case "permission_prompt", "elicitation_dialog":
            let justAnswered = memory.answeredAt.map { now.timeIntervalSince($0) < Self.answerEcho } ?? false
            guard !hasApproval, !justAnswered, memory.asking == nil else { return }
            memory.asking = type == "permission_prompt" ? "Needs your permission" : "Has a question for you"
            announceAsking(session, tool: nil, actions: session.origin.action.map { [$0] } ?? [])
        case "idle_prompt":
            // It's waiting for a new prompt, so what it asked has been answered, and if its Stop never
            // came, as after a No at the keyboard, its turn is over.
            retireApprovals(ofSession: id)
            memory.asking = nil
            if memory.phase == .working {
                memory.phase = .done(now)
                memory.call = nil
                memory.turnStartedAt = nil
            }
        default:
            return
        }
        memories[id] = memory
    }

    private func stopped(_ id: String, now: Date) {
        guard var memory = memories[id], let session = sessions.first(where: { $0.id == id }) else { return }
        let started = memory.turnStartedAt
        memory.phase = .done(now)
        memory.turnStartedAt = nil
        memory.call = nil
        memory.asking = nil
        memories[id] = memory
        guard let started, now.timeIntervalSince(started) >= Self.noticeWorthyTurn else { return }
        let minutes = Int(now.timeIntervalSince(started) / 60)
        post(LiveNotice(key: "agents.done.\(id)", symbol: "checkmark.circle.fill", tint: .green, text: "Done",
                        detail: "\(session.project) · \(AgentSession.span(minutes: minutes))", fromScript: true,
                        actions: session.origin.action.map { [$0] } ?? [], timing: .waits, recall: .whole), 4)
    }

    /// Says a session needs you, with the tool and the project and nothing about what it would do.
    /// Over the socket anyone can name a project, so it carries the terminal badge.
    private func announceAsking(_ session: AgentSession, tool: String?, actions: [NoticeAction] = []) {
        post(LiveNotice(key: Self.askingKey + session.id, symbol: "hand.raised.fill", tint: Self.tint, text: "Needs you",
                        detail: tool.map { "\($0) · \(session.project)" } ?? session.project, fromScript: true,
                        actions: actions, timing: .waits, recall: .nothing), 5)
    }

    /// A notice about a session that has moved on since it was posted, as one held through a call may have.
    func hasMovedOn(from notice: LiveNotice) -> Bool {
        guard notice.key.hasPrefix(Self.askingKey) else { return false }
        let id = String(notice.key.dropFirst(Self.askingKey.count))
        if case .waiting = sessions.first(where: { $0.id == id })?.state { return false }
        return true
    }

    // MARK: Answers

    /// Allows a tool call. This is the only place an allow leaves the app from, and only the button in
    /// the glance calls it, with the guard for what's on screen and when the press on it began.
    func allow(_ approval: AgentApproval, shown: ApprovalGuard, pressedAt: Date) {
        guard canAnswer(approval, shown: shown, pressedAt: pressedAt), let waiter = waiters[approval.id] else { return }
        waiter.reply(["ok": true, "decision": "allow"])
        answered(approval, doing: approval.doing, at: pressedAt)
    }

    /// Denies a tool call.
    func deny(_ approval: AgentApproval, shown: ApprovalGuard, pressedAt: Date) {
        guard canAnswer(approval, shown: shown, pressedAt: pressedAt), let waiter = waiters[approval.id] else { return }
        waiter.reply(["ok": true, "decision": "deny"])
        answered(approval, doing: nil, at: pressedAt)
    }

    /// Only for the one at the front, once the guard says so.
    private func canAnswer(_ approval: AgentApproval, shown: ApprovalGuard, pressedAt: Date) -> Bool {
        approvals.first?.id == approval.id && shown.accepts(approval.id, at: pressedAt)
    }

    /// Puts a session's oldest tool call at the front, for Review on its row.
    func bringForward(session id: String) {
        guard let index = approvals.firstIndex(where: { $0.sessionID == id }), index > 0 else { return }
        approvals.insert(approvals.remove(at: index), at: 0)
    }

    private func answered(_ approval: AgentApproval, doing: String?, at now: Date) {
        waiters[approval.id] = nil
        approvals.removeAll { $0.id == approval.id }
        let id = approval.sessionID
        if var memory = memories[id] {
            memory.answeredAt = now
            memory.asking = nil
            memory.phase = .working
            memory.turnStartedAt = memory.turnStartedAt ?? now
            memory.call = doing.map { Call(id: memory.call?.id, doing: $0, since: now) }
            memories[id] = memory
        }
        show(id, now: now)
        wakeForNext()
    }

    // MARK: Retiring

    /// Takes an approval down with no decision. The only reply here is one with nothing in it.
    private func retire(_ id: UUID) {
        waiters.removeValue(forKey: id)?.reply(["ok": true])
        approvals.removeAll { $0.id == id }
    }

    private func retireApprovals(ofSession id: String) {
        for approval in approvals where approval.sessionID == id { retire(approval.id) }
    }

    /// The hook has gone, or has been waiting so long that it must have. Claude Code may still be
    /// asking in its own window, so the session stays waiting until it's heard from.
    private func giveUp(on id: UUID, now: Date) {
        guard let approval = approvals.first(where: { $0.id == id }) else { return }
        retire(id)
        memories[approval.sessionID]?.asking = "Needs your permission"
        show(approval.sessionID, now: now)
    }

    private func clientWent(_ id: UUID) {
        giveUp(on: id, now: .now)
        wakeForNext()
    }

    /// Takes down whatever has run its time by `now`.
    func expire(now: Date = .now) {
        for (id, waiter) in waiters where waiter.deadline <= now { giveUp(on: id, now: now) }
        for session in sessions {
            if let expiry = expiry(of: session), expiry <= now { remove(session.id) }
        }
        endedAt = endedAt.filter { now.timeIntervalSince($0.value) < Self.endEcho }
        wakeForNext()
    }

    /// When a session leaves the list. Never while an approval of its waits.
    private func expiry(of session: AgentSession) -> Date? {
        guard !approvals.contains(where: { $0.sessionID == session.id }), let memory = memories[session.id] else { return nil }
        switch session.state {
        // Waiting with no approval here: nothing says when that's over, so it can't stay for long.
        case .ready, .done, .waiting: return memory.lastHeard.addingTimeInterval(Self.doneHiddenAfter)
        case .working: return memory.lastHeard.addingTimeInterval(Self.silentDroppedAfter)
        }
    }

    /// With the switch off nothing shows, and what's waiting goes back to Claude Code's own prompt.
    func settingChanged() {
        guard !AppSettings.shared.liveAgents else { return }
        for id in Array(waiters.keys) { retire(id) }
        sessions = []
        memories = [:]
        endedAt = [:]
        updateWaitingCount()
        wakeForNext()
    }

    private func remove(_ id: String) {
        sessions.removeAll { $0.id == id }
        memories[id] = nil
        updateWaitingCount()
    }

    /// Makes room: the session heard from longest ago that has no approval waiting.
    private func dropQuietest() {
        let quiet = sessions.filter { session in !approvals.contains { $0.sessionID == session.id } }
        let oldest = quiet.min { (memories[$0.id]?.lastHeard ?? .distantPast) < (memories[$1.id]?.lastHeard ?? .distantPast) }
        if let oldest { remove(oldest.id) }
    }

    /// One wake at the next time anything is due, not a poll: nothing runs until then, and nothing at all with nothing here.
    private func wakeForNext() {
        let next = (waiters.values.map(\.deadline) + sessions.compactMap(expiry(of:))).min()
        guard next != scheduledWake else { return }
        clock?.cancel()
        clock = nil
        scheduledWake = next
        guard let next else { return }
        clock = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(next.timeIntervalSinceNow, 0.01)))
            guard !Task.isCancelled else { return }
            self?.scheduledWake = nil
            self?.expire()
        }
    }

    // MARK: What it shows

    /// Works out what a session shows from what's known about it, and only changes it if that's different.
    private func show(_ id: String, now: Date) {
        guard let index = sessions.firstIndex(where: { $0.id == id }), let memory = memories[id] else { return }
        var session = sessions[index]
        if let approval = approvals.first(where: { $0.sessionID == id }) {
            session.state = .waiting(approval.asking)
        } else if let asking = memory.asking {
            session.state = .waiting(asking)
        } else {
            switch memory.phase {
            case .ready: session.state = .ready
            case .working: session.state = .working(memory.call?.doing)
            case .done(let date): session.state = .done(date)
            }
        }
        session.since = memory.call?.since ?? memory.turnStartedAt ?? session.since
        if sessions[index] != session { sessions[index] = session }
        updateWaitingCount()
    }

    private func updateWaitingCount() {
        let asking = sessions.filter { session in
            guard case .waiting = session.state else { return false }
            return !approvals.contains { $0.sessionID == session.id }
        }
        let count = approvals.count + asking.count
        if waitingCount != count { waitingCount = count }
    }

    /// For the list: what's waiting first, in the order the glance takes it, then what's working,
    /// then the rest, most recent first.
    var ordered: [AgentSession] {
        func rank(_ session: AgentSession) -> Int {
            switch session.state {
            case .waiting: 0
            case .working: 1
            case .ready, .done: 2
            }
        }
        func recency(_ session: AgentSession) -> Date {
            if case .done(let date) = session.state { return date }
            return session.since
        }
        let queue = approvals.map(\.sessionID)
        return sessions.sorted { first, second in
            if rank(first) != rank(second) { return rank(first) < rank(second) }
            if rank(first) == 0 {
                let places = (queue.firstIndex(of: first.id) ?? queue.count, queue.firstIndex(of: second.id) ?? queue.count)
                if places.0 != places.1 { return places.0 < places.1 }
            }
            if recency(first) != recency(second) { return recency(first) > recency(second) }
            return first.id < second.id
        }
    }

    /// Whether this session has an approval waiting, so its row has Review rather than Back.
    func hasApproval(forSession id: String) -> Bool {
        approvals.contains { $0.sessionID == id }
    }

    /// What `dynotch status` says: how many of each. What sessions are doing stays in the notch.
    var statusReport: [String: Int] {
        var counts = ["sessions": sessions.count, "approvals": approvals.count, "ready": 0, "working": 0, "waiting": 0, "done": 0]
        for session in sessions {
            switch session.state {
            case .ready: counts["ready", default: 0] += 1
            case .working: counts["working", default: 0] += 1
            case .waiting: counts["waiting", default: 0] += 1
            case .done: counts["done", default: 0] += 1
            }
        }
        return counts
    }

    // MARK: Snapshots

    func loadSample(sessions: [AgentSession], approvals: [AgentApproval] = [], isInert: Bool = false) {
        self.sessions = sessions
        self.approvals = approvals
        isSampleInert = isInert
        waitingCount = approvals.count
    }

    /// Back to nothing, between snapshot scenes.
    func clearSample() {
        loadSample(sessions: [])
    }
}
