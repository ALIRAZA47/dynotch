import DynotchShared
import SwiftUI

extension SnapshotRenderer {
    /// Orbit's Agents section, the glance and the command field, with sample sessions, runs and
    /// notices only. Agents and the command field in both themes and at the smallest and largest
    /// open sizes; the glance hangs on black, so it's dark only.
    static func orbitAgentGlanceCommandScenes() -> [Scene] {
        let now = Date.now
        let small = CGSize(width: 640, height: 300)
        let large = CGSize(width: 880, height: 460)
        let light = NotchTheme(isDark: false)

        let ghostty = TerminalOrigin(program: "ghostty")
        let iTerm = TerminalOrigin(program: "iTerm.app")
        let desktop = TerminalOrigin(bundleID: "com.anthropic.claudefordesktop")
        let asking = AgentSession(id: "b", project: "dynotch", state: .waiting("Wants to run: swift build"),
                                  since: now.addingTimeInterval(-42), origin: ghostty)
        let building = AgentSession(id: "a", project: "ratline-cli", state: .working("Editing nginx.go"),
                                    since: now.addingTimeInterval(-6 * 60), origin: desktop)
        let done = AgentSession(id: "c", project: "docs", state: .done(now.addingTimeInterval(-9 * 60)), since: now, origin: iTerm)
        let sessions = [asking, building, done]
        let crowd = sessions + (1...8).map {
            AgentSession(id: "d\($0)", project: "a-project-with-rather-a-long-name-\($0)",
                         state: .done(now.addingTimeInterval(TimeInterval(-600 * $0))), since: now, origin: iTerm)
        }
        let approval = AgentApproval(sessionID: "b", project: "dynotch", tool: "Bash",
                                     input: ["command": "swift build -c release --product Dynotch"],
                                     folder: "/Users/sample/Desktop/FunProjects/dynotch", origin: ghostty)
        let subagent = AgentApproval(sessionID: "a", project: "ratline-cli", tool: "Edit", input: [
            "file_path": "/Users/sample/Desktop/FunProjects/ratline-cli/internal/system/nginx.go",
            "old_string": "listen 80;", "new_string": "listen 80;\n    listen [::]:80;",
        ], isFromSubagent: true)

        let url = URL(string: "https://github.com/acme/app/actions/runs/1")
        let run = CIRun(id: 9, repository: "acme/app", branch: "feature/orbit", workflow: "Build", url: url, seconds: 134,
                        total: 3, finished: 1)
        let limits: @MainActor () -> Void = {
            UsageStore.shared.loadSample(fiveHour: UsageWindow(percent: 41, resetsAt: now.addingTimeInterval(3 * 3600 + 19 * 60)),
                                         sevenDay: UsageWindow(percent: 63, resetsAt: now.addingTimeInterval(4 * 24 * 3600)),
                                         receivedAt: now.addingTimeInterval(-120))
        }
        let agents: @MainActor () -> Void = {
            AgentDeck.shared.loadSample(sessions: sessions, approvals: [approval])
            CIMonitor.shared.loadSample(run, reviewCount: 2)
            limits()
        }
        let quiet: @MainActor () -> Void = {
            AgentDeck.shared.loadSample(sessions: [building, done])
            limits()
        }

        let link = URL(string: "https://example.com")!
        let downloaded = LiveNotice(key: "download", symbol: "arrow.down.circle.fill", tint: DownloadMonitor.tint,
                                    text: "Downloaded", detail: "Keynote draft.key",
                                    actions: [NoticeAction(title: "Open", kind: .openURL(link)),
                                              NoticeAction(title: "Show", kind: .openURL(link))])
        let meeting = LiveNotice(key: "event", symbol: "calendar", tint: .orange, text: "in 5m", detail: "Design review",
                                 actions: [NoticeAction(title: "Join", kind: .openURL(URL(string: "https://meet.google.com")!))])
        let recents: @MainActor () -> Void = {
            LiveActivityCenter.shared.loadSample(recents: [
                RecentNotice(id: UUID(), symbol: "checkmark.circle.fill", tint: .green, title: "Deployed", detail: "api · 2m 14s",
                             date: now.addingTimeInterval(-4 * 60), actions: [NoticeAction(title: "Open", kind: .openURL(link))]),
                RecentNotice(id: UUID(), symbol: "message.fill", tint: .green, title: "Messages", detail: nil,
                             date: now.addingTimeInterval(-18 * 60), actions: []),
                RecentNotice(id: UUID(), symbol: "arrow.down.circle.fill", tint: DownloadMonitor.tint, title: "Downloaded",
                             detail: "Keynote draft.key", date: now.addingTimeInterval(-62 * 60), actions: []),
            ], unseen: 3)
        }

        return [
            // Agents
            Scene(name: "o-agents-dark", phase: .open, tab: .agents, setUp: agents),
            Scene(name: "o-agents-light", phase: .open, tab: .agents, theme: light, setUp: agents),
            Scene(name: "o-agents-small-dark", phase: .open, tab: .agents, openSize: small, setUp: agents),
            Scene(name: "o-agents-small-light", phase: .open, tab: .agents, theme: light, openSize: small, setUp: agents),
            Scene(name: "o-agents-large-dark", phase: .open, tab: .agents, openSize: large, setUp: agents),
            Scene(name: "o-agents-large-light", phase: .open, tab: .agents, theme: light, openSize: large, setUp: agents),
            Scene(name: "o-agents-crowded-dark", phase: .open, tab: .agents, setUp: {
                AgentDeck.shared.loadSample(sessions: crowd, approvals: [approval, subagent])
                limits()
            }),
            Scene(name: "o-agents-quiet-light", phase: .open, tab: .agents, theme: light, setUp: quiet),
            // The glance
            Scene(name: "o-glance-approval", phase: .glance, setUp: { AgentDeck.shared.loadSample(sessions: sessions, approvals: [approval]) }),
            Scene(name: "o-glance-approval-inert", phase: .glance,
                  setUp: { AgentDeck.shared.loadSample(sessions: sessions, approvals: [approval], isInert: true) }),
            Scene(name: "o-glance-approval-several", phase: .glance,
                  setUp: { AgentDeck.shared.loadSample(sessions: sessions, approvals: [subagent, approval]) }),
            Scene(name: "o-glance-music", phase: .glance, activity: .music),
            Scene(name: "o-glance-pomodoro", phase: .glance, activity: .timer),
            Scene(name: "o-glance-stopwatch", phase: .glance, activity: .stopwatch),
            Scene(name: "o-glance-download", phase: .glance, activity: .download),
            Scene(name: "o-glance-event", phase: .glance, hasTrack: false),
            Scene(name: "o-glance-notice-buttons", phase: .glance, activity: .notice(downloaded)),
            Scene(name: "o-glance-join", phase: .glance, activity: .notice(meeting)),
            Scene(name: "o-glance-recent", phase: .glance, showingRecent: true, setUp: recents),
            Scene(name: "o-glance-today", phase: .glance, hasTrack: false, setUp: {
                let lunch = CalendarService.shared.events.filter { $0.title == "Lunch with Sam" }
                CalendarService.shared.loadSample(events: lunch, reminders: CalendarService.shared.reminders)
                recents()
                CIMonitor.shared.loadSample(nil, reviewCount: 2)
            }),
            Scene(name: "o-glance-ci", phase: .glance, activity: .ci(run), setUp: { CIMonitor.shared.loadSample(run, reviewCount: 2) }),
            // The command field
            Scene(name: "o-command-empty-dark", phase: .open, command: ""),
            Scene(name: "o-command-empty-light", phase: .open, theme: light, command: ""),
            Scene(name: "o-command-tea-dark", phase: .open, command: "tea 4m"),
            Scene(name: "o-command-tea-light", phase: .open, theme: light, command: "tea 4m"),
            Scene(name: "o-command-volume-dark", phase: .open, command: "vol 30"),
            Scene(name: "o-command-nothing-light", phase: .open, theme: light, command: "zzqx"),
            Scene(name: "o-command-learned-dark", phase: .open, command: "", setUp: {
                for (id, uses) in [("stopwatch", 4), ("tab-tray", 3), ("awake", 2)] {
                    for _ in 0..<uses { CommandHistory.record(id) }
                }
            }),
            Scene(name: "o-command-small-dark", phase: .open, command: "", openSize: small),
            Scene(name: "o-command-small-light", phase: .open, theme: light, command: "tea 4m", openSize: small),
            Scene(name: "o-command-large-dark", phase: .open, command: "tea 4m", openSize: large),
            Scene(name: "o-command-large-light", phase: .open, theme: light, command: "", openSize: large),
        ]
    }
}
