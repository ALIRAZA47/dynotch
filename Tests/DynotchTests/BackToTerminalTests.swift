import Darwin
import Foundation
import Testing
@testable import Dynotch
import DynotchShared

private let sessionUUID = "7E0D7E04-8FD6-4E87-A1F0-5B61A7A6AB7B"
private let sessionID = "w0t1p2:\(sessionUUID)"
private let cursor = "com.todesktop.230313mzl4w4u92"

/// Values that must never reach a script, in every field that could carry them.
private let hostileValues = [
    "\"", "\\", "\n", "\r\n", "\0", "", " ", "'", "`",
    "\" & do shell script \"touch /tmp/dynotch-pwned\" & \"",
    "\"\ndo shell script \"id\"\n\"",
    "\\\" & do shell script \\\"id",
    "end tell\ndo shell script \"id\"",
]

/// The dictionary a stand-in app holds, for compiling without the real app. The codes are the real ones.
private enum Dictionary {
    static let iTerm = """
        <suite name="Standard Suite" code="????" description="">
          <class name="application" code="capp" description=""><element type="window"/></class>
          <class name="window" code="cwin" description=""><element type="tab"/></class>
        </suite>
        <suite name="iTerm2 Suite" code="Itrm" description="">
          <class name="tab" code="Trmt" description=""><element type="session"/></class>
          <class name="session" code="Trms" description="">
            <property name="unique ID" code="Uniq" type="text" access="r"/>
          </class>
          <command name="select" code="Itrmslct" description=""><direct-parameter type="specifier"/></command>
        </suite>
        """

    static func ghostty(hasTTY: Bool) -> String {
        """
        <suite name="Ghostty Suite" code="Ghst" description="">
          <class name="application" code="capp" description=""><element type="terminal"/></class>
          <class name="terminal" code="Gtrm" plural="terminals" description="">
            <property name="working directory" code="Gwdr" type="text" access="r"/>
            \(hasTTY ? #"<property name="tty" code="Gtty" type="text" access="r"/>"# : "")
          </class>
          <command name="focus" code="GhstFcus" description=""><direct-parameter type="specifier"/></command>
        </suite>
        """
    }

    static let empty = #"<suite name="Nothing" code="Noth" description=""><class name="application" code="capp" description=""/></suite>"#
}

