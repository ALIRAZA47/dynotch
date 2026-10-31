import Foundation
import Testing
@testable import Dynotch

struct OneTimeCodeTests {
    @Test(arguments: [
        ("Your verification code is 482913. It expires in 10 minutes.", "482913"),
        ("G-482913 is your Google verification code.", "482913"),
        ("Your code: 482 913", "482913"),
        ("Your code: 482-913", "482913"),
        ("Use 7301 to sign in", "7301"),
        ("OTP 12345678 for your bank", "12345678"),
        ("Login code for Acme\n\n9921", "9921"),
    ])
    func findsTheCode(text: String, code: String) {
        #expect(OneTimeCode.find(in: text) == code)
    }

    @Test(arguments: [
        "Running ten minutes late, start the review without me",
        "Your order 482913 has shipped",
        "Lunch at 12:30? Table for 4",
        "The barcode is 482913",
        "Your code expires at 10:30",
        "That costs $1250 with the promo code",
        "Your password was changed in 2026",
        "Your code SAVE2024 is ready",
        "Up 2500% since the code change",
    ])
    func leavesEverythingElseAlone(text: String) {
        #expect(OneTimeCode.find(in: text) == nil)
    }
}

struct NotificationPeekTests {
    private func entry(_ body: String, title: String = "Bank") -> NotificationReader.Entry {
        NotificationReader.Entry(bundleID: "com.apple.MobileSMS", title: title, subtitle: "", body: body)
    }

    @Test func aPeekOpensItsApp() {
        let notice = NotificationPeek.notice(for: entry("See you at six"), appName: "Messages", hideText: false, findsCodes: true)
        #expect(notice.actions == [NoticeAction(title: "Open", kind: .openApp(bundleID: "com.apple.MobileSMS"))])
        #expect(notice.timing == .waits)
    }

    @Test func aPeekIsRememberedByItsAppAlone() {
        let notice = NotificationPeek.notice(for: entry("See you at six"), appName: "Messages", hideText: false)
        #expect(notice.recall == .name("Messages"))
    }

    @Test func aCodeComesFirstAndDoesntWait() {
        let notice = NotificationPeek.notice(for: entry("Your code is 482 913"), appName: "Messages", hideText: false, findsCodes: true)
        #expect(notice.actions.first?.kind == .copyCode("482913"))
        #expect(notice.timing == .always)
    }

    @Test func codesCanBeTurnedOff() {
        let notice = NotificationPeek.notice(for: entry("Your code is 482 913"), appName: "Messages", hideText: false, findsCodes: false)
        #expect(notice.actions.count == 1)
    }

    @Test func aHiddenPeekKeepsItsCodeOffTheScreenButCanStillCopyIt() {
        let notice = NotificationPeek.notice(for: entry("Your code is 482 913"), appName: "Messages", hideText: true, findsCodes: true)
        #expect(notice.detail == "Messages")
        #expect(notice.actions.first?.kind == .copyCode("482913"))
    }

    @Test func onACallACodeShowsWithItsTextHidden() {
        let notice = NotificationPeek.notice(for: entry("Your code is 482 913"), appName: "Messages", hideText: false,
                                             findsCodes: true, isQuiet: true)
        #expect(notice.detail == "Messages")
        #expect(notice.timing == .always)
    }

    @Test func aPeekWaitingOutACallKeepsItsText() {
        let notice = NotificationPeek.notice(for: entry("See you at six"), appName: "Messages", hideText: false,
                                             findsCodes: true, isQuiet: true)
        #expect(notice.detail == "See you at six")
        #expect(notice.timing == .waits)
    }

    @Test func aCodeIsNotKeptForLater() {
        let actions = [NoticeAction(title: "Copy Code", kind: .copyCode("482913")),
                       NoticeAction(title: "Open", kind: .openApp(bundleID: "com.apple.MobileSMS"))]
        #expect(actions.keptForLater.map(\.title) == ["Open"])
    }

