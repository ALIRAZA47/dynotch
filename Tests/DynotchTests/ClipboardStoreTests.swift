import AppKit
import Foundation
import Testing
@testable import Dynotch

/// An app in the activation notification. Nothing can make a real one for an app that isn't running.
private final class FakeApp: NSRunningApplication, @unchecked Sendable {
    private let id: String?

    init(_ id: String?) {
        self.id = id
        super.init()
    }

    override var bundleIdentifier: String? { id }
}

/// What the store asked macOS, and what macOS says back. A named pasteboard always allows reading,
/// so what's refused comes from here.
@MainActor
private final class FakeSystem {
    var changeCounts = 0
    var reads = 0
    var accessChecks = 0
    var access = ClipboardStore.Access.allowed
    var frontApp: String?
    /// Runs in the middle of a read, for what lands while the store is reading.
    var duringRead: (() -> Void)?

    var system: ClipboardStore.System {
        var system = ClipboardStore.System()
        system.changeCount = { [unowned self] in
            changeCounts += 1
            return $0.changeCount
        }
        system.access = { [unowned self] _ in
            accessChecks += 1
            return access
        }
        system.read = { [unowned self] in
            reads += 1
            let text = $0.string(forType: .string)
            duringRead?()
            return text
        }
        system.frontApp = { [unowned self] in frontApp }
        return system
    }
}

/// Each test has a store of its own, on a named pasteboard, a folder and a coordinator of its own, so
/// none of them can reach the real clipboard, the real pins or the real conditions.
@MainActor
@Suite(.serialized)
final class ClipboardStoreTests {
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let onePassword = "com.1password.1password"
    private static let safari = "com.apple.Safari"

    private let support: URL
    private let pasteboard = NSPasteboard(name: NSPasteboard.Name("app.dynotch.test.\(UUID().uuidString)"))
    private let energy = EnergyCoordinator()
    private let macOS = FakeSystem()

    init() throws {
        SnapshotRenderer.useScratchDefaults()
        AppSettings.shared.clipboardHistory = false
        support = FileManager.default.temporaryDirectory
            .appendingPathComponent("DynotchClipboardTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    deinit {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: support)
    }

    // MARK: Helpers

    private var fileURL: URL { support.appendingPathComponent("clipboard.json") }

    private func makeStore(cadence: Cadence = .clipboard) -> ClipboardStore {
        ClipboardStore(support: support, pasteboard: pasteboard, energy: energy, cadence: cadence, system: macOS.system)
    }

    /// A store with the history turned on through the setting, as it is in the app.
    private func storeTurnedOn() -> ClipboardStore {
        AppSettings.shared.clipboardHistory = true
        let store = makeStore()
        store.start()
        return store
    }

    private func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Copies and looks, as one trip through the store.
    private func keep(_ texts: String..., in store: ClipboardStore) {
        for text in texts {
            copy(text)
            store.look()
        }
    }

    private func texts(_ store: ClipboardStore) -> [String] {
        store.clips.map(\.text)
    }

    private func clip(_ text: String, in store: ClipboardStore) throws -> ClipboardStore.Clip {
        try #require(store.clips.first { $0.text == text })
    }

    /// Through the same notification macOS posts, to the store's own observer.
    private func activate(_ bundleID: String?) {
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
                                                   userInfo: [NSWorkspace.applicationUserInfoKey: FakeApp(bundleID)])
    }

    private func setQuiet(_ quiet: Bool) {
        var conditions = EnergyCoordinator.Conditions()
        conditions.screenLocked = quiet
        energy.update(conditions)
    }

    // MARK: Off until asked for

    @Test func whileOffNothingIsAskedOrKept() {
        let store = makeStore()
        store.start()
        copy("copied while off")
        store.look()
        store.sawInput()
        activate(Self.safari)
        #expect(store.clips.isEmpty)
        #expect(macOS.reads == 0)
        #expect(macOS.changeCounts == 0)
        #expect(macOS.accessChecks == 0)
    }

    @Test func thePollRunsOnlyWhileOn() {
        let fast = Cadence(name: "Test", every: 0.01, onBattery: 0.01, lowPower: 0.01)
        let store = makeStore(cadence: fast)
        store.setWatching(false)
        RunLoop.main.run(until: .now + 0.1)
        #expect(macOS.changeCounts == 0)

        store.setWatching(true)
        copy("found by the poll")
        RunLoop.main.run(until: .now + 0.2)
        #expect(texts(store) == ["found by the poll"])

        store.setWatching(false)
        let counted = macOS.changeCounts
        RunLoop.main.run(until: .now + 0.1)
        #expect(macOS.changeCounts == counted)
    }

