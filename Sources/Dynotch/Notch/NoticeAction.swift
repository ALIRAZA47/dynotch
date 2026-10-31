import AppKit

/// A button on a notice. Buttons only show in the glance, so a stray click on the notch can't join a
/// meeting or start an update.
struct NoticeAction: Equatable {
    enum Kind: Equatable {
        case openApp(bundleID: String)
        case openFile(URL)
        case reveal(URL)
        case openURL(URL)
        /// A one-time code, marked so clipboard managers leave it out of their history.
        case copyCode(String)
        case openTab(NotchTab)
        case installUpdate
        case showRecent
    }

    let title: String
    let kind: Kind

    /// Does what the button says, then gets the notice and the glance out of the way. From the recent
    /// list, the notice showing behind it may be another one entirely, so that stays.
    @MainActor
    func perform(in viewModel: NotchViewModel, fromRecent: Bool = false) {
        let center = LiveActivityCenter.shared
        switch kind {
        case .openApp(let bundleID):
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            }
        case .openFile(let url):
            FileActions.open(url)
        case .reveal(let url):
            FileActions.reveal([url])
        case .openURL(let url):
            NSWorkspace.shared.open(url)
        case .copyCode(let code):
            Self.copy(code)
        case .openTab(let tab):
            if !fromRecent { center.dismissNotice() }
            viewModel.open(tab: tab)
            return
        case .installUpdate:
            UpdateChecker.shared.installAvailableRelease()
        case .showRecent:
            if !fromRecent { center.dismissNotice() }
            viewModel.showRecent()
            return
        }
        if !fromRecent { center.dismissNotice() }
        viewModel.close()
    }

    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    @MainActor
    private static func copy(_ code: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        pasteboard.setData(Data(), forType: concealedType)
        LiveActivityCenter.shared.post(LiveNotice(key: "copied", symbol: "doc.on.clipboard.fill", tint: .white,
                                                  text: "Copied"), for: 1.6)
    }
}

extension Array where Element == NoticeAction {
    /// What's left for the recent list: a code is shown and forgotten, like the rest of a peek.
    var keptForLater: [NoticeAction] {
        filter {
            if case .copyCode = $0.kind { return false }
            return true
        }
    }

    /// A file the notice is about, which can be dragged out of the glance.
    var file: URL? {
        for action in self {
            if case .openFile(let url) = action.kind { return url }
        }
        return nil
    }
}