    @Test func differentSendersTakeTurnsAndTheSameOneUpdatesInPlace() {
        let anna = NotificationPeek.notice(for: entry("Hi", title: "Anna"), appName: "Messages", hideText: false)
        let annaAgain = NotificationPeek.notice(for: entry("Hello?", title: "Anna"), appName: "Messages", hideText: false)
        let sam = NotificationPeek.notice(for: entry("Hi", title: "Sam"), appName: "Messages", hideText: false)
        #expect(anna.key == annaAgain.key)
        #expect(anna.key != sam.key)
    }

    @Test func aDigestCountsByAppWithTheMostFirst() {
        let notice = NotificationPeek.digest(of: ["Mail": 3, "Slack": 8, "Messages": 1], during: "Work")
        #expect(notice.text == "12")
        #expect(notice.detail == "While you were in Work: Slack 8, Mail 3, Messages 1")
    }

    @Test func aDigestSaysNothingOfWhatTheMessagesSaid() {
        let notice = NotificationPeek.digest(of: ["Messages": 1], during: "Work")
        #expect(notice.recall == .whole)
        #expect(notice.detail == "While you were in Work: Messages 1")
    }
}

@MainActor
@Suite(.serialized)
struct RecentNoticesTests {
    private let center = LiveActivityCenter.shared

    init() {
        center.loadSample(recents: [], unseen: 0)
    }

    private func notice(_ text: String, recall: LiveNotice.Recall, actions: [NoticeAction] = []) -> LiveNotice {
        LiveNotice(key: text, symbol: "bell", tint: .white, text: text, detail: "It said this", actions: actions, recall: recall)
    }

    @Test func mostNoticesAreNotKept() {
        center.remember(notice("Muted", recall: .nothing))
        #expect(!center.recents.contains { $0.title == "Muted" })
    }

    @Test func aWholeNoticeKeepsItsWords() {
        center.remember(notice("Downloaded", recall: .whole))
        #expect(center.recents.first?.title == "Downloaded")
        #expect(center.recents.first?.detail == "It said this")
    }

    @Test func aNotificationKeepsOnlyItsAppsName() {
        center.remember(notice("Anna", recall: .name("Messages")))
        #expect(center.recents.first?.title == "Messages")
        #expect(center.recents.first?.detail == nil)
    }

    @Test func aRunFromOneAppIsOneLine() {
        for _ in 0..<3 { center.remember(notice("Anna", recall: .name("Slack"))) }
        #expect(center.recents.first?.count == 3)
    }

    @Test func aCodeDoesNotStay() {
        center.remember(notice("Bank", recall: .name("Messages"), actions: [NoticeAction(title: "Copy Code", kind: .copyCode("482913"))]))
        #expect(center.recents.first?.actions.isEmpty == true)
    }

    @Test func onlyTheLastFewAreKept() {
        for index in 0..<30 { center.remember(notice("n\(index)", recall: .whole)) }
        #expect(center.recents.count == LiveActivityCenter.mostRecents)
        #expect(center.recents.first?.title == "n29")
        #expect(center.unseenRecents == LiveActivityCenter.mostRecents)
    }
}

@MainActor
struct ScriptButtonTests {
    @Test func anHttpsLinkMakesAButton() {
        let button = URLCommands.button(title: "Open", url: "https://example.com/pr/1")
        #expect(button?.kind == .openURL(URL(string: "https://example.com/pr/1")!))
    }

    @Test(arguments: ["http://example.com", "file:///etc/hosts", "dynotch://close", "javascript:alert(1)", "ssh://host", ""])
    func nothingElseDoes(url: String) {
        #expect(URLCommands.button(title: "Open", url: url) == nil)
    }

    @Test func aButtonNeedsATitle() {
        #expect(URLCommands.button(title: "", url: "https://example.com") == nil)
        #expect(URLCommands.button(title: nil, url: "https://example.com") == nil)
    }

    @Test func aLongTitleIsCut() {
        let button = URLCommands.button(title: String(repeating: "x", count: 40), url: "https://example.com")
        #expect(button?.title.count == 16)
    }
}