    @Test func whatWasOnTheClipboardAtLaunchIsNotKept() {
        copy("from before")
        let store = storeTurnedOn()
        store.look()
        #expect(store.clips.isEmpty)
        #expect(macOS.reads == 0)
    }

    @Test func whatWasOnTheClipboardWhenTurnedOnIsNotKept() {
        let store = makeStore()
        store.start()
        copy("copied while off")
        AppSettings.shared.clipboardHistory = true
        store.look()
        #expect(store.clips.isEmpty)
        #expect(macOS.reads == 0)
        keep("copied after", in: store)
        #expect(texts(store) == ["copied after"])
    }

    @Test func turningOffForgetsAllButPinsAtOnce() throws {
        let store = storeTurnedOn()
        keep("one", "two", in: store)
        store.togglePin(try clip("one", in: store))
        // Published before the value changes, so this proves it doesn't wait for a later turn.
        AppSettings.shared.clipboardHistory = false
        #expect(texts(store) == ["one"])
    }

    @Test func aPinUnpinnedWhileOffGoes() throws {
        let store = storeTurnedOn()
        keep("one", in: store)
        store.togglePin(try clip("one", in: store))
        AppSettings.shared.clipboardHistory = false
        store.togglePin(try clip("one", in: store))
        #expect(store.clips.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: What's kept

    @Test func aCopyIsKept() {
        let store = storeTurnedOn()
        keep("hello", in: store)
        #expect(texts(store) == ["hello"])
        #expect(macOS.reads == 1)
    }

    @Test func nothingNewMeansNoRead() {
        let store = storeTurnedOn()
        keep("hello", in: store)
        store.look()
        store.look()
        #expect(macOS.reads == 1)
    }

    @Test func newestComesFirst() {
        let store = storeTurnedOn()
        keep("one", "two", "three", in: store)
        #expect(texts(store) == ["three", "two", "one"])
    }

    @Test func aRepeatMovesToTheFront() {
        let store = storeTurnedOn()
        keep("one", "two", "one", in: store)
        #expect(texts(store) == ["one", "two"])
    }

    @Test func aRepeatKeepsItsPin() throws {
        let store = storeTurnedOn()
        keep("one", "two", in: store)
        store.togglePin(try clip("one", in: store))
        keep("three", "one", in: store)
        #expect(try clip("one", in: store).isPinned)
        #expect(texts(store) == ["one", "three", "two"])
    }

    @Test func pinsComeFirst() throws {
        let store = storeTurnedOn()
        keep("one", "two", "three", in: store)
        store.togglePin(try clip("one", in: store))
        #expect(texts(store) == ["one", "three", "two"])
    }

    @Test func fiftyAreKeptAndPinsDontCount() throws {
        let store = storeTurnedOn()
        keep("pinned", in: store)
        store.togglePin(try clip("pinned", in: store))
        for number in 1...55 { keep("copy \(number)", in: store) }
        #expect(store.clips.count == 51)
        #expect(store.clips.filter { !$0.isPinned }.count == 50)
        #expect(store.clips.first?.text == "pinned")
        #expect(store.clips[1].text == "copy 55")
        #expect(store.clips.last?.text == "copy 6")
    }

    @Test func unpinningWithFiftyOthersKeepsToTheLimit() throws {
        let store = storeTurnedOn()
        keep("pinned", in: store)
        store.togglePin(try clip("pinned", in: store))
        for number in 1...50 { keep("copy \(number)", in: store) }
        store.togglePin(try clip("pinned", in: store))
        #expect(store.clips.count == 50)
        #expect(store.clips.allSatisfy { !$0.isPinned })
    }

    @Test func clearLeavesWhatsPinnedAndTheClipboard() throws {
        let store = storeTurnedOn()
        keep("one", "two", in: store)
        store.togglePin(try clip("one", in: store))
        store.clear()
        #expect(texts(store) == ["one"])
        #expect(pasteboard.string(forType: .string) == "two")
        store.look()
        #expect(texts(store) == ["one"])
    }

    @Test func removingAClipDoesntBringItBack() throws {
        let store = storeTurnedOn()
        keep("one", in: store)
        store.remove(try clip("one", in: store))
        store.look()
        #expect(store.clips.isEmpty)
    }

    // MARK: Pins on disk

    @Test func pinsSurviveANewStoreAndTheRestDoNot() throws {
        let store = storeTurnedOn()
        keep("kept", "forgotten", in: store)
        store.togglePin(try clip("kept", in: store))
        let reopened = makeStore()
        reopened.start()
        #expect(texts(reopened) == ["kept"])
        #expect(reopened.clips.first?.isPinned == true)
    }

    @Test func theFileHoldsOnlyPinsAndOnlyItsOwnerCanReadIt() throws {
        let store = storeTurnedOn()
        keep("the pin", "not the pin", in: store)
        store.togglePin(try clip("the pin", in: store))
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(contents.contains("the pin"))
        #expect(!contents.contains("not the pin"))
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.int16Value == 0o600)
    }

