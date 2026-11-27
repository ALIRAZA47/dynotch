import AppKit
import Security

/// One copy of Dynotch at a time. Two would each draw a notch, take the volume keys, listen on the
/// same socket and write the same Tray, notes and clipboard files; that happens when a copy opened
/// from somewhere else runs beside the one that opens at login. The copy opened last is the one
/// that stays: it asks older ones to quit, and a copy that sees a newer one open quits.
@MainActor
enum SingleCopy {
    private static var observer: NSObjectProtocol?

    /// When a copy started, and its process ID to settle two that started in the same instant.
    struct Start: Equatable {
        var date: Date?
        var pid: pid_t

        /// Whether this copy started before `other`, so it's the one that gives way.
        func isOlder(than other: Start) -> Bool {
            let mine = date ?? .distantPast, theirs = other.date ?? .distantPast
            return mine != theirs ? mine < theirs : pid < other.pid
        }
    }

    /// Whether `app` is signed as this copy is. Anything can carry Dynotch's bundle identifier, and
    /// this copy only gives way to the real thing. An unsigned build of this one has nothing to go
    /// by, and takes the identifier's word.
    private static func isDynotch(_ app: NSRunningApplication) -> Bool {
        guard let requirement = UpdateInstaller.ownRequirement() else { return true }
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: app.processIdentifier] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// False if a newer copy is already running and this one should quit without starting anything.
    static func claim() -> Bool {
        // A bare build has no bundle, and nothing to tell its copies by.
        guard let id = Bundle.main.bundleIdentifier else { return true }
        let me = NSRunningApplication.current
        let mine = Start(date: me.launchDate, pid: me.processIdentifier)
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != me.processIdentifier && !$0.isTerminated }
        if others.contains(where: { mine.isOlder(than: Start(date: $0.launchDate, pid: $0.processIdentifier)) && isDynotch($0) }) {
            return false
        }
        // Older copies quit the way the menu's Quit does, so a recording gets finished. Wait a
        // moment for them, so two copies don't hold the same files; one that's slow is left to it.
        for other in others { other.terminate() }
        let deadline = Date.now.addingTimeInterval(3)
        while others.contains(where: { !$0.isTerminated }), Date.now < deadline {
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.05))
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == id, app.processIdentifier != mine.pid,
                  mine.isOlder(than: Start(date: app.launchDate, pid: app.processIdentifier)) else { return }
            MainActor.assumeIsolated {
                if isDynotch(app) { NSApp.terminate(nil) }
            }
        }
        return true
    }
}
