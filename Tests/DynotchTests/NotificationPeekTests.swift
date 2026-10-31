import Foundation
import Testing
@testable import Dynotch

struct OneTimeCodeTests {
    @Test(arguments: [
        ("72975", "Your verification code is 482913", "482913"),
        ("22395", "123456 is your Instagram code", "123456"),
        ("+1 (415) 555-0199", "Your verification code is 482913", "482913"),
        ("+14155550199", "Your verification code is 482913", "482913"),
        ("+92 300 1234567", "Your OTP is 482913", "482913"),
    ])
    func aSendersNumberIsNotTheCode(sender: String, body: String, code: String) {
        #expect(OneTimeCode.find(title: sender, subtitle: "", body: body) == code)
    }

    @Test func aSendersNumberIsNotACodeForAMessageWithNone() {
        #expect(OneTimeCode.find(title: "72975", subtitle: "", body: "Your code expires soon") == nil)
    }

    @Test func aTitleCanSayWhatTheMessageIs() {
        #expect(OneTimeCode.find(title: "Verification code", subtitle: "", body: "482913") == "482913")
        #expect(OneTimeCode.find(title: "Acme verification", subtitle: "", body: "Use 482913 to continue") == "482913")
    }

    @Test func aSubjectLineCounts() {
        #expect(OneTimeCode.find(title: "Acme", subtitle: "Your login code is 482913", body: "Hi Sam, here it is.") == "482913")
    }

    @Test func aCodeInTheTitleCounts() {
        #expect(OneTimeCode.find(title: "482913 is your code", subtitle: "", body: "") == "482913")
    }

    @Test(arguments: [
        ("Your verification code is 482913. It expires in 10 minutes.", "482913"),
        ("G-482913 is your Google verification code.", "482913"),
        ("Your code: 482 913", "482913"),
        ("Your code: 482-913", "482913"),
        ("Use 7301 to sign in, your verification code", "7301"),
        ("OTP 12345678 for your bank", "12345678"),
        ("Login code for Acme\n\n9921", "9921"),
        ("Call 415-555-0199 if this wasn't you. Your code is 482913", "482913"),
        ("Your OTP for ₹5000 payment is 482913", "482913"),
        ("OTP for Rs 5000 at Daraz is 482913", "482913"),
        ("Your OTP for PKR 2500 transfer is 482913", "482913"),
        ("Your OTP for 5000 PKR is 482913", "482913"),
        ("Card ending 4821: your one-time code is 482913", "482913"),
        ("Sign in to pay ¥12000. Code 482913", "482913"),
        ("Your code for order #12345 is 9876", "9876"),
        ("OTP:482913", "482913"),
        ("code=482913", "482913"),
        ("Your code is #482913", "482913"),
        ("Your verification code is 2048", "2048"),
        ("Your PIN is 1987", "1987"),
        ("Your code is 4829-1337", "48291337"),
        ("Your code is 123-456-789", "123456789"),
        ("Your code is 12 34 56", "123456"),
        ("Sign-in: 482913", "482913"),
        ("Log-in 482913", "482913"),
        ("Your passkey is 482913", "482913"),
        ("Your authentication code: 482913", "482913"),
        ("Security code: 482913", "482913"),
        ("Access code 4821", "4821"),
        ("MFA 482913", "482913"),
        ("Your 2-step verification number is 482913", "482913"),
        ("Confirmation number 482913 for your login", "482913"),
        ("Your code (482913) expires soon", "482913"),
        ("Your code is 482913.", "482913"),
        ("Your code is 482913\n2 attempts left", "482913"),
        ("₨5000 will be charged. OTP 482913", "482913"),
        ("Ihr Bestätigungscode lautet 482913", "482913"),
        ("Ihr Einmalpasswort: 482913", "482913"),
        ("Ihr Code lautet 482913", "482913"),
        ("Votre code de vérification est 482913", "482913"),
        ("Tu código de verificación es 482913", "482913"),
        ("Seu código é 482913", "482913"),
        ("Il tuo codice è 482913", "482913"),
        ("Uw verificatiecode is 482913", "482913"),
        ("Din kod är 482913", "482913"),
        ("Twój kod weryfikacyjny to 482913", "482913"),
        ("Doğrulama kodunuz: 482913", "482913"),
        ("Ваш код подтверждения: 482913", "482913"),
        ("Ваш код: 482913", "482913"),
        ("رمز التحقق الخاص بك هو 482913", "482913"),
        ("आपका ओटीपी 482913 है", "482913"),
        ("آپ کا تصدیقی کوڈ 482913 ہے", "482913"),
        ("您的验证码是 482913", "482913"),
        ("您的验证码是482913", "482913"),
        ("認証コード: 482913", "482913"),
        ("인증번호 482913", "482913"),
        ("Your code is ٤٨٢٩١٣", "482913"),
        ("Your code is ４８２９１３", "482913"),
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
        "The zip code is 94103",
        "Use promo code SPRING on orders over 1000",
        "code freeze for ticket 4821 starts today",
        "the login bug is in PR 12345",
        "Verify a charge on card ending 4821",
        "Pin the doc for room 4012",
        "Log in to claim 2500 points",
        "Password reset? Call 800-555-1234",
        "Sign in opens at 1530",
        "Code sent to 0300 1234567",
        "We sent a code to 415 555 0199",
        "Your verification code went to +1 415 555 0199",
        "Xcode 1600 has finished installing",
        "Build failed with exit code 1234",
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
        #expect(notice.detail == "Login code")
        #expect(notice.actions.first?.kind == .copyCode("482913"))
    }

    @Test func aCodeInTheTitleStaysHiddenToo() {
        let notice = NotificationPeek.notice(for: entry("", title: "482913 is your code"), appName: "Messages", hideText: true, findsCodes: true)
        #expect(notice.text == "Messages")
        #expect(notice.detail == "Login code")
    }

    @Test func onACallACodeShowsWithItsTextHidden() {
        let notice = NotificationPeek.notice(for: entry("Your code is 482 913"), appName: "Messages", hideText: false,
                                             findsCodes: true, isQuiet: true)
        #expect(notice.detail == "Login code")
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