    @Test func nothingReachesTheDiskWithoutAPin() {
        let store = storeTurnedOn()
        keep("one", "two", in: store)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: support.path))?.isEmpty == true)
    }

    @Test func aFileAnyoneCouldReadIsReplaced() throws {
        try Data("[]".utf8).write(to: fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        let store = storeTurnedOn()
        keep("one", in: store)
        store.togglePin(try clip("one", in: store))
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.int16Value == 0o600)
    }

    @Test func noDraftsAreLeftBehind() throws {
        let store = storeTurnedOn()
        keep("one", in: store)
        store.togglePin(try clip("one", in: store))
        #expect(try FileManager.default.contentsOfDirectory(atPath: support.path) == ["clipboard.json"])
    }

    @Test func theLastPinTakesTheFileWithIt() throws {
        let store = storeTurnedOn()
        keep("one", in: store)
        store.togglePin(try clip("one", in: store))
        store.remove(try clip("one", in: store))
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func aBrokenFileIsLeftOut() throws {
        try Data("not json".utf8).write(to: fileURL)
        let store = storeTurnedOn()
        #expect(store.clips.isEmpty)
    }

    @Test func whateverIsInTheFileCountsAsAPin() throws {
        let saved = [ClipboardStore.Clip(text: "edited by hand", isPinned: false),
                     ClipboardStore.Clip(text: "   ", isPinned: true),
                     ClipboardStore.Clip(text: String(repeating: "x", count: ClipboardStore.longest + 1), isPinned: true)]
        try JSONEncoder().encode(saved).write(to: fileURL)
        let store = storeTurnedOn()
        #expect(texts(store) == ["edited by hand"])
        #expect(store.clips.first?.isPinned == true)
    }

    // MARK: What's left out

    /// Written out, so a type that goes missing from the store's list fails here.
    private static let skippedTypes = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword", "net.antelle.keeweb", "de.petermaurer.TransientPasteboardType",
        "Pasteboard generator type", "com.typeit4me.clipping", "com.apple.is-remote-clipboard",
    ]

    @Test(arguments: ClipboardStoreTests.skippedTypes)
    func aSkippedTypeIsDecidedBeforeAnyRead(type: String) {
        let store = storeTurnedOn()
        copy("a secret")
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType(type))
        store.look()
        #expect(store.clips.isEmpty)
        #expect(macOS.reads == 0)
    }

    /// An item refuses a name that isn't a UTI, so an app's second item holds that one in its `dyn.`
    /// form. The pasteboard's `types` still lists it by its old name.
    private static func itemType(_ type: String) -> NSPasteboard.PasteboardType {
        NSPasteboard.PasteboardType(type == "Pasteboard generator type"
            ? "dyn.ah62d4rv4gu8za2pxsvw0e55bsmwca35fr3w1e2pyr73ca7d3sbwu" : type)
    }

    @Test(arguments: ClipboardStoreTests.skippedTypes)
    func aSkippedTypeOnASecondItemCounts(type: String) {
        let store = storeTurnedOn()
        pasteboard.clearContents()
        let first = NSPasteboardItem(), second = NSPasteboardItem()
        first.setString("plain", forType: .string)
        second.setString("a secret", forType: .string)
        #expect(second.setData(Data(), forType: Self.itemType(type)))
        #expect(pasteboard.writeObjects([first, second]))
        store.look()
        #expect(store.clips.isEmpty)
        #expect(macOS.reads == 0)
    }

    @Test func aCopyAfterASkippedOneIsKept() {
        let store = storeTurnedOn()
        copy("a secret")
        pasteboard.setData(Data(), forType: Self.concealed)
        store.look()
        keep("plain", in: store)
        #expect(texts(store) == ["plain"])
    }

    @Test func aFileURLIsLeftOut() {
        let store = storeTurnedOn()
        pasteboard.clearContents()
        // As Finder does it: the file, and its name as a string.
        pasteboard.setString(URL(fileURLWithPath: "/tmp/Report.pdf").absoluteString, forType: .fileURL)
        pasteboard.setString("Report.pdf", forType: .string)
        store.look()
        #expect(store.clips.isEmpty)
        #expect(macOS.reads == 0)
    }

    @Test func aFileURLOnASecondItemCounts() {
        let store = storeTurnedOn()
        pasteboard.clearContents()
        let name = NSPasteboardItem(), file = NSPasteboardItem()
        name.setString("Report.pdf", forType: .string)
        file.setString(URL(fileURLWithPath: "/tmp/Report.pdf").absoluteString, forType: .fileURL)
        #expect(pasteboard.writeObjects([name, file]))
        store.look()
        #expect(store.clips.isEmpty)
        #expect(macOS.reads == 0)
    }

    @Test func anImageIsLeftOut() {
        let store = storeTurnedOn()
        pasteboard.clearContents()
        pasteboard.setData(Data([0x89, 0x50]), forType: .png)
        store.look()
        #expect(store.clips.isEmpty)
        #expect(macOS.reads == 0)
    }

    @Test func anEmptiedClipboardIsLeftOut() {
        let store = storeTurnedOn()
        keep("one", in: store)
        pasteboard.clearContents()
        store.look()
        #expect(texts(store) == ["one"])
        #expect(macOS.reads == 1)
    }

    @Test func textUpToTheLimitIsKept() {
        let store = storeTurnedOn()
        keep(String(repeating: "x", count: ClipboardStore.longest), in: store)
        #expect(store.clips.count == 1)
    }

    @Test func textPastTheLimitIsLeftOut() {
        let store = storeTurnedOn()
        keep(String(repeating: "x", count: ClipboardStore.longest + 1), in: store)
        #expect(store.clips.isEmpty)
    }

    @Test(arguments: ["   ", "\n\n", "\t \r\n", "\u{00A0}"])
    func whitespaceIsLeftOut(text: String) {
        let store = storeTurnedOn()
        keep(text, in: store)
        #expect(store.clips.isEmpty)
    }

    // MARK: Password managers

    @Test(arguments: ["com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
                      "com.agilebits.onepassword4", "com.bitwarden.desktop", "com.lastpass.LastPass",
                      "com.lastpass.lastpassmacdesktop", "com.dashlane.Dashlane", "com.dashlane.dashlanephonefinal",
                      "org.keepassxc.keepassxc", "org.keepassx.keepassxc", "com.keepersecurity.passwordmanager",
                      "com.callpod.keepermac", "in.sinew.Enpass-Desktop", "in.sinew.Enpass-Desktop.App",
                      "com.nordsec.nordpass", "me.proton.pass.electron", "com.apple.Passwords",
                      "com.apple.Passwords.MenuBarExtra", "com.apple.keychainaccess"])
    func theseArePasswordManagers(bundleID: String) {
        #expect(ClipboardStore.isPasswordManager(bundleID))
    }

    @Test(arguments: ["com.apple.Safari", "com.apple.Notes", "me.proton.mail", "com.1passwordish.app", "dev.zed.Zed"])
    func theseAreNot(bundleID: String) {
        #expect(!ClipboardStore.isPasswordManager(bundleID))
    }

    @Test func noBundleIDIsNoPasswordManager() {
        #expect(!ClipboardStore.isPasswordManager(nil))
    }

    @Test func aCopyWithAPasswordManagerInFrontIsLeftOut() {
        let store = storeTurnedOn()
        activate(Self.onePassword)
        keep("hunter2", in: store)
        #expect(store.clips.isEmpty)
        #expect(macOS.reads == 0)
    }

    @Test func aPasswordManagerAlreadyInFrontCounts() {
        macOS.frontApp = Self.onePassword
        let store = storeTurnedOn()
        keep("hunter2", in: store)
        #expect(store.clips.isEmpty)
        #expect(macOS.reads == 0)
    }

    /// The switch brings the check on while Safari is already in front, and the copy isn't Safari's.
    @Test func copiedInOnePasswordThenSwitchedToSafariIsLeftOut() {
        let store = storeTurnedOn()
        activate(Self.onePassword)
        copy("hunter2")
        activate(Self.safari)
        #expect(store.clips.isEmpty)
        store.look()
        #expect(store.clips.isEmpty)
        #expect(macOS.reads == 0)
    }

    @Test func aCopyInSafariBeforeSwitchingToOnePasswordIsKept() {
        let store = storeTurnedOn()
        activate(Self.safari)
        copy("from Safari")
        activate(Self.onePassword)
        #expect(texts(store) == ["from Safari"])
    }

    @Test func aCopyAfterLeavingAPasswordManagerIsKept() {
        let store = storeTurnedOn()
        activate(Self.onePassword)
        activate(Self.safari)
        keep("from Safari", in: store)
        #expect(texts(store) == ["from Safari"])
    }

    @Test func aCopyInAPasswordManagerStaysOutThroughALock() {
        let store = storeTurnedOn()
        activate(Self.onePassword)
        copy("hunter2")
        setQuiet(true)
        activate("com.apple.loginwindow")
        activate(Self.safari)
        setQuiet(false)
        store.look()
        #expect(store.clips.isEmpty)
        #expect(macOS.reads == 0)
    }

    @Test func aLockDoesntTaintWhatComesAfterIt() {
        let store = storeTurnedOn()
        activate(Self.onePassword)
        setQuiet(true)
        activate(Self.safari)
        setQuiet(false)
        store.look()
        keep("from Safari", in: store)
        #expect(texts(store) == ["from Safari"])
    }

    // MARK: Dynotch's own copies

    @Test func theRealCopyCodeIsNotKept() {
        let store = storeTurnedOn()
        NoticeAction.copy("482913", to: pasteboard)
        store.look()
        #expect(store.clips.isEmpty)
        #expect(macOS.reads == 0)
        #expect(pasteboard.string(forType: .string) == "482913")
    }

    @Test func copyingAClipBackPutsItOnTheClipboardAndToTheFront() throws {
        let store = storeTurnedOn()
        keep("one", "two", in: store)
        store.copy(try clip("one", in: store))
        #expect(pasteboard.string(forType: .string) == "one")
        #expect(texts(store) == ["one", "two"])
    }

    @Test func copyingAClipBackIsNoNewCopy() throws {
        let store = storeTurnedOn()
        keep("one", in: store)
        let reads = macOS.reads
        store.copy(try clip("one", in: store))
        store.look()
        #expect(macOS.reads == reads)
    }

    @Test func copyingAClipBackLeavesItsTextOutOfTheRecentList() throws {
        let store = storeTurnedOn()
        keep("a clip with a secret in it", in: store)
        store.copy(try clip("a clip with a secret in it", in: store))
        #expect(!LiveActivityCenter.shared.recents.contains { recent in
            recent.title.contains("secret") || recent.detail?.contains("secret") == true
        })
    }

    @Test func aPinCopiedBackWhileOffStaysAPin() throws {
        let store = storeTurnedOn()
        keep("one", in: store)
        store.togglePin(try clip("one", in: store))
        AppSettings.shared.clipboardHistory = false
        store.copy(try clip("one", in: store))
        #expect(pasteboard.string(forType: .string) == "one")
        #expect(texts(store) == ["one"])
    }

    // MARK: macOS refusing

    @Test func whenMacOSAsksNothingIsReadAndItSaysSo() {
        let store = storeTurnedOn()
        macOS.access = .asks
        keep("hello", in: store)
        #expect(store.clips.isEmpty)
        #expect(macOS.reads == 0)
        #expect(store.access == .asks)
        #expect(store.access.problem != nil)
    }

    @Test func whenMacOSDeniesNothingIsReadAndItSaysSo() {
        let store = storeTurnedOn()
        macOS.access = .denied
        keep("hello", in: store)
        #expect(store.clips.isEmpty)
        #expect(macOS.reads == 0)
        #expect(store.access == .denied)
        #expect(store.access.problem != nil)
    }

    @Test func aRefusalFromBeforeShowsWhenTurnedOn() {
        macOS.access = .denied
        let store = storeTurnedOn()
        #expect(store.access == .denied)
    }

    @Test func aChangeInSystemSettingsTakesEffectWithTheNextCopy() {
        let store = storeTurnedOn()
        macOS.access = .asks
        keep("refused", in: store)
        macOS.access = .allowed
        keep("allowed", in: store)
        #expect(texts(store) == ["allowed"])
        #expect(store.access == .allowed)
    }

    @Test func allowingInSystemSettingsClearsTheNoteWithoutACopy() {
        let store = storeTurnedOn()
        macOS.access = .asks
        keep("refused", in: store)
        macOS.access = .allowed
        store.look()
        #expect(store.access == .allowed)
        #expect(macOS.reads == 0)
        #expect(store.clips.isEmpty)
    }

    /// Types with no data behind them read back nil, as a refused read does.
    @Test func aNilReadIsRefusedForThatChangeOnly() {
        let store = storeTurnedOn()
        pasteboard.declareTypes([.string], owner: nil)
        store.look()
        store.look()
        store.look()
        #expect(store.access == .refused)
        #expect(store.clips.isEmpty)
        #expect(macOS.reads == 1)

        keep("next", in: store)
        #expect(texts(store) == ["next"])
        #expect(store.access == .allowed)
    }

    @Test func turningOffClearsTheNote() {
        let store = storeTurnedOn()
        macOS.access = .denied
        keep("hello", in: store)
        AppSettings.shared.clipboardHistory = false
        #expect(store.access == .allowed)
    }

    // MARK: When it looks

    @Test func nothingIsReadWhileNobodysLooking() {
        let store = storeTurnedOn()
        setQuiet(true)
        let counted = macOS.changeCounts
        copy("copied just before locking")
        store.look()
        store.sawInput()
        #expect(store.clips.isEmpty)
        #expect(macOS.reads == 0)
        #expect(macOS.changeCounts == counted)

        setQuiet(false)
        store.look()
        #expect(texts(store) == ["copied just before locking"])
    }

    @Test func thePointerLooksAtMostOnceASecond() {
        let store = storeTurnedOn()
        let start = Date.now.addingTimeInterval(100)
        let counted = macOS.changeCounts
        store.sawInput(now: start)
        #expect(macOS.changeCounts == counted + 1)
        store.sawInput(now: start.addingTimeInterval(0.5))
        store.sawInput(now: start.addingTimeInterval(0.99))
        #expect(macOS.changeCounts == counted + 1)
        store.sawInput(now: start.addingTimeInterval(1))
        #expect(macOS.changeCounts == counted + 2)
    }

    @Test func offThePointerDoesntEvenReadTheClock() {
        let store = makeStore()
        store.start()
        store.sawInput(now: {
            Issue.record("The clock was read with the history off")
            return .now
        }())
        #expect(macOS.changeCounts == 0)
    }

    @Test func thePointerFindsACopy() {
        let store = storeTurnedOn()
        copy("found by the pointer")
        store.sawInput()
        #expect(texts(store) == ["found by the pointer"])
    }

    @Test func anAppSwitchFindsACopy() {
        let store = storeTurnedOn()
        activate(Self.safari)
        copy("found by the switch")
        activate("com.apple.Notes")
        #expect(texts(store) == ["found by the switch"])
    }

    @Test func aCopyThatLandsDuringTheReadIsntTaken() {
        let store = storeTurnedOn()
        copy("plain")
        macOS.duringRead = { [pasteboard] in
            pasteboard.clearContents()
            pasteboard.setString("hunter2", forType: .string)
            pasteboard.setData(Data(), forType: Self.concealed)
        }
        store.look()
        macOS.duringRead = nil
        store.look()
        #expect(store.clips.isEmpty)
        #expect(macOS.reads == 1)
    }

    @Test func aTypeThatLandsDuringTheReadCounts() {
        let store = storeTurnedOn()
        copy("hunter2")
        // Written after the string, which doesn't move the change count.
        macOS.duringRead = { [pasteboard] in pasteboard.setData(Data(), forType: Self.concealed) }
        store.look()
        #expect(store.clips.isEmpty)
    }

    // MARK: Search

    @Test func searchFindsEveryWordInAnyCase() {
        let store = storeTurnedOn()
        keep("Book the flights", "book a table", "the flights are booked", in: store)
        #expect(store.clips(matching: "book").count == 3)
        #expect(store.clips(matching: "FLIGHTS book").map(\.text) == ["the flights are booked", "Book the flights"])
        #expect(store.clips(matching: "boat").isEmpty)
    }

    @Test func searchingForNothingFindsEverything() {
        let store = storeTurnedOn()
        keep("one", "two", in: store)
        #expect(store.clips(matching: "  ").count == 2)
    }

    @Test func searchKeepsPinsFirst() throws {
        let store = storeTurnedOn()
        keep("first note", "second note", in: store)
        store.togglePin(try clip("first note", in: store))
        #expect(store.clips(matching: "note").map(\.text) == ["first note", "second note"])
    }

    // MARK: The command field

    private var viewModel: NotchViewModel {
        NotchViewModel(geometry: NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                               closedSize: CGSize(width: 186, height: 37), hasHardwareNotch: true))
    }

    private func ids(_ text: String) -> [String] {
        CommandEngine.results(for: text, in: viewModel).map(\.id)
    }

    /// `ClipboardStore.shared`, on samples held in memory, is what the field reads.
    private func withSharedClips(_ clips: [ClipboardStore.Clip], isOn: Bool, run: () -> Void) {
        AppSettings.shared.clipboardHistory = isOn
        ClipboardStore.shared.loadSample(clips)
        run()
        ClipboardStore.shared.loadSample([])
    }

    @Test func clipListsPinnedFirstWithHints() throws {
        let store = storeTurnedOn()
        keep("the pin\nand a second line", "newer", in: store)
        store.togglePin(try clip("the pin\nand a second line", in: store))
        let rows = CommandEngine.clips(matching: "", in: store)
        #expect(rows.map(\.title) == ["the pin", "newer"])
        #expect(rows.map(\.hint) == ["pinned", "clip"])
    }

    @Test func clipSearches() {
        let store = storeTurnedOn()
        keep("git status", "npm test", in: store)
        #expect(CommandEngine.clips(matching: "GIT", in: store).map(\.title) == ["git status"])
    }

    @Test func aRowsTitleIsCutShort() {
        let store = storeTurnedOn()
        keep(String(repeating: "long ", count: 40), in: store)
        let title = CommandEngine.clips(matching: "", in: store).first?.title ?? ""
        #expect(title.count == 81)
        #expect(title.hasSuffix("…"))
    }

    @Test func returnCopiesAndCloses() throws {
        let store = storeTurnedOn()
        keep("one", "two", in: store)
        let row = try #require(CommandEngine.clips(matching: "one", in: store).first)
        let outcome = try #require(row.action?(viewModel))
        guard case .close = outcome else {
            Issue.record("Expected the notch to close")
            return
        }
        #expect(pasteboard.string(forType: .string) == "one")
    }

    @Test(arguments: ["clip", "clips", "clipboard", "Clip", "CLIPBOARD"])
    func everyWordForItWorks(word: String) throws {
        let clip = ClipboardStore.Clip(text: "something copied")
        withSharedClips([clip], isOn: true) {
            #expect(ids(word).first == "clip-\(clip.id)")
        }
    }

    @Test func wordsAfterItSearch() {
        let git = ClipboardStore.Clip(text: "git status"), npm = ClipboardStore.Clip(text: "npm test")
        withSharedClips([git, npm], isOn: true) {
            #expect(ids("clips npm").first == "clip-\(npm.id)")
            #expect(!ids("clips npm").contains("clip-\(git.id)"))
        }
    }

    @Test func aTimerDoesntTakeTheLine() {
        withSharedClips([], isOn: true) {
            #expect(!ids("clip 5m").contains("timer"))
        }
    }

    @Test func clipsOnlyShowOnALineThatStartsWithClip() {
        let clip = ClipboardStore.Clip(text: "something findable")
        withSharedClips([clip], isOn: true) {
            for line in ["something", "findable", "something findable", "clipper", "note findable"] {
                #expect(!ids(line).contains("clip-\(clip.id)"))
            }
        }
    }

    @Test func clipsAreNotSuggestedInAnEmptyField() {
        let clip = ClipboardStore.Clip(text: "something copied")
        withSharedClips([clip], isOn: true) {
            #expect(!ids("").contains { $0.hasPrefix("clip") })
        }
    }

    @Test func offWithNoPinsOffersOnlySettingsAndStaysOff() {
        withSharedClips([], isOn: false) {
            #expect(ids("clip") == ["clip-off"])
            #expect(ids("clip anything").first == "clip-off")
            #expect(!AppSettings.shared.clipboardHistory)
        }
    }

    @Test func offWithPinsShowsThem() {
        let pin = ClipboardStore.Clip(text: "a pin", isPinned: true)
        withSharedClips([pin], isOn: false) {
            #expect(ids("clip").first == "clip-\(pin.id)")
        }
    }

    @Test func nothingYetSaysSoAndDoesNothing() throws {
        withSharedClips([], isOn: true) {
            let rows = CommandEngine.results(for: "clip", in: viewModel)
            #expect(rows.first?.id == "clip-none")
            #expect(rows.first?.action == nil)
        }
    }
}

