import SwiftUI

extension SnapshotRenderer {
    /// A long command's notices and their way back: closed, in the glance, and beside a script's own button.
    static func terminalScenes() -> [Scene] {
        let iTerm = TerminalOrigin(program: "iTerm.app", sessionID: "w0t1p0:7E0D7E04-8FD6-4E87-A1F0-5B61A7A6AB7B",
                                   tty: "/dev/ttys003", folder: "/Users/you/api")
        let terminal = TerminalOrigin(program: "Apple_Terminal", tty: "/dev/ttys004", folder: "/Users/you/api")
        let failed = notice("Failed", symbol: "xmark.octagon.fill", tint: .red, detail: "make · 2m 14s", actions: [iTerm.action])
        let done = notice("Done", symbol: "checkmark.circle.fill", tint: .green, detail: "make · 2m 14s", actions: [iTerm.action])
        let longestTitle = notice("Failed", symbol: "xmark.octagon.fill", tint: .red, detail: "make · 2m 14s",
                                  actions: [terminal.action])
        let open = NoticeAction(title: "Open", kind: .openURL(URL(string: "https://example.com")!))
        let twoButtons = notice("Deployed", symbol: "checkmark.circle.fill", tint: .green, detail: "api · 2m 14s",
                                actions: [open, iTerm.action])
        // With DYNOTCH_LONG_COMMAND_DETAIL=full: the line gives way, not the button.
        let longDetail = notice("Failed", symbol: "xmark.octagon.fill", tint: .red,
                                detail: "make -j8 test-integration FILTER=notices VERBOSE=1 · 12m 40s", actions: [terminal.action])
        return [
            Scene(name: "terminal-1-failed-closed", phase: .closed, activity: .notice(failed)),
            Scene(name: "terminal-2-failed-glance", phase: .glance, activity: .notice(failed)),
            Scene(name: "terminal-3-done-glance", phase: .glance, activity: .notice(done)),
            Scene(name: "terminal-4-longest-title", phase: .glance, activity: .notice(longestTitle)),
            Scene(name: "terminal-5-two-buttons", phase: .glance, activity: .notice(twoButtons)),
            Scene(name: "terminal-6-long-detail", phase: .glance, activity: .notice(longDetail)),
        ]
    }

    private static func notice(_ text: String, symbol: String, tint: Color, detail: String, actions: [NoticeAction?]) -> LiveNotice {
        LiveNotice(key: "command", symbol: symbol, tint: tint, text: text, detail: detail, fromScript: true,
                   actions: actions.compactMap { $0 }, timing: .waits, recall: .whole)
    }
}
