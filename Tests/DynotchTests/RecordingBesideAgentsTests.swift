import Foundation
import Testing
@testable import Dynotch

/// A recording beside what scripts and Claude Code put in the notch. The recording keeps its dot and
/// its Stop, and what it pushes aside stays in reach.
@MainActor
@Suite(.serialized)
struct RecordingBesideAgentsTests {
    private let viewModel: NotchViewModel
    private let deploy = ScriptActivity(key: "deploy", percent: 40)
    private let toolCall = AgentApproval(sessionID: "s", project: "lantern", tool: "Bash", input: ["command": "swift build"])
    private let notice = LiveNotice(key: "download", symbol: "arrow.down.circle.fill", tint: .blue, text: "Downloaded")

    init() {
        SnapshotRenderer.useScratchDefaults()
        AppSettings.shared.liveAgents = true
        viewModel = NotchViewModel(geometry: NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                                           closedSize: CGSize(width: 186, height: 37), hasHardwareNotch: true))
    }

    /// The real center while a recording runs, past anything other suites left waiting.
    private func closed(scripts: [ScriptActivity] = [], approvals: [AgentApproval] = [], showing shown: LiveNotice? = nil) -> ClosedContent {
        ScreenRecorder.shared.loadSample(.recording(since: .now))
        ScriptActivityStore.shared.loadSample(scripts)
        AgentDeck.shared.loadSample(sessions: [], approvals: approvals)
        for _ in 0...NoticeQueue.mostWaiting { LiveActivityCenter.shared.dismissNotice() }
        if let shown { LiveActivityCenter.shared.post(shown, for: 5) }
        return LiveActivityCenter.shared.content
    }

    /// A tool call waiting while a recording runs, on the real center, so a glance rising keeps to it.
    private func waiting(_ phase: NotchViewModel.Phase) {
        ScreenRecorder.shared.loadSample(.recording(since: .now))
        AgentDeck.shared.loadSample(sessions: [], approvals: [toolCall])
        for _ in 0...NoticeQueue.mostWaiting { LiveActivityCenter.shared.dismissNotice() }
        viewModel.stage(phase: phase, activity: .recording)
    }

    private func tidy() {
        ScreenRecorder.shared.loadSample(.idle)
        ScriptActivityStore.shared.loadSample([])
        AgentDeck.shared.clearSample()
        for _ in 0...NoticeQueue.mostWaiting { LiveActivityCenter.shared.dismissNotice() }
    }

    @Test func aRecordingComesBeforeAScriptWhichStaysBeside() {
        defer { tidy() }
        let content = closed(scripts: [deploy])
        #expect(content.activity == .recording)
        #expect(content.secondary == .script(deploy))
    }

    @Test func theCountShowsBesideTheTime() {
        defer { tidy() }
        let content = closed(approvals: [toolCall])
        #expect(content.activity == .recording)
        #expect(content.secondary == .agentsWaiting(1))
    }

    /// There's one place beside a notice, and the dot in it is how the notch knows to keep Stop in reach.
    @Test func besideANoticeTheDotComesBeforeTheCount() {
        defer { tidy() }
        #expect(closed(approvals: [toolCall], showing: notice).secondary == .recording)
    }

    @Test func aToolCallWaitsForTheRecordingsGlance() {
        defer { tidy() }
        waiting(.glance)
        #expect(viewModel.glanceContent == .recording)
        #expect(viewModel.metrics.width < ApprovalGlance.width)
    }

    @Test func aClickStillBringsUpStop() {
        defer { tidy() }
        waiting(.closed)
        viewModel.activate()
        #expect(viewModel.phase == .glance)
        #expect(viewModel.glanceContent == .recording)
    }

    @Test func reviewBringsTheToolCallUp() {
        defer { tidy() }
        waiting(.open)
        viewModel.showApproval()
        #expect(viewModel.phase == .glance)
        #expect(viewModel.glanceContent == .approval(toolCall))
    }

    @Test func closingHandsTheGlanceBackToStop() {
        defer { tidy() }
        waiting(.open)
        viewModel.showApproval()
        viewModel.close()
        viewModel.setHovering(true)
        viewModel.glance()
        #expect(viewModel.glanceContent == .recording)
    }

    @Test func oneThatComesLaterWaitsAgain() {
        defer { tidy() }
        waiting(.open)
        viewModel.showApproval()
        AgentDeck.shared.clearSample()
        #expect(viewModel.glanceContent == .recording)
        AgentDeck.shared.loadSample(sessions: [], approvals: [toolCall])
        #expect(viewModel.glanceContent == .recording)
    }

    @Test func theRingAskedForStaysItsOwn() {
        viewModel.stage(phase: .glance, activity: .recording, showingUsage: true)
        #expect(viewModel.glanceContent == .usage)
    }

    @Test func statusSaysSo() {
        #expect(ClosedActivity.recording.statusName == "recording")
    }
}