/// What a clip looks like on its card.
struct ClipKindTests {
    private func kind(_ text: String) -> ClipboardStore.Clip.Kind {
        ClipboardStore.Clip(text: text).kind
    }

    @Test(arguments: ["#A894FF", "#a894ff", "#abc", "#A894FF80", "  #A894FF\n"])
    func aLoneHexColorIsAColor(text: String) {
        guard case .color = kind(text) else {
            Issue.record("\(text) should be a color")
            return
        }
    }

    @Test func aColorHasItsChannels() {
        #expect(kind("#FF0080") == .color(red: 1, green: 0, blue: 128.0 / 255, opacity: 1))
        #expect(kind("#F00") == .color(red: 1, green: 0, blue: 0, opacity: 1))
        #expect(kind("#00000080") == .color(red: 0, green: 0, blue: 0, opacity: 128.0 / 255))
    }

    @Test(arguments: ["A894FF", "decade", "#A894F", "#GGGGGG", "#+ff", "#A894FF and more", "#", "#１２３"])
    func anythingElseIsNot(text: String) {
        #expect(kind(text) == .text)
    }

    @Test(arguments: ["https://example.com/a?b=c", "http://example.com", "HTTPS://EXAMPLE.COM/", "  https://example.com\n"])
    func aLoneWebLinkIsALink(text: String) {
        guard case .link = kind(text) else {
            Issue.record("\(text) should be a link")
            return
        }
    }

