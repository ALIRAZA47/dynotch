import AppKit
import Foundation
import Testing
@testable import Dynotch

struct TranslationRequestTests {
    private let english = Locale.Language(identifier: "en")

    private func read(_ text: String) -> TranslationRequest { TranslationRequest(text, system: english) }

    @Test func thePagesExample() {
        let request = read("hola to english")
        #expect(request.text == "hola")
        #expect(request.source == nil)
        #expect(request.target.languageCode == "en")
        #expect(request.targetName == "English")
    }

    @Test func aSourceCanBeNamed() {
        let request = read("chat from french to english")
        #expect(request.text == "chat")
        #expect(request.source?.languageCode == "fr")
    }

    @Test func noLanguageMeansTheMacsOwn() {
        let request = read("bonjour")
        #expect(request.text == "bonjour")
        #expect(request.targetName == "English")
    }

    @Test func aToThatNamesNoLanguageIsPartOfTheText() {
        #expect(read("how to swim").text == "how to swim")
        #expect(read("how to swim").targetName == "English")
        #expect(read("go to klingon").text == "go to klingon")
    }

    @Test func theLastToCounts() {
        let request = read("how to swim to french")
        #expect(request.text == "how to swim")
        #expect(request.targetName == "French")
    }

    @Test func languagesInTwoWords() {
        #expect(read("hello to traditional chinese").target.script?.identifier == "Hant")
        #expect(read("hello to chinese").targetName == "Chinese")
        #expect(read("well to do to traditional chinese").text == "well to do")
    }

    @Test func caseStaysInTheTextAndGoesFromTheLanguage() {
        let request = read("Hola Amigo TO ENGLISH")
        #expect(request.text == "Hola Amigo")
        #expect(request.targetName == "English")
    }

    @Test func aFromThatNamesNoLanguageIsPartOfTheText() {
        #expect(read("a word from klingon to french").text == "a word from klingon")
        #expect(read("a word from klingon to french").source == nil)
    }

    @Test func aLanguageMacOSCantDoStillGetsAsked() {
        #expect(read("hello to urdu").targetName == "Urdu")
    }

    @Test func namesForLanguages() {
        #expect(TranslationRequest.name(of: Locale.Language(identifier: "es-MX")) == "Spanish")
        #expect(TranslationRequest.name(of: Locale.Language(identifier: "pa")) == "Punjabi")
    }

    /// Only Natural Language's model, which runs on the Mac.
    @Test func theLanguageOfWhatsTyped() {
        #expect(OnDeviceText.language(of: "bonjour tout le monde")?.languageCode == "fr")
        #expect(OnDeviceText.language(of: "Guten Morgen, wie geht es dir?")?.languageCode == "de")
        #expect(OnDeviceText.language(of: "") == nil)
    }
}

/// What the real answers do before they reach the frameworks, on any macOS, with no languages
/// installed and no Apple Intelligence, as on CI's Mac. Nothing here starts a session or a model.
struct OnDeviceTextTests {
    private let english = Locale.Language(identifier: "en")
    private let spanish = Locale.Language(identifier: "es")

    @Test func beforeMacOS26NeitherRuns() async {
        let translation = await OnDeviceText.translate("hola", from: spanish, to: english, name: "English", isAvailable: false)
        #expect(translation == .failure(.needsNewerMacOS))
        #expect(await OnDeviceText.summarize("Some text.", isAvailable: false) == .failure(.needsNewerMacOS))
    }

    @Test func theSameLanguageIsNoTranslation() async {
        guard OnDeviceText.isAvailable else { return }
        #expect(await OnDeviceText.translate("hello", from: english, to: english, name: "English") == .failure(.alreadyIn("English")))
        let regional = Locale.Language(identifier: "en-GB")
        #expect(await OnDeviceText.translate("hello", from: regional, to: english, name: "English") == .failure(.alreadyIn("English")))
    }

    @Test func nothingToGoOnIsNoLanguage() async {
        guard OnDeviceText.isAvailable else { return }
        #expect(await OnDeviceText.translate("", from: nil, to: english, name: "English") == .failure(.unknownLanguage))
    }