/// A throwaway folder, gone when the test is.
private final class Scratch {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("dyn-" + UUID().uuidString.prefix(8), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    /// A bundle with a dictionary and no executable, so `osacompile` has terms to read and nothing can start.
    func standIn(_ name: String, suites: String) throws -> URL {
        let body = #"<?xml version="1.0" encoding="UTF-8"?><dictionary title="Stand-in">"# + suites + "</dictionary>"
        return try standIn(name) { try body.write(to: $0, atomically: true, encoding: .utf8) }
    }

    func standIn(_ name: String, copying dictionary: URL) throws -> URL {
        try standIn(name) { try FileManager.default.copyItem(at: dictionary, to: $0) }
    }

    private func standIn(_ name: String, writing write: (URL) throws -> Void) throws -> URL {
        let app = folder.appendingPathComponent(name + ".app", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try write(resources.appendingPathComponent("Dictionary.sdef"))
        let info: [String: Any] = ["CFBundleIdentifier": "app.dynotch.tests.standin." + name, "CFBundleName": name,
                                   "CFBundlePackageType": "APPL", "NSAppleScriptEnabled": true,
                                   "OSAScriptingDefinition": "Dictionary.sdef"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    /// Compiles `source` with its app swapped for `app`. Nothing runs, so nothing is sent to anything.
    /// A misspelt word still compiles, as a variable, so the terms that resolved are read from what
    /// came out: `codes` says which of `wanted` the compiled script holds.
    func compile(_ source: String, for bundleID: String, against app: URL,
                 wanted: [String] = []) throws -> (code: Int32, error: String, codes: [String]) {
        let swapped = source.replacingOccurrences(of: "application id \"\(bundleID)\"", with: "application \"\(app.path)\"")
        #expect(swapped != source)
        let file = folder.appendingPathComponent(UUID().uuidString + ".applescript")
        let compiled = file.deletingPathExtension().appendingPathExtension("scpt")
        try swapped.write(to: file, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        process.arguments = ["-o", compiled.path, file.path]
        let error = Pipe()
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let bytes = (try? Data(contentsOf: compiled)) ?? Data()
        return (process.terminationStatus, String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                wanted.filter { bytes.range(of: Data($0.utf8)) != nil })
    }
}

struct KnownTerminalTests {
    @Test(arguments: [("Apple_Terminal", "com.apple.Terminal"), ("iTerm.app", "com.googlecode.iterm2"),
                      ("ghostty", "com.mitchellh.ghostty"), ("WezTerm", "com.github.wez.wezterm"),
                      ("WarpTerminal", "dev.warp.Warp-Stable"), ("alacritty", "org.alacritty"),
                      ("kitty", "net.kovidgoyal.kitty"), ("Hyper", "co.zeit.hyper"), ("Tabby", "org.tabby"),
                      ("rio", "com.raphaelamorim.rio"), ("vscode", "com.microsoft.VSCode"), ("zed", "dev.zed.Zed")])
    func aProgramNamesItsApp(program: String, bundleID: String) {
        #expect(TerminalOrigin(program: program).terminal?.bundleID == bundleID)
    }

    @Test func everyBundleIDIsEnoughOnItsOwn() {
        for terminal in KnownTerminal.all {
            #expect(TerminalOrigin(bundleID: terminal.bundleID).terminal == terminal)
        }
    }

    @Test func noAppIsListedTwice() {
        #expect(Set(KnownTerminal.all.map(\.bundleID)).count == KnownTerminal.all.count)
    }

    @Test func theCaseOfAProgramDoesntMatter() {
        #expect(TerminalOrigin(program: "ITERM.APP").terminal?.name == "iTerm")
    }

    @Test func aBundleIDHasToBeExact() {
        #expect(TerminalOrigin(bundleID: "COM.APPLE.TERMINAL").terminal == nil)
        #expect(TerminalOrigin(bundleID: "com.apple.Terminal.evil").terminal == nil)
    }

    @Test func theBundleIDPicksBetweenAppsThatSetOneProgram() {
        #expect(TerminalOrigin(program: "vscode", bundleID: cursor).terminal?.name == "Cursor")
        #expect(TerminalOrigin(program: "vscode", bundleID: "com.vscodium").terminal?.name == "VSCodium")
        #expect(TerminalOrigin(program: "vscode", bundleID: "com.microsoft.VSCode").terminal?.bundleID == "com.microsoft.VSCode")
        #expect(TerminalOrigin(program: "vscode", bundleID: "com.microsoft.VSCodeInsiders").terminal?.bundleID == "com.microsoft.VSCodeInsiders")
        #expect(TerminalOrigin(program: "zed", bundleID: "dev.zed.Zed-Preview").terminal?.bundleID == "dev.zed.Zed-Preview")
        #expect(TerminalOrigin(program: "WarpTerminal", bundleID: "dev.warp.Warp-Preview").terminal?.bundleID == "dev.warp.Warp-Preview")
    }

    @Test func aProgramOnItsOwnMeansTheFirstAppThatSetsIt() {
        #expect(TerminalOrigin(program: "vscode").terminal?.bundleID == "com.microsoft.VSCode")
        #expect(TerminalOrigin(program: "zed").terminal?.bundleID == "dev.zed.Zed")
        #expect(TerminalOrigin(program: "WarpTerminal").terminal?.bundleID == "dev.warp.Warp-Stable")
    }

    @Test func aBundleIDInheritedFromAnotherTerminalLosesToTheProgram() {
        // `code .` in iTerm: VS Code's terminal sets its own program, and keeps iTerm's bundle ID.
        #expect(TerminalOrigin(program: "vscode", bundleID: "com.googlecode.iterm2").terminal?.name == "VS Code")
        #expect(TerminalOrigin(program: "ghostty", bundleID: "com.apple.Terminal").terminal?.name == "Ghostty")
    }

    @Test func aProgramAppsDontSetLeavesTheBundleID() {
        // JetBrains and Claude set no program at all.
        #expect(TerminalOrigin(bundleID: "com.jetbrains.WebStorm").terminal?.name == "WebStorm")
    }

    @Test func aKnownProgramFromAnUnknownAppGoesNowhere() {
        // A fork of VS Code would otherwise bring up VS Code.
        #expect(TerminalOrigin(program: "vscode", bundleID: "com.example.fork").terminal == nil)
    }

    @Test func anUnknownProgramFromAKnownAppGoesNowhere() {
        #expect(TerminalOrigin(program: "evil", bundleID: "com.googlecode.iterm2").terminal == nil)
    }

    @Test(arguments: ["evil", "Finder", "com.apple.Terminal", "open", "/Applications/Calculator.app", "tmux "])
    func anUnknownNameGetsNoButton(name: String) {
        #expect(TerminalOrigin(program: name).action == nil)
    }

    @Test(arguments: ["com.apple.finder", "com.apple.systempreferences", "com.evil.app", "iTerm.app"])
    func anUnknownBundleIDGetsNoButton(bundleID: String) {
        #expect(TerminalOrigin(bundleID: bundleID).action == nil)
        #expect(TerminalOrigin(program: "iTerm.app", bundleID: bundleID).action == nil)
    }

    @Test func nothingToGoOnGetsNoButton() {
        #expect(TerminalOrigin().action == nil)
        #expect(TerminalOrigin(program: "", bundleID: "").action == nil)
        #expect(TerminalOrigin(sessionID: sessionID, tty: "/dev/ttys001", folder: "/tmp").action == nil)
    }

    @Test func anEmptyNameIsNoName() {
        #expect(TerminalOrigin(program: "", bundleID: "com.apple.Terminal").terminal?.name == "Terminal")
        #expect(TerminalOrigin(program: "ghostty", bundleID: "").terminal?.name == "Ghostty")
    }

    @Test func theButtonCarriesWhereItRan() {
        let origin = TerminalOrigin(program: "iTerm.app", sessionID: sessionID)
        #expect(origin.action == NoticeAction(title: "Back to iTerm", kind: .focusTerminal(origin)))
    }

    @Test func theDesktopAppHasNoTabToPick() {
        let origin = TerminalOrigin(bundleID: "com.anthropic.claudefordesktop", sessionID: "local_123", folder: "/work")
        #expect(origin.title == "Back to Claude")
        #expect(origin.action != nil)
        #expect(origin.script == nil)
    }
}

@MainActor
struct TerminalTitleTests {
    @Test(arguments: [("com.apple.Terminal", "Back to Terminal"), ("com.googlecode.iterm2", "Back to iTerm"),
                      ("com.mitchellh.ghostty", "Back to Ghostty"), ("com.github.wez.wezterm", "Back to WezTerm"),
                      ("dev.warp.Warp-Stable", "Back to Warp"), ("dev.warp.Warp-Preview", "Back to Warp"),
                      ("net.kovidgoyal.kitty", "Back to kitty"), ("co.zeit.hyper", "Back to Hyper"),
                      ("org.tabby", "Back to Tabby"), ("com.raphaelamorim.rio", "Back to Rio"),
                      ("com.microsoft.VSCode", "Back to VS Code"), ("com.microsoft.VSCodeInsiders", "Back to VS Code"),
                      ("com.vscodium", "Back to VSCodium"), (cursor, "Back to Cursor"), ("dev.zed.Zed", "Back to Zed"),
                      ("dev.zed.Zed-Preview", "Back to Zed"), ("com.anthropic.claudefordesktop", "Back to Claude"),
                      ("com.jetbrains.WebStorm", "Back to WebStorm"), ("com.jetbrains.datagrip", "Back to DataGrip"),
                      ("com.jetbrains.intellij", "Back to IntelliJ"), ("com.jetbrains.pycharm.ce", "Back to PyCharm"),
                      ("com.jetbrains.goland", "Back to GoLand")])
    func theTitleSaysWhereItGoes(bundleID: String, title: String) {
        #expect(TerminalOrigin(bundleID: bundleID).title == title)
    }

    @Test func aNameTooLongForTheButtonFallsBack() {
        // "Back to Alacritty" is one over, and cut short it would read "Back to Alacritt".
        #expect(TerminalOrigin(bundleID: "org.alacritty").title == "Back")
    }

    @Test func nowhereKnownFallsBack() {
        #expect(TerminalOrigin().title == "Back")
        #expect(TerminalOrigin(program: "evil").title == "Back")
    }

    @Test func everyTitleFitsAButton() {
        for terminal in KnownTerminal.all {
            let title = TerminalOrigin(bundleID: terminal.bundleID).title
            #expect(title.count <= 16)
            #expect(URLCommands.button(title: title, url: "https://example.com")?.title == title)
        }
    }

    @Test func tmuxStillSaysWhichApp() {
        #expect(TerminalOrigin(program: "tmux", bundleID: "com.googlecode.iterm2").title == "Back to iTerm")
    }
}

struct TerminalValidationTests {
    @Test(arguments: ["/dev/ttys0", "/dev/ttys003", "/dev/ttys999"])
    func aRealTTYPasses(tty: String) {
        #expect(TerminalScript.checked(tty: tty) == tty)
    }

    @Test(arguments: hostileValues + ["/dev/ttys", "/dev/tty001", "/dev/ttysabc", "/dev/ttys001\n", "\n/dev/ttys001", " /dev/ttys001",
                                      "/dev/ttys001 ", "/dev/ttys001\n/dev/ttys002", "/dev/ttys0\" & do shell script \"id",
                                      "/dev/ttys١٢٣", "/dev/ttys１", "/dev/ttys1\u{0301}", "/dev/ttys1\0", "/dev/../dev/ttys001",
                                      "//dev/ttys001", "/DEV/TTYS001"])
    func anythingElseFailsAsATTY(value: String) {
        #expect(TerminalScript.checked(tty: value) == nil)
        #expect(TerminalScript.terminal(tty: value) == nil)
    }

    @Test func onlyTheUUIDOfASessionIDIsKept() {
        #expect(TerminalScript.uuid(inSessionID: sessionID) == sessionUUID)
        #expect(TerminalScript.uuid(inSessionID: "w10t200p3000:\(sessionUUID.lowercased())") == sessionUUID.lowercased())
    }

    @Test(arguments: hostileValues + [sessionUUID, "w0t1:\(sessionUUID)", "w0t1p2\(sessionUUID)", "w0t1p2:", "w0t1p2:\(sessionUUID)\n",
                                      "\nw0t1p2:\(sessionUUID)", "w0t1p2:\(sessionUUID)x", "w0t1p2:\(sessionUUID.dropLast())g",
                                      "w0t1p2:\(sessionUUID)\" & do shell script \"id", "wxtyp2:\(sessionUUID)",
                                      "w0t1p2:\(sessionUUID.replacingOccurrences(of: "-", with: ""))"])
    func anythingElseFailsAsASessionID(value: String) {
        #expect(TerminalScript.uuid(inSessionID: value) == nil)
        #expect(TerminalScript.iTerm(sessionID: value) == nil)
    }

    @Test(arguments: ["/", "/work", "/Users/you/my project", "/Users/you/it's mine", "/Users/you/Документы", "/tmp/a&b;c$d`e"])
    func aRealFolderPasses(folder: String) {
        #expect(TerminalScript.checked(folder: folder) == folder)
    }

    @Test(arguments: hostileValues + ["work", "~/work", "../work", "/work\n", "/work\nmore", "/work\u{7F}", "/wo\"rk", "/wo\\rk",
                                      "/tmp/\" & do shell script \"id\" & \"",
                                      "/" + String(repeating: "a", count: 2000)])
    func anythingElseFailsAsAFolder(value: String) {
        #expect(TerminalScript.checked(folder: value) == nil)
    }

    @Test(arguments: hostileValues)
    func aHostileValueLeavesOnlyTheApp(value: String) {
        // The button stays, and comes forward with no script at all.
        let iTerm = TerminalOrigin(program: "iTerm.app", sessionID: value, tty: value, folder: value)
        let terminal = TerminalOrigin(program: "Apple_Terminal", sessionID: value, tty: value, folder: value)
        let ghostty = TerminalOrigin(program: "ghostty", sessionID: value, tty: value, folder: value)
        for origin in [iTerm, terminal, ghostty] {
            #expect(origin.action != nil)
            #expect(origin.script == nil)
        }
    }

    @Test(arguments: hostileValues)
    func aHostileNameNeverReachesAnApp(value: String) {
        #expect(TerminalOrigin(program: value, bundleID: value).action == nil)
    }

    @Test func oneGoodValueOutOfTwoIsEnoughForGhostty() throws {
        let hostile = hostileValues[9]
        #expect(TerminalScript.ghostty(tty: hostile, folder: "/work")?.arguments == ["", "/work"])
        #expect(TerminalScript.ghostty(tty: "/dev/ttys001", folder: hostile)?.arguments == ["/dev/ttys001", ""])
    }
}

struct TerminalScriptTests {
    private var scripts: [TerminalScript] {
        [TerminalScript.iTerm(sessionID: sessionID), TerminalScript.terminal(tty: "/dev/ttys003"),
         TerminalScript.ghostty(tty: "/dev/ttys003", folder: "/work")].compactMap { $0 }
    }

    @Test func iTermLooksForTheSessionAcrossEverything() throws {
        let script = try #require(TerminalOrigin(program: "iTerm.app", sessionID: sessionID).script)
        #expect(script.arguments == [sessionUUID])
        for line in ["tell application id \"com.googlecode.iterm2\"", "repeat with aWindow in windows", "repeat with aTab in tabs of aWindow",
                     "repeat with aSession in sessions of aTab", "if unique ID of aSession is wanted then", "select aWindow", "select aTab",
                     "select aSession", "activate"] {
            #expect(script.source.contains(line))
        }
    }

    @Test func terminalLooksForTheTabByItsTTY() throws {
        let script = try #require(TerminalOrigin(program: "Apple_Terminal", tty: "/dev/ttys003").script)
        #expect(script.arguments == ["/dev/ttys003"])
        for line in ["tell application id \"com.apple.Terminal\"", "if tty of aTab is wanted then", "set selected tab of aWindow to aTab",
                     "set frontmost of aWindow to true", "activate"] {
            #expect(script.source.contains(line))
        }
    }

    @Test func ghosttyLooksByItsTTYThenItsFolder() throws {
        let script = try #require(TerminalOrigin(program: "ghostty", tty: "/dev/ttys003", folder: "/work").script)
        #expect(script.arguments == ["/dev/ttys003", "/work"])
        for line in ["tell application id \"com.mitchellh.ghostty\"", "terminals whose tty is wantedTTY",
                     "terminals whose working directory is wantedFolder", "if (count of found) is 1 then", "focus item 1 of found"] {
            #expect(script.source.contains(line))
        }
    }

    @Test func aWayToSayNothingLeavesNoScript() {
        #expect(TerminalOrigin(program: "iTerm.app", tty: "/dev/ttys003").script == nil)
        #expect(TerminalOrigin(program: "Apple_Terminal", sessionID: sessionID).script == nil)
        #expect(TerminalOrigin(program: "ghostty", sessionID: sessionID).script == nil)
    }

    @Test func theOthersOnlyComeForward() {
        let tabbed = ["com.googlecode.iterm2", "com.apple.Terminal", "com.mitchellh.ghostty"]
        for terminal in KnownTerminal.all where !tabbed.contains(terminal.bundleID) {
            #expect(TerminalOrigin(bundleID: terminal.bundleID, sessionID: sessionID, tty: "/dev/ttys003", folder: "/work").script == nil)
        }
    }

    @Test func theAppThatWonPicksTheScript() {
        let origin = TerminalOrigin(program: "iTerm.app", bundleID: "com.apple.Terminal", sessionID: sessionID, tty: "/dev/ttys003")
        #expect(origin.script?.source.contains("com.googlecode.iterm2") == true)
        #expect(origin.script?.arguments == [sessionUUID])
    }

    @Test func insideTmuxNoTabIsPicked() {
        let origin = TerminalOrigin(program: "tmux", bundleID: "com.googlecode.iterm2", sessionID: sessionID, tty: "/dev/ttys003")
        #expect(origin.terminal?.name == "iTerm")
        #expect(origin.action != nil)
        #expect(origin.script == nil)
    }

    @Test func tmuxWithNoKnownAppGetsNoButton() {
        #expect(TerminalOrigin(program: "tmux").action == nil)
        #expect(TerminalOrigin(program: "tmux", bundleID: "com.evil.app").action == nil)
    }

    @Test func tmuxIsSeenInTheEnvironmentEvenWhereItLeavesTheProgramAlone() {
        let origin = TerminalOrigin(environment: ["TMUX": "/private/tmp/tmux-501/default,123,0", "TERM_PROGRAM": "iTerm.app",
                                                  "__CFBundleIdentifier": "com.googlecode.iterm2", "ITERM_SESSION_ID": sessionID])
        #expect(origin.isInTmux)
        #expect(origin.script == nil)
        #expect(TerminalOrigin(environment: ["TMUX": "", "TERM_PROGRAM": "iTerm.app"]).program == "iTerm.app")
    }

    @Test func noScriptRunsAShell() {
        for script in scripts {
            let source = script.source.lowercased()
            for word in ["do shell script", "run script", "load script", "store script", "osascript", "system events", "keystroke"] {
                #expect(!source.contains(word))
            }
        }
    }

    @Test func eachScriptHasOneHandlerAndItsAppAlone() {
        for script in scripts {
            #expect(script.source.components(separatedBy: "on \(TerminalScript.handler)(").count == 2)
            #expect(script.source.components(separatedBy: "tell application").count == 2)
            #expect(TerminalScript.handler == TerminalScript.handler.lowercased())
        }
    }

    @Test func theSourceNeverHoldsAValue() {
        let one = TerminalScript.ghostty(tty: "/dev/ttys1", folder: "/one")
        let two = TerminalScript.ghostty(tty: "/dev/ttys2", folder: "/two")
        #expect(one?.source == two?.source)
        #expect(TerminalScript.terminal(tty: "/dev/ttys1")?.source == TerminalScript.terminal(tty: "/dev/ttys2")?.source)
        #expect(TerminalScript.iTerm(sessionID: sessionID)?.source == TerminalScript.iTerm(sessionID: "w9t9p9:\(sessionUUID.lowercased())")?.source)
        for script in scripts {
            for argument in script.arguments { #expect(!script.source.contains(argument)) }
        }
    }

    @Test func terminalCompilesAgainstItsOwnDictionary() throws {
        let scratch = try Scratch()
        let dictionary = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app/Contents/Resources/Terminal.sdef")
        let app = try scratch.standIn("Terminal", copying: dictionary)
        let source = try #require(TerminalScript.terminal(tty: "/dev/ttys003")?.source)
        // Tab, tty, selected tab, frontmost, miniaturized.
        let codes = ["ttab", "ttty", "tcnt", "pisf", "pmnd"]
        let result = try scratch.compile(source, for: "com.apple.Terminal", against: app, wanted: codes)
        #expect(result.code == 0, "\(result.error)")
        #expect(result.codes == codes)
    }

    @Test func iTermCompilesAgainstItsTerms() throws {
        let scratch = try Scratch()
        let app = try scratch.standIn("iTerm", suites: Dictionary.iTerm)
        let source = try #require(TerminalScript.iTerm(sessionID: sessionID)?.source)
        // Tab, session, unique ID, select.
        let codes = ["Trmt", "Trms", "Uniq", "slct"]
        let result = try scratch.compile(source, for: "com.googlecode.iterm2", against: app, wanted: codes)
        #expect(result.code == 0, "\(result.error)")
        #expect(result.codes == codes)
    }

    @Test(arguments: [false, true])
    func ghosttyCompilesWithOrWithoutATTY(hasTTY: Bool) throws {
        // 1.3 has no `tty`, which then compiles as a name, fails inside its `try`, and leaves the folder.
        let scratch = try Scratch()
        let app = try scratch.standIn("Ghostty", suites: Dictionary.ghostty(hasTTY: hasTTY))
        let source = try #require(TerminalScript.ghostty(tty: "/dev/ttys003", folder: "/work")?.source)
        // Terminal, working directory, focus, tty.
        let result = try scratch.compile(source, for: "com.mitchellh.ghostty", against: app, wanted: ["Gtrm", "Gwdr", "Fcus", "Gtty"])
        #expect(result.code == 0, "\(result.error)")
        #expect(result.codes == ["Gtrm", "Gwdr", "Fcus"] + (hasTTY ? ["Gtty"] : []))
    }

    @Test func compilingReallyChecksTheTerms() throws {
        let scratch = try Scratch()
        let app = try scratch.standIn("Empty", suites: Dictionary.empty)
        let source = try #require(TerminalScript.iTerm(sessionID: sessionID)?.source)
        #expect(try scratch.compile(source, for: "com.googlecode.iterm2", against: app).code != 0)
    }
}

/// Runs in-process with a script that talks to no other app, so nothing here sends an Apple event.
struct ScriptArgumentTests {
    /// One for them all: AppleScript's very first use fails on all but one thread if several start at once.
    private static let runner = AppleScriptRunner()
    private let echo = "on pick(one, other)\nreturn one & \"|\" & other\nend pick"

    @Test func argumentsArriveInOrder() async {
        #expect(await Self.runner.run(echo, handler: "pick", arguments: ["one", "two"])?.text == "one|two")
    }

    @Test(arguments: hostileValues.filter { !$0.contains("\0") })
    func aHostileArgumentStaysText(value: String) async {
        #expect(await Self.runner.run(echo, handler: "pick", arguments: [value, "x"])?.text == value + "|x")
    }

    @Test func aHostileArgumentRunsNothing() async throws {
        let scratch = try Scratch()
        let canary = scratch.folder.appendingPathComponent("canary")
        let hostile = "\" & do shell script \"touch \(canary.path)\" & \""
        #expect(await Self.runner.run(echo, handler: "pick", arguments: [hostile, "x"])?.text == hostile + "|x")
        #expect(!FileManager.default.fileExists(atPath: canary.path))
    }

    @Test func noSuchHandlerComesBackAsNothing() async {
        #expect(await Self.runner.run(echo, handler: "other", arguments: ["a", "b"]) == nil)
    }

    @Test func theSameScriptTakesNewArguments() async {
        #expect(await Self.runner.run(echo, handler: "pick", arguments: ["a", "b"])?.text == "a|b")
        #expect(await Self.runner.run(echo, handler: "pick", arguments: ["c", "d"])?.text == "c|d")
    }
}

/// `focus()`, watched through a stand-in for the Mac, so nothing moves on screen.
@MainActor
struct TerminalFocusTests {
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        var all: [String] { lock.withLock { entries } }
        func add(_ entry: String) { lock.withLock { entries.append(entry) } }
    }

    private func mac(_ log: Log, running: Bool = true, run: (@Sendable () async -> Void)? = nil) -> TerminalMac {
        TerminalMac(isRunning: { log.add("is \($0) running"); return running },
                    bringForward: { log.add("forward \($0)") },
                    run: { script in
                        log.add("script \(script.arguments)")
                        await run?()
                    })
    }

    @Test func nowhereKnownTouchesNothing() async {
        let log = Log()
        #expect(TerminalOrigin(program: "evil", bundleID: "com.apple.finder").focus(on: mac(log)) == nil)
        #expect(TerminalOrigin().focus(on: mac(log)) == nil)
        #expect(log.all.isEmpty)
    }

    @Test func theAppComesForwardBeforeTheScript() async {
        let log = Log()
        await TerminalOrigin(program: "iTerm.app", sessionID: sessionID).focus(on: mac(log))?.value
        #expect(log.all == ["is com.googlecode.iterm2 running", "forward com.googlecode.iterm2", "script [\"\(sessionUUID)\"]"])
    }

    @Test func aTerminalWithNoTabsToPickOnlyComesForward() {
        let log = Log()
        #expect(TerminalOrigin(program: "WezTerm", tty: "/dev/ttys003").focus(on: mac(log)) == nil)
        #expect(log.all == ["is com.github.wez.wezterm running", "forward com.github.wez.wezterm"])
    }

    @Test func aBadValueOnlyComesForward() {
        let log = Log()
        #expect(TerminalOrigin(program: "Apple_Terminal", tty: hostileValues[9]).focus(on: mac(log)) == nil)
        #expect(log.all == ["is com.apple.Terminal running", "forward com.apple.Terminal"])
    }

    @Test func tmuxOnlyComesForward() {
        let log = Log()
        #expect(TerminalOrigin(program: "tmux", bundleID: "com.apple.Terminal", tty: "/dev/ttys003").focus(on: mac(log)) == nil)
        #expect(log.all == ["is com.apple.Terminal running", "forward com.apple.Terminal"])
    }

    @Test func aTerminalThatHasBeenQuitGetsNoScript() {
        // Scripting it would start it, only to ask for a tab that's gone.
        let log = Log()
        #expect(TerminalOrigin(program: "iTerm.app", sessionID: sessionID).focus(on: mac(log, running: false)) == nil)
        #expect(log.all == ["is com.googlecode.iterm2 running", "forward com.googlecode.iterm2"])
    }

    @Test func aScriptThatHangsHoldsNothingUp() async {
        let log = Log()
        let (release, released) = AsyncStream<Void>.makeStream()
        let task = TerminalOrigin(program: "iTerm.app", sessionID: sessionID).focus(on: mac(log) {
            for await _ in release { break }
            log.add("script finished")
        })
        // Still on the main actor, with the script waiting: the app has already come forward.
        #expect(log.all.contains("forward com.googlecode.iterm2"))
        #expect(!log.all.contains("script finished"))
        released.yield()
        await task?.value
        #expect(log.all.last == "script finished")
    }
}

/// The real `URLCommands.handle`, down to the notice the glance would show.
@MainActor
@Suite(.serialized)
struct TerminalLinkTests {
    private let center = LiveActivityCenter.shared

    /// Clears what other tests left, as the center is shared: a notice on show has others waiting behind it.
    private func clearNotices() {
        for _ in 0...NoticeQueue.mostWaiting { center.dismissNotice() }
        center.loadSample(recents: [], unseen: 0)
    }

    private func actions(_ query: String) throws -> [NoticeAction] {
        SnapshotRenderer.useScratchDefaults()
        clearNotices()
        defer { clearNotices() }
        URLCommands.handle(try #require(URL(string: "dynotch://notify?text=Failed&" + query)))
        let shown = center.content.activity
        guard case .notice(let notice) = shown else {
            Issue.record("Nothing on show: \(shown)")
            return []
        }
        #expect(center.recents.first?.actions == notice.actions)
        return notice.actions
    }

    private func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }

    @Test func noTerminalMeansNoButton() throws {
        #expect(try actions("detail=make").isEmpty)
    }

    @Test func aTerminalIsTheMainButton() throws {
        let origin = TerminalOrigin(program: "iTerm.app", bundleID: "com.googlecode.iterm2", sessionID: sessionID,
                                    tty: "/dev/ttys003", folder: "/Users/you/my project")
        let query = "terminal=iTerm.app&bundle=com.googlecode.iterm2&session=\(encoded(sessionID))&tty=%2Fdev%2Fttys003"
            + "&folder=\(encoded("/Users/you/my project"))"
        #expect(try actions(query) == [NoticeAction(title: "Back to iTerm", kind: .focusTerminal(origin))])
    }

    @Test func aScriptsOwnButtonGoesFirstAndBothShow() throws {
        let found = try actions("button=Open&url=https%3A%2F%2Fexample.com&terminal=Apple_Terminal&tty=%2Fdev%2Fttys003")
        #expect(found.map(\.title) == ["Open", "Back to Terminal"])
        #expect(found.first?.kind == .openURL(URL(string: "https://example.com")!))
    }

    @Test func aButtonThatIsntAllowedLeavesTheWayBack() throws {
        #expect(try actions("button=Open&url=file%3A%2F%2F%2Fetc%2Fpasswd&terminal=ghostty").map(\.title) == ["Back to Ghostty"])
    }

    @Test func anUnknownTerminalGetsNoButton() throws {
        #expect(try actions("terminal=evil&session=\(encoded(sessionID))").isEmpty)
    }

    @Test func anUnknownBundleIDGetsNoButton() throws {
        #expect(try actions("bundle=com.apple.finder&folder=%2Ftmp").isEmpty)
    }

    @Test func anUnknownBundleIDWithAKnownProgramGetsNoButton() throws {
        #expect(try actions("terminal=iTerm.app&bundle=com.evil.app").isEmpty)
    }

    @Test func anUnknownTerminalLeavesAScriptsOwnButton() throws {
        #expect(try actions("button=Open&url=https%3A%2F%2Fexample.com&terminal=evil").map(\.title) == ["Open"])
    }

    @Test func aHostileValueSurvivesAsTextAndNeverAsAScript() throws {
        let hostile = hostileValues[9]
        let found = try actions("terminal=Apple_Terminal&tty=\(encoded(hostile))")
        guard case .focusTerminal(let origin) = found.first?.kind else {
            Issue.record("No way back")
            return
        }
        #expect(origin.tty == hostile)
        #expect(origin.script == nil)
    }

    @Test func tmuxGetsTheApp() throws {
        let found = try actions("terminal=tmux&bundle=com.googlecode.iterm2&folder=%2Fwork")
        #expect(found.map(\.title) == ["Back to iTerm"])
    }

    @Test func theDesktopAppNeedsOnlyItsBundleID() throws {
        #expect(try actions("bundle=com.anthropic.claudefordesktop").map(\.title) == ["Back to Claude"])
    }
}

/// The real `scripts/dynotch` and the real zsh hook, with stand-ins for what they call. No real `open`
/// is on the path, so no link ever leaves the test, and the environment is only what's written here.
struct LongCommandHookTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Writes its arguments to `$DYNOTCH_TEST_LOG`, a line each. Renamed into place, since the hook doesn't wait for it.
    private static let recorder = """
        #!/bin/sh
        for argument in "$@"; do printf '%s\\n' "$argument"; done > "$DYNOTCH_TEST_LOG.part"
        mv "$DYNOTCH_TEST_LOG.part" "$DYNOTCH_TEST_LOG"

        """

    private final class Stage {
        let scratch: Scratch
        let bin: URL
        let log: URL

        init() throws {
            scratch = try Scratch()
            bin = scratch.folder.appendingPathComponent("bin", isDirectory: true)
            log = scratch.folder.appendingPathComponent("log")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            for tool in ["od", "tr", "sed", "mv"] {
                let path = ["/usr/bin/\(tool)", "/bin/\(tool)"].first(where: FileManager.default.isExecutableFile) ?? ""
                try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent(tool), withDestinationURL: URL(fileURLWithPath: path))
            }
        }

        func install(_ script: String, as name: String, in folder: URL? = nil) throws {
            let file = (folder ?? bin).appendingPathComponent(name)
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }

        func copy(_ path: String, to name: String) throws {
            let destination = scratch.folder.appendingPathComponent(name)
            try FileManager.default.copyItem(at: LongCommandHookTests.root.appendingPathComponent(path), to: destination)
        }

        /// What the recorder heard, once it has.
        func heard() throws -> [String] {
            let deadline = Date.now.addingTimeInterval(10)
            while !FileManager.default.fileExists(atPath: log.path), Date.now < deadline { usleep(10_000) }
            return try String(contentsOf: log, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
        }

        var environment: [String: String] {
            ["PATH": bin.path, "HOME": scratch.folder.path, "DYNOTCH_TEST_LOG": log.path, "DYNOTCH_LONG_COMMAND": "0"]
        }

        /// Sources the hook in a real interactive zsh, which runs one command and leaves. With the
        /// threshold at nothing every line after the hook sends a notice, so the setting up comes
        /// first. `TTY` is zsh's own to set, so it's set in the session rather than passed in.
        func runHook(command: String = "make", exitCode: Int32, environment extra: [String: String] = [:], tty: String? = nil,
                     in folder: URL? = nil) throws {
            let lines = ["make() { return \(exitCode) }", "TTY=\(tty ?? "")", "source \(scratch.folder.path)/notify-long-commands.zsh",
                         command, "exit"]
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-f", "-i"]
            process.environment = environment.merging(extra) { $1 }
            process.currentDirectoryURL = folder ?? scratch.folder
            let input = Pipe()
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            input.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
            input.fileHandleForWriting.closeFile()
            process.waitUntilExit()
        }

        /// The hook on its own, calling a recorder found on the PATH.
        static func withRecorder() throws -> Stage {
            let stage = try Stage()
            try stage.copy("scripts/notify-long-commands.zsh", to: "notify-long-commands.zsh")
            try stage.install(recorder, as: "dynotch")
            return stage
        }

        /// The hook beside the real `dynotch`, which calls a recorder in place of `open`.
        static func withRealCommand() throws -> Stage {
            let stage = try Stage()
            try stage.copy("scripts/notify-long-commands.zsh", to: "notify-long-commands.zsh")
            try stage.copy("scripts/dynotch", to: "dynotch")
            try stage.install(recorder, as: "open")
            return stage
        }
    }

    private func value(of flag: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    }

    private func realPath(_ url: URL) -> String {
        url.path.withCString { path in
            guard let resolved = realpath(path, nil) else { return url.path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    /// Parses a link the way `URLCommands.handle` does.
    private func origin(in arguments: [String]) throws -> TerminalOrigin {
        #expect(arguments.first == "-g")
        let link = try #require(arguments.last)
        let items = try #require(URLComponents(string: link)?.queryItems)
        let value = { (name: String) in items.first { $0.name == name }?.value }
        return TerminalOrigin(program: value("terminal"), bundleID: value("bundle"), sessionID: value("session"),
                              tty: value("tty"), folder: value("folder"))
    }

    @Test func aFailedCommandInITermSaysWhereItRan() throws {
        let stage = try Stage.withRecorder()
        try stage.runHook(exitCode: 2, environment: ["TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": sessionID, "TERM_SESSION_ID": "other",
                                                     "__CFBundleIdentifier": "com.googlecode.iterm2"], tty: "/dev/ttys042")
        let heard = try stage.heard()
        #expect(Array(heard.prefix(2)) == ["notify", "Failed"])
        #expect(value(of: "--symbol", in: heard) == "xmark.octagon.fill")
        #expect(value(of: "--tint", in: heard) == "red")
        #expect(value(of: "--terminal", in: heard) == "iTerm.app")
        #expect(value(of: "--session", in: heard) == sessionID)
        #expect(value(of: "--tty", in: heard) == "/dev/ttys042")
        #expect(value(of: "--bundle", in: heard) == "com.googlecode.iterm2")
        #expect(value(of: "--folder", in: heard) == realPath(stage.scratch.folder))
    }

    @Test func aDoneCommandSaysTheSameAndTerminalsSessionIsUsed() throws {
        let stage = try Stage.withRecorder()
        try stage.runHook(exitCode: 0, environment: ["TERM_PROGRAM": "Apple_Terminal", "TERM_SESSION_ID": "E9A3A9C8-0000",
                                                     "__CFBundleIdentifier": "com.apple.Terminal"], tty: "/dev/ttys007")
        let heard = try stage.heard()
        #expect(Array(heard.prefix(2)) == ["notify", "Done"])
        #expect(value(of: "--tint", in: heard) == "green")
        #expect(value(of: "--terminal", in: heard) == "Apple_Terminal")
        #expect(value(of: "--session", in: heard) == "E9A3A9C8-0000")
        #expect(value(of: "--tty", in: heard) == "/dev/ttys007")
        #expect(value(of: "--bundle", in: heard) == "com.apple.Terminal")
    }

    @Test func whatIsntSetIsLeftOut() throws {
        let stage = try Stage.withRecorder()
        try stage.runHook(exitCode: 0)
        let heard = try stage.heard()
        #expect(value(of: "--folder", in: heard) == realPath(stage.scratch.folder))
        for flag in ["--terminal", "--session", "--tty", "--bundle"] {
            #expect(!heard.contains(flag))
        }
    }

    @Test func insideTmuxOnlyTheMarkerAndTheAppGoAlong() throws {
        let stage = try Stage.withRecorder()
        try stage.runHook(exitCode: 1, environment: ["TMUX": "/private/tmp/tmux-501/default,123,0", "TERM_PROGRAM": "tmux",
                                                     "ITERM_SESSION_ID": sessionID, "__CFBundleIdentifier": "com.googlecode.iterm2"],
                          tty: "/dev/ttys042")
        let heard = try stage.heard()
        #expect(value(of: "--terminal", in: heard) == "tmux")
        #expect(value(of: "--bundle", in: heard) == "com.googlecode.iterm2")
        #expect(!heard.contains("--session"))
        #expect(!heard.contains("--tty"))
    }

    @Test func tmuxThatLeavesTheProgramAloneIsMarkedToo() throws {
        let stage = try Stage.withRecorder()
        try stage.runHook(exitCode: 1, environment: ["TMUX": "/private/tmp/tmux-501/default,123,0", "TERM_PROGRAM": "iTerm.app"])
        #expect(value(of: "--terminal", in: try stage.heard()) == "tmux")
    }

    @Test func theNoticeStillNamesOnlyTheCommand() throws {
        let stage = try Stage.withRecorder()
        try stage.runHook(command: "make deploy TOKEN=hunter2", exitCode: 1, environment: ["TERM_PROGRAM": "iTerm.app"])
        let heard = try stage.heard()
        #expect(value(of: "--detail", in: heard)?.hasPrefix("make · ") == true)
        #expect(!heard.joined(separator: " ").contains("hunter2"))
    }

    @Test func aFailedMakeReachesAButtonFromEndToEnd() throws {
        // The hook, the real `dynotch` beside it, the link, and the origin parsed back out of it.
        let stage = try Stage.withRealCommand()
        let folder = stage.scratch.folder.appendingPathComponent("it's a \"folder\" ünï", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try stage.runHook(exitCode: 2, environment: ["TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": sessionID,
                                                     "__CFBundleIdentifier": "com.googlecode.iterm2"], tty: "/dev/ttys042", in: folder)
        let origin = try origin(in: try stage.heard())
        #expect(origin == TerminalOrigin(program: "iTerm.app", bundleID: "com.googlecode.iterm2", sessionID: sessionID,
                                         tty: "/dev/ttys042", folder: realPath(folder)))
        #expect(origin.title == "Back to iTerm")
        #expect(origin.script?.arguments == [sessionUUID])
    }

    private func dynotch(_ arguments: [String], in stage: Stage) throws -> Int32 {
        let process = Process()
        process.executableURL = stage.scratch.folder.appendingPathComponent("dynotch")
        process.arguments = arguments
        process.environment = stage.environment
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test func theCommandPutsEveryFlagOnTheLink() throws {
        let stage = try Stage.withRealCommand()
        #expect(try dynotch(["notify", "Done", "--terminal", "ghostty", "--session", "abc", "--tty", "/dev/ttys001",
                             "--folder", "/a b", "--bundle", "com.mitchellh.ghostty"], in: stage) == 0)
        let heard = try stage.heard()
        #expect(try origin(in: heard) == TerminalOrigin(program: "ghostty", bundleID: "com.mitchellh.ghostty", sessionID: "abc",
                                                        tty: "/dev/ttys001", folder: "/a b"))
        #expect(heard.last?.hasPrefix("dynotch://notify?text=%44%6f%6e%65&terminal=") == true)
    }

    @Test(arguments: hostileValues.filter { !$0.contains("\0") && !$0.isEmpty })
    func aHostileFlagIsEncodedLikeAnyOther(value: String) throws {
        let stage = try Stage.withRealCommand()
        #expect(try dynotch(["notify", "Done", "--tty", value, "--folder", value], in: stage) == 0)
        let heard = try stage.heard()
        let link = try #require(heard.last)
        #expect(!link.contains("\""))
        #expect(!link.contains(" "))
        #expect(!link.contains("\\"))
        let origin = try origin(in: heard)
        #expect(origin.tty == value)
        #expect(origin.folder == value)
    }

    @Test func aFlagWithNoValueIsWrongUse() throws {
        let stage = try Stage.withRealCommand()
        #expect(try dynotch(["notify", "Done", "--tty"], in: stage) == 1)
        #expect(!FileManager.default.fileExists(atPath: stage.log.path))
    }

    @Test func theUsageShowsTheFlagsAndStopsAtItsEnd() throws {
        let process = Process()
        process.executableURL = Self.root.appendingPathComponent("scripts/dynotch")
        process.arguments = ["--help"]
        process.environment = ["PATH": "/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(text.contains("[--terminal NAME] [--session ID] [--tty PATH] [--folder PATH] [--bundle ID]"))
        #expect(text.contains("gets no button"))
        #expect(!text.contains("set -euo"))
    }
}

@MainActor
@Suite(.serialized)
struct LinkNumberTests {
    /// `.seconds(NaN)` traps, and any page can open a link.
    @Test(arguments: ["nan", "inf", "-inf", "1e999"])
    func aNoticeForATimeThatIsntOneStillShows(seconds: String) async throws {
        SnapshotRenderer.useScratchDefaults()
        URLCommands.handle(try #require(URL(string: "dynotch://notify?text=x&seconds=\(seconds)")))
        // The notice's clock has to have started for this to fail.
        try await Task.sleep(for: .milliseconds(50))
        LiveActivityCenter.shared.dismissNotice()
    }
}