    @Test(arguments: ["javascript:alert(1)", "file:///etc/hosts", "ftp://example.com/a", "mailto:sam@example.com",
                      "example.com", "see https://example.com", "https://", "https://exa mple.com"])
    func nothingElseGetsOpenLink(text: String) {
        if case .link = kind(text) { Issue.record("\(text) shouldn't be a link") }
    }

    @Test(arguments: ["git rebase -i HEAD~3", "npm run build", "$ make test", "swift build -c release", "ls -la",
                      "make test --verbose", "func greet() {\n    print(1)\n}", "let total = items.count;",
                      "const add = (a, b) => a + b", "if a == b", "<div></div>", "    indented\n    block"])
    func aCommandOrCodeIsMonospaced(text: String) {
        #expect(kind(text) == .code)
    }

    @Test(arguments: ["We're moving the launch to Tuesday so the docs can catch up.", "Hello, world!", "make the deck nicer",
                      "Find the file (the big one) and open it", "Sam said: bring coffee", "git is a version control system.",
                      "One line\nand another", "swift", "Meet at 5pm; bring coffee and cake"])
    func proseIsNot(text: String) {
        #expect(kind(text) == .text)
    }

    @Test func theTitleIsTheFirstLineThatHasAnything() {
        #expect(ClipboardStore.Clip(text: "\n\n  first\nsecond").title == "first")
        #expect(ClipboardStore.Clip(text: "first\r\nsecond").title == "first")
    }

    @Test func aHugeClipStaysCheapToShow() {
        let clip = ClipboardStore.Clip(text: String(repeating: "x", count: ClipboardStore.longest))
        #expect(clip.title.count == 81)
        #expect(clip.preview.count == 400)
    }

    @Test func theTextStaysExactlyAsCopied() throws {
        let text = "  spaced\n"
        let decoded = try JSONDecoder().decode(ClipboardStore.Clip.self, from: JSONEncoder().encode(ClipboardStore.Clip(text: text)))
        #expect(decoded.text == text)
    }

    @Test func onlyWhatMattersIsSaved() throws {
        let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ClipboardStore.Clip(text: "#A894FF"))) as? [String: Any]
        #expect(Set(saved?.keys ?? [:].keys) == ["id", "text", "copiedAt", "isPinned"])
    }
}
