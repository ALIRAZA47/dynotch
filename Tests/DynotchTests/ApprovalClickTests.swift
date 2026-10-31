import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Dynotch

/// A panel of Dynotch's own, parked far off screen. Nothing here reaches the real screen: the clicks
/// are events handed to this window alone.
private final class OffScreenPanel: NotchPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
}

/// The real glance in a real panel, clicked with synthesized events on the real Allow button.
@MainActor
private final class ClickHarness {
    let panel: OffScreenPanel
    let model: NotchViewModel
    private var number = 0
    private(set) var replies: [String] = []
    private let height: CGFloat = 420

    init() {
        _ = NSApplication.shared
        model = NotchViewModel(geometry: NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                                                       closedSize: CGSize(width: 185, height: 32), hasHardwareNotch: true))
        model.stage(phase: .glance, activity: .idle)
        panel = OffScreenPanel(contentRect: NSRect(x: -30_000, y: -30_000, width: 800, height: height))
        panel.onPress = { [model] event in model.notePress(event) }
        panel.contentView = NotchHostingView(rootView: NotchRootView(viewModel: model))
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        wait(0.4)
    }

    func close() {
        panel.orderOut(nil)
    }

    func wait(_ seconds: TimeInterval) {
        RunLoop.main.run(until: .now.addingTimeInterval(seconds))
    }

    private var allow: NSPoint {
        NSPoint(x: 400 + 280 - 14 - 38, y: height - model.metrics.height + 11 + 14)
    }

    func press() { mouse(.leftMouseDown) }
    func release() { mouse(.leftMouseUp) }

    func click() {
        press()
        wait(0.03)
        release()
        wait(0.05)
    }

    /// As quick as a tap on a trackpad: nothing runs between the two.
    func tap() {
        press()
        release()
        wait(0.05)
    }

    private func mouse(_ type: NSEvent.EventType) {
        number += 1
        let event = NSEvent.mouseEvent(with: type, location: allow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: panel.windowNumber, context: nil, eventNumber: number, clickCount: 1,
                                       pressure: type == .leftMouseDown ? 1 : 0)
        panel.sendEvent(event!)
    }

    func hold(_ command: String) throws {
        AgentDeck.shared.apply(try request("PermissionRequest", command)) { [weak self] answer in
            if let decision = answer["decision"] as? String { self?.replies.append("\(command) \(decision)") }
        }
    }

    func finish(_ command: String) throws {
        AgentDeck.shared.apply(try request("PostToolUse", command)) { _ in }
    }

    private func request(_ event: String, _ command: String) throws -> SocketRequest {
        try #require(SocketRequest(line: JSONSerialization.data(withJSONObject: [
            "op": "hook", "hook_event_name": event, "session_id": "session-\(command)", "cwd": "/a/\(command)", "tool_name": "Bash",
            "tool_input": ["command": command],
        ] as [String: Any])))
    }
}

/// Real events, because the bugs here live between the mouse and the deck: a press that spans the
/// time the buttons sleep, or a release that lands on a different approval from the press.
@MainActor
@Suite(.serialized)
struct ApprovalClickTests {
    private func harness() -> ClickHarness {
        SnapshotRenderer.useScratchDefaults()
        AppSettings.shared.liveAgents = true
        return ClickHarness()
    }

    @Test func aClickWhileItSleepsDoesNothingAndOneAfterAllows() throws {
        let harness = harness()
        defer { harness.close() }
        try harness.hold("one")
        harness.wait(0.1)
        harness.click()
        #expect(harness.replies.isEmpty)
        harness.wait(0.8)
        harness.click()
        #expect(harness.replies == ["one allow"])
    }

    @Test func aTapAsQuickAsATrackpadsCounts() throws {
        let harness = harness()
        defer { harness.close() }
        try harness.hold("tapped")
        harness.wait(0.9)
        harness.tap()
        #expect(harness.replies == ["tapped allow"])
    }

    @Test func aPressThatBeganWhileItSleptDoesntCountWhenLetGoLater() throws {
        let harness = harness()
        defer { harness.close() }
        try harness.hold("two")
        harness.wait(0.1)
        harness.press()
        harness.wait(0.9)
        harness.release()
        harness.wait(0.05)
        #expect(harness.replies.isEmpty)
        try harness.finish("two")
    }

    @Test func aPressOnOneApprovalDoesntAllowTheNext() throws {
        let harness = harness()
        defer { harness.close() }
        try harness.hold("three")
        try harness.hold("four")
        harness.wait(0.9)
        harness.press()
        harness.wait(0.05)
        try harness.finish("three")
        harness.wait(1.5)
        harness.release()
        harness.wait(0.05)
        #expect(harness.replies.isEmpty)
        #expect(AgentDeck.shared.approvals.count == 1)
        try harness.finish("four")
    }

    @Test func aDoubleClickDoesntAllowTheOneBehind() throws {
        let harness = harness()
        defer { harness.close() }
        try harness.hold("five")
        try harness.hold("six")
        harness.wait(0.9)
        harness.click()
        harness.click()
        #expect(harness.replies == ["five allow"])
        try harness.finish("six")
    }

    /// Long enough for a double click, and not long enough to see it's a different one.
    @Test func thePointerRestingOnAllowCantTakeTheNextOneUnseen() throws {
        let harness = harness()
        defer { harness.close() }
        try harness.hold("seven")
        try harness.hold("eight")
        harness.wait(0.9)
        try harness.finish("seven")
        harness.wait(0.7)
        harness.click()
        #expect(harness.replies.isEmpty)
        harness.wait(0.8)
        harness.click()
        #expect(harness.replies == ["eight allow"])
    }

    @Test func comingBackStartsTheWaitAgain() throws {
        let harness = harness()
        defer { harness.close() }
        try harness.hold("nine")
        harness.wait(0.9)
        harness.model.stage(phase: .closed, activity: .idle)
        harness.wait(0.3)
        harness.model.stage(phase: .glance, activity: .idle)
        harness.wait(0.1)
        harness.click()
        #expect(harness.replies.isEmpty)
        harness.wait(0.8)
        harness.click()
        #expect(harness.replies == ["nine allow"])
    }
}