    @Test func whatMacOSSaysOfTheLanguages() {
        guard #available(macOS 26, *) else { return }
        #expect(OnDeviceText.failure(for: .installed, from: spanish, to: "English", knowsTarget: true) == nil)
        #expect(OnDeviceText.failure(for: .supported, from: spanish, to: "English", knowsTarget: true) == .notInstalled("Spanish to English"))
        #expect(OnDeviceText.failure(for: .unsupported, from: spanish, to: "Urdu", knowsTarget: false) == .unsupported("Urdu"))
        #expect(OnDeviceText.failure(for: .unsupported, from: Locale.Language(identifier: "ur"), to: "English", knowsTarget: true)
            == .unsupported("Urdu"))
    }

    @Test func whatMacOSSaysOfTheModel() {
        guard #available(macOS 26, *) else { return }
        #expect(OnDeviceText.failure(for: .available) == nil)
        #expect(OnDeviceText.failure(for: .unavailable(.appleIntelligenceNotEnabled)) == .appleIntelligenceOff)
        #expect(OnDeviceText.failure(for: .unavailable(.modelNotReady)) == .modelNotReady)
        #expect(OnDeviceText.failure(for: .unavailable(.deviceNotEligible)) == .deviceNotEligible)
    }

    // MARK: Text files

    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dynotch-\(UUID().uuidString)-\(name)")
        try data.write(to: url)
        return url
    }

    @Test func aTextFileIsRead() async throws {
        let url = try file("note.txt", Data("Bonjour tout le monde".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(await FileActions.text(of: url) == "Bonjour tout le monde")
    }

    @Test func anEncodingThatSaysSoIsRead() async throws {
        let url = try file("note.txt", try #require("Grüße".data(using: .utf16)))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(await FileActions.text(of: url) == "Grüße")
    }

    @Test func aLargeOrMissingFileIsLeftAlone() async throws {
        let url = try file("large.txt", Data(repeating: 97, count: 4_000_001))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(await FileActions.text(of: url) == nil)
        #expect(await FileActions.text(of: url.appendingPathExtension("gone")) == nil)
    }

    @MainActor
    @Test func whichFilesAreText() {
        #expect(FileActions.isText(URL(fileURLWithPath: "/tmp/notes.txt")))
        #expect(FileActions.isText(URL(fileURLWithPath: "/tmp/notes.md")))
        #expect(!FileActions.isText(URL(fileURLWithPath: "/tmp/photo.png")))
        #expect(!FileActions.isText(URL(fileURLWithPath: "/tmp/report.pdf")))
    }
}

/// With a stand-in for the Mac and a pasteboard of their own.
@MainActor
@Suite(.serialized)
final class TextActionsTests {
    private let pasteboard = NSPasteboard(name: .init("app.dynotch.text-actions-tests"))
    private var notices: [LiveNotice] = []

    /// What was asked of the stand-in.
    private final class Asked: @unchecked Sendable {
        var texts: [String] = []
        var sources: [Locale.Language?] = []
    }

    private let asked = Asked()

    init() {
        SnapshotRenderer.useScratchDefaults()
        pasteboard.clearContents()
        pasteboard.setString("what was there", forType: .string)
    }

    deinit {
        pasteboard.releaseGlobally()
    }

    private var notify: TextActions.Notify {
        { [unowned self] notice, _ in notices.append(notice) }
    }

    private func system(_ answer: Result<String, OnDeviceText.Failure>) -> OnDeviceText.System {
        let asked = asked
        return OnDeviceText.System(translate: { text, source, _, _ in
            asked.texts.append(text)
            asked.sources.append(source)
            return answer
        }, summarize: { text in
            asked.texts.append(text)
            return answer
        })
    }

    private var clipboard: String? { pasteboard.string(forType: .string) }
    private let request = TranslationRequest("hola to english")

    // MARK: Translate

    @Test func whatsTypedComesBackInTheNotice() async {
        await TextActions.translate(request, showsResult: true, to: pasteboard, system: system(.success("hello")), notify: notify)
        #expect(clipboard == "hello")
        #expect(notices.last == TextActions.copied("hello"))
    }

    /// A clip or a file's text may be anything, so it stays off the screen.
    @Test func aClipsTranslationStaysOffTheNotch() async {
        await TextActions.translate(request, showsResult: false, to: pasteboard, system: system(.success("a secret")), notify: notify)
        #expect(clipboard == "a secret")
        let notice = notices.last
        #expect(notice?.text == "Copied")
        #expect(notice?.detail == "In English")
        #expect(notice?.detail?.contains("secret") == false)
        #expect(notice?.recall == LiveNotice.Recall.nothing)
    }

    @Test func aNamedSourceGoesAlong() async {
        await TextActions.translate(TranslationRequest("chat from french to english"), showsResult: true, to: pasteboard,
                                    system: system(.success("cat")), notify: notify)
        #expect(asked.sources.first??.languageCode == "fr")
    }

    @Test func aVeryLongTextIsCutAndItSaysSo() async {
        let long = TranslationRequest(text: String(repeating: "a", count: TextActions.longestTranslation + 10), source: nil, target: ("French", "fr"))
        await TextActions.translate(long, showsResult: false, to: pasteboard, system: system(.success("b")), notify: notify)
        #expect(asked.texts.first?.count == TextActions.longestTranslation)
        #expect(notices.last?.detail == "The start of it, in French")
    }

    @Test(arguments: [
        (OnDeviceText.Failure.notInstalled("Spanish to English"), "Download Spanish to English", true),
        (.unsupported("Urdu"), "macOS can't translate Urdu", false),
        (.alreadyIn("English"), "That's already in English", false),
        (.unknownLanguage, "Couldn't tell what language that is", false),
        (.needsNewerMacOS, "This needs macOS 26", false),
        (.failed, "Something went wrong on the Mac", false),
    ])
    func whatCantBeDoneIsSaidAndTheClipboardStays(failure: OnDeviceText.Failure, message: String, hasFix: Bool) async {
        await TextActions.translate(request, showsResult: true, to: pasteboard, system: system(.failure(failure)), notify: notify)
        #expect(clipboard == "what was there")
        #expect(notices.last?.text == "Can't translate")
        #expect(notices.last?.detail == message)
        #expect((notices.last?.actions.isEmpty == false) == hasFix)
    }

    // MARK: Summarize

    @Test func aSummaryIsCopiedAndStaysOffTheNotch() async {
        await TextActions.summarize("Some long text.", to: pasteboard, system: system(.success("Short.")), notify: notify)
        #expect(clipboard == "Short.")
        #expect(notices.last?.detail == "The summary")
    }

    @Test func aLongTextIsCutAndItSaysSo() async {
        let long = String(repeating: "a", count: TextActions.longestSummary + 10)
        await TextActions.summarize(long, to: pasteboard, system: system(.success("Short.")), notify: notify)
        #expect(asked.texts.first?.count == TextActions.longestSummary)
        #expect(notices.last?.detail == "A summary of the start of it")
    }

    /// Too long for the model comes back as an error that isn't the documented one on macOS 27.
    @Test func aFailureOnALongTextGetsOneMoreTryWithLess() async {
        let asked = asked
        let long = String(repeating: "a", count: TextActions.longestSummary)
        let system = OnDeviceText.System(translate: { _, _, _, _ in .failure(.failed) }, summarize: { text in
            asked.texts.append(text)
            return text.count > TextActions.shortSummary ? .failure(.failed) : .success("Short.")
        })
        await TextActions.summarize(long, to: pasteboard, system: system, notify: notify)
        #expect(asked.texts.count == 2)
        #expect(asked.texts.last?.count == TextActions.shortSummary)
        #expect(clipboard == "Short.")
        #expect(notices.last?.detail == "A summary of the start of it")
    }

    @Test func aFailureOnAShortTextIsntTriedTwice() async {
        await TextActions.summarize("Short text.", to: pasteboard, system: system(.failure(.failed)), notify: notify)
        #expect(asked.texts.count == 1)
    }

    @Test(arguments: [
        (OnDeviceText.Failure.appleIntelligenceOff, "Turn on Apple Intelligence first", true),
        (.modelNotReady, "Apple Intelligence is still getting ready", false),
        (.deviceNotEligible, "This Mac can't run Apple Intelligence", false),
        (.refused, "Apple's model wouldn't summarize that", false),
        (.unsupportedLanguage, "Apple's model doesn't read that language", false),
    ])
    func aModelThatCantRunSaysSoOnce(failure: OnDeviceText.Failure, message: String, hasFix: Bool) async {
        let long = String(repeating: "a", count: TextActions.longestSummary)
        await TextActions.summarize(long, to: pasteboard, system: system(.failure(failure)), notify: notify)
        #expect(asked.texts.count == 1)
        #expect(clipboard == "what was there")
        #expect(notices.last?.text == "Can't summarize")
        #expect(notices.last?.detail == message)
        #expect((notices.last?.actions.isEmpty == false) == hasFix)
    }

    @Test func aFixGoesToItsPaneOfSettings() throws {
        let translation = try #require(OnDeviceText.Failure.notInstalled("Spanish to English").fix)
        #expect(translation.kind == .openURL(URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!))
        let intelligence = try #require(OnDeviceText.Failure.appleIntelligenceOff.fix)
        #expect(intelligence.kind == .openURL(URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!))
    }

    /// An answer that won't come until it's told to, so nothing here depends on how fast this Mac is.
    @Test func aSlowAnswerSaysItsWorkingAndTheAnswerTakesItsPlace() async {
        let gate = Gate()
        let system = OnDeviceText.System(translate: { _, _, _, _ in .failure(.failed) }, summarize: { _ in
            await gate.wait()
            return .success("Short.")
        })
        let work = Task { await TextActions.summarize("Some text.", to: pasteboard, system: system, notify: notify) }
        let limit = Date.now.addingTimeInterval(30)
        while notices.isEmpty, .now < limit { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(notices.first?.text == "Summarizing")
        await gate.open()
        await work.value
        #expect(notices.last?.text == "Copied")
        #expect(notices.first?.key == notices.last?.key)
    }
}

/// Holds whatever waits on it until it's opened.
private actor Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

/// The row, with what Return starts caught before it reaches the Mac.
@MainActor
@Suite(.serialized)
struct TranslationRowTests {
    private let viewModel: NotchViewModel

    init() {
        SnapshotRenderer.useScratchDefaults()
        viewModel = NotchViewModel(geometry: NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                                           closedSize: CGSize(width: 186, height: 37), hasHardwareNotch: true))
    }

    @Test func beforeMacOS26ItSaysSoAndDoesNothing() {
        let row = CommandEngine.translation("hola to english", isAvailable: false)
        #expect(row.title == "Translating needs macOS 26")
        #expect(row.action == nil)
    }

    @Test func theRowSaysWhereItsGoing() {
        let row = CommandEngine.translation("hola to english", isAvailable: true) { _ in }
        #expect(row.title == "Translate to English: hola")
        #expect(row.hint == "on this Mac")
    }

    @Test func returnStartsIt() {
        var started: [TranslationRequest] = []
        viewModel.run(CommandEngine.translation("hola to english", isAvailable: true) { started.append($0) })
        #expect(started.map(\.text) == ["hola"])
    }

    @Test func nothingToTranslateAsksForIt() {
        let row = CommandEngine.translation("", isAvailable: true) { _ in }
        #expect(row.action == nil)
        #expect(row.hint == "hola to english")
    }

    private func ids(_ text: String) -> [String] { CommandEngine.results(for: text, in: viewModel).map(\.id) }

    @Test func theFieldOffersIt() {
        #expect(ids("tr hola to english").first == "translate")
        #expect(ids("translate hola").first == "translate")
        #expect(ids("translate").first == "translate")
    }

    @Test func trOnItsOwnIsStillTheTray() {
        #expect(!ids("tr").contains("translate"))
        #expect(ids("tr").contains("tab-tray"))
    }

    @Test func itsCountedAsTheCommandAndNotWhatWasTyped() {
        CommandHistory.forget()
        viewModel.run(CommandEngine.translation("my secret to english", isAvailable: true) { _ in })
        #expect(CommandHistory.ranked() == ["translate"])
    }
}
