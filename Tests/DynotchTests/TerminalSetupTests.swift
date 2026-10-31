import Darwin
import Foundation
import Testing
@testable import Dynotch

struct OrderedJSONTests {
    private let claudeSettings = """
    {
      "model": "claude-fable-5-1[1m]",
      "hooks": {
        "SessionStart": [
          {
            "matcher": "^(startup|resume|clear|compact|fork)$",
            "hooks": [
              {
                "type": "command",
                "command": "bash '/Users/sample/.claude/hooks/herdr-agent-state.sh' session",
                "timeout": 10
              }
            ]
          }
        ]
      },
      "enabledPlugins": {},
      "extraKnownMarketplaces": [],
      "effortLevel": "max",
      "skipWorkflowUsageWarning": true,
      "number": -1.5e3,
      "nothing": null,
      "escapes": "a \\"quoted\\" \\\\ path\\n\\u00e9"
    }
    """

    @Test func aFileFromJSONStringifyComesBackByteForByte() throws {
        #expect(try OrderedJSON(parsing: claudeSettings).printed() == claudeSettings)
    }

    @Test func keysKeepTheirOrder() throws {
        let json = try OrderedJSON(parsing: #"{"z": 1, "a": 2, "m": 3}"#)
        guard case .object(let members) = json else { Issue.record("Not an object"); return }
        #expect(members.map(\.key) == ["z", "a", "m"])
    }

    @Test func aNewKeyGoesLast() throws {
        var json = try OrderedJSON(parsing: #"{"z": 1}"#)
        json["a"] = .literal("2")
        #expect(json.printed() == "{\n  \"z\": 1,\n  \"a\": 2\n}")
    }

    @Test func aKeyCanBeRemovedAndChanged() throws {
        var json = try OrderedJSON(parsing: #"{"a": 1, "b": 2}"#)
        json["a"] = nil
        json["b"] = .literal("3")
        #expect(json.printed() == "{\n  \"b\": 3\n}")
    }

    @Test func escapesAreWorkedOutForReading() throws {
        let json = try OrderedJSON(parsing: #"{"a": "x \"y\" \\ \n \u00e9"}"#)
        #expect(json["a"]?.stringValue == "x \"y\" \\ \n é")
    }

    @Test func textIsEscapedForWriting() throws {
        let original = "a \"b\" \\ c\nd\te\u{1}f é"
        let json = OrderedJSON.object([.init(key: "k", value: .text(original))])
        #expect(try OrderedJSON(parsing: json.printed())["k"]?.stringValue == original)
        let check = try JSONSerialization.jsonObject(with: Data(json.printed().utf8)) as? [String: String]
        #expect(check?["k"] == original)
    }

    @Test(arguments: ["", "{", "}", #"{"a"}"#, #"{"a": }"#, #"{"a": 1,}"#, "[1,]", #"{"a": 1} extra"#, "01", "1.", "nul", #"{"a": "b"#,
                      "{\"a\": \"line\nbreak\"}", "// comment\n{}", String(repeating: "[", count: 100)])
    func whatIsntJSONIsRefused(text: String) {
        #expect(throws: OrderedJSON.Failure.malformed) { try OrderedJSON(parsing: text) }
    }

    @Test(arguments: ["{}", "[]", "[1, 2]", "true", "null", "0", "-0.5", "1e5", #""text""#, #"{"a": {"b": [{}]}}"#])
    func whatIsJSONIsRead(text: String) throws {
        let json = try OrderedJSON(parsing: text)
        #expect(try JSONSerialization.jsonObject(with: Data(json.printed().utf8), options: .fragmentsAllowed) as Any? != nil)
    }
}

/// A home folder and an app of its own, never the real ones.
private final class ScratchHome {
    let root: URL
    var home: URL { root.appendingPathComponent("home") }
    var resources: URL { root.appendingPathComponent("Applications/Dynotch.app/Contents/Resources") }
    var setup: TerminalSetup { TerminalSetup(home: home, resources: resources) }

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dynotch-setup-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func write(_ text: String, to path: String, mode: mode_t = 0o644) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: false, encoding: .utf8)
        #expect(chmod(url.path, mode) == 0)
    }

    func read(_ path: String) -> String? {
        try? String(contentsOf: home.appendingPathComponent(path), encoding: .utf8)
    }

    func mode(_ path: String) -> mode_t {
        var info = stat()
        _ = stat(home.appendingPathComponent(path).path, &info)
        return info.st_mode & 0o777
    }

    func install(_ items: Set<SetupItem> = Set(SetupItem.allCases)) throws {
        try setup.install(items, reviewed: setup.fingerprint)
    }

    func undo(_ items: Set<SetupItem> = Set(SetupItem.allCases)) throws {
        try setup.undo(items, reviewed: setup.fingerprint)
    }

    func settings() throws -> [String: Any] {
        let text = try #require(read(".claude/settings.json"))
        return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}

/// What's in `~/.claude/settings.json` on the Mac this was built on, in shape.
private let herdrSettings = """
{
  "model": "claude-fable-5-1[1m]",
  "hooks": {
    "SessionStart": [
      {
        "matcher": "^(startup|resume|clear|compact|fork)$",
        "hooks": [
          {
            "type": "command",
            "command": "bash '/Users/sample/.claude/hooks/herdr-agent-state.sh' session",
            "timeout": 10
          }
        ]
      }
    ]
  },
  "effortLevel": "max"
}

"""

struct TerminalSetupTests {
    @Test func aFreshHomeHasNothingInstalled() {
        let scratch = ScratchHome()
        for item in SetupItem.allCases { #expect(scratch.setup.state(of: item) == .notInstalled) }
    }

    @Test func nothingIsWrittenUntilAsked() {
        let scratch = ScratchHome()
        _ = scratch.setup.installChanges(for: Set(SetupItem.allCases))
        _ = scratch.setup.undoChanges(for: Set(SetupItem.allCases))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: scratch.home.path)) == [])
    }

    @Test func everyChangeIsShownFirst() {
        let scratch = ScratchHome()
        let changes = scratch.setup.installChanges(for: Set(SetupItem.allCases))
        #expect(changes.map(\.item) == SetupItem.allCases)
        #expect(changes.allSatisfy { !$0.summary.isEmpty && !$0.text.isEmpty })
        #expect(changes[1].text.contains(TerminalSetup.blockStart))
        #expect(changes[2].text.contains("PermissionRequest"))
        #expect(changes[3].text.hasSuffix("statusline"))
    }

    @Test func whatHooksNeedComesAlongAndIsShown() {
        let scratch = ScratchHome()
        #expect(scratch.setup.installChanges(for: [.claudeHooks]).map(\.item) == [.command, .claudeHooks])
    }

    @Test func allOfItGoesIn() throws {
        let scratch = ScratchHome()
        try scratch.install()
        for item in SetupItem.allCases { #expect(scratch.setup.state(of: item) == .installed) }
    }

    @Test func theCommandIsALinkIntoLocalBin() throws {
        let scratch = ScratchHome()
        try scratch.install([.command])
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: scratch.setup.linkURL.path)
        #expect(target == scratch.resources.appendingPathComponent("dynotch").path)
    }

    @Test func aFileInItsPlaceStays() throws {
        let scratch = ScratchHome()
        try scratch.write("#!/bin/sh\n", to: ".local/bin/dynotch")
        #expect(scratch.setup.state(of: .command) == .blocked("~/.local/bin/dynotch is something else, so it stays."))
        try scratch.install()
        #expect(scratch.read(".local/bin/dynotch") == "#!/bin/sh\n")
    }

    @Test func someoneElsesLinkStays() throws {
        let scratch = ScratchHome()
        try FileManager.default.createDirectory(at: scratch.setup.linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: scratch.setup.linkURL.path, withDestinationPath: "/usr/local/bin/other")
        guard case .blocked = scratch.setup.state(of: .command) else { Issue.record("Not blocked"); return }
        try scratch.install([.command])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: scratch.setup.linkURL.path) == "/usr/local/bin/other")
    }

    @Test func aLinkToAnAppThatMovedIsFixed() throws {
        let scratch = ScratchHome()
        try FileManager.default.createDirectory(at: scratch.setup.linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: scratch.setup.linkURL.path,
                                                   withDestinationPath: "/Downloads/Dynotch.app/Contents/Resources/dynotch")
        #expect(scratch.setup.state(of: .command) == .outOfDate)
        try scratch.install([.command])
        #expect(scratch.setup.state(of: .command) == .installed)
    }

    @Test func aMissingZshrcIsMade() throws {
        let scratch = ScratchHome()
        try scratch.install([.longCommands])
        let text = try #require(scratch.read(".zshrc"))
        #expect(text.hasPrefix(TerminalSetup.blockStart))
        #expect(text.contains("notify-long-commands.zsh"))
        #expect(text.hasSuffix(TerminalSetup.blockEnd + "\n"))
    }

    @Test func theBlockGoesBesideWhatsThere() throws {
        let scratch = ScratchHome()
        let original = "export EDITOR=vim\nalias ll='ls -l'\n"
        try scratch.write(original, to: ".zshrc")
        try scratch.install([.longCommands])
        let text = try #require(scratch.read(".zshrc"))
        #expect(text.hasPrefix(original + "\n" + TerminalSetup.blockStart))
    }

    @Test(arguments: ["export EDITOR=vim\n", "no newline at the end", "# Just a comment\n\n\n", "\n"])
    func undoingLeavesZshrcAsItWas(original: String) throws {
        let scratch = ScratchHome()
        try scratch.write(original, to: ".zshrc")
        try scratch.install([.longCommands])
        try scratch.undo([.longCommands])
        let text = try #require(scratch.read(".zshrc"))
        // A file with no last newline gets one, and nothing else changes.
        #expect(text == (original.hasSuffix("\n") ? original : original + "\n"))
    }

    @Test func aMissingZshrcComesBackEmpty() throws {
        let scratch = ScratchHome()
        try scratch.install([.longCommands])
        try scratch.undo([.longCommands])
        #expect(scratch.read(".zshrc") == "")
    }

    @Test func linesAddedAfterTheBlockSurviveUndoing() throws {
        let scratch = ScratchHome()
        try scratch.write("first\n", to: ".zshrc")
        try scratch.install([.longCommands])
        try scratch.write(try #require(scratch.read(".zshrc")) + "added later\n", to: ".zshrc")
        try scratch.undo([.longCommands])
        #expect(scratch.read(".zshrc") == "first\n\nadded later\n")
    }

    @Test func installingTwiceAddsOneBlock() throws {
        let scratch = ScratchHome()
        try scratch.install([.longCommands])
        let once = scratch.read(".zshrc")
        try scratch.install([.longCommands])
        #expect(scratch.read(".zshrc") == once)
    }

    @Test func anAppThatMovedUpdatesTheBlockInPlace() throws {
        let scratch = ScratchHome()
        try scratch.install([.longCommands])
        let moved = TerminalSetup(home: scratch.home, resources: scratch.root.appendingPathComponent("Elsewhere/Dynotch.app/Contents/Resources"))
        #expect(moved.state(of: .longCommands) == .outOfDate)
        try moved.install([.longCommands], reviewed: moved.fingerprint)
        let text = try #require(scratch.read(".zshrc"))
        #expect(text.contains("Elsewhere"))
        #expect(!text.contains("/Applications/"))
        #expect(text.components(separatedBy: TerminalSetup.blockStart).count == 2)
    }

    @Test func aBlockMissingAMarkerIsLeftAlone() throws {
        let scratch = ScratchHome()
        let broken = "\(TerminalSetup.blockStart)\nsomething\n"
        try scratch.write(broken, to: ".zshrc")
        guard case .blocked = scratch.setup.state(of: .longCommands) else { Issue.record("Not blocked"); return }
        try scratch.install([.longCommands])
        try scratch.undo([.longCommands])
        #expect(scratch.read(".zshrc") == broken)
    }

    @Test func thePathLineOnlyGoesInWhenNeeded() throws {
        let scratch = ScratchHome()
        try scratch.install([.longCommands])
        #expect(scratch.read(".zshrc")?.contains("export PATH") == true)

        let other = ScratchHome()
        try other.write("export PATH=\"$HOME/.local/bin:$PATH\"\n", to: ".zshrc")
        try other.install([.longCommands])
        #expect(other.read(".zshrc")?.components(separatedBy: "export PATH").count == 2)

        let commented = ScratchHome()
        try commented.write("# export PATH=\"$HOME/.local/bin:$PATH\"\n", to: ".zshrc")
        try commented.install([.longCommands])
        #expect(commented.read(".zshrc")?.components(separatedBy: "export PATH").count == 3)
    }

    @Test func aPathWithASpaceIsQuoted() throws {
        #expect(TerminalSetup.quoted("/Applications/Dynotch.app") == "/Applications/Dynotch.app")
        #expect(TerminalSetup.quoted("/Users/a b/x") == "'/Users/a b/x'")
        #expect(TerminalSetup.quoted("/Users/o'brien/x") == "'/Users/o'\\''brien/x'")
    }

    @Test func aZshrcBehindALinkStaysALink() throws {
        let scratch = ScratchHome()
        try scratch.write("real\n", to: "dotfiles/zshrc")
        try FileManager.default.createSymbolicLink(atPath: scratch.setup.zshrcURL.path,
                                                   withDestinationPath: scratch.home.appendingPathComponent("dotfiles/zshrc").path)
        try scratch.install([.longCommands])
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: scratch.setup.zshrcURL.path)) != nil)
        #expect(scratch.read("dotfiles/zshrc")?.contains(TerminalSetup.blockStart) == true)
    }

    @Test func aFilesPermissionsStay() throws {
        let scratch = ScratchHome()
        try scratch.write("x\n", to: ".zshrc", mode: 0o600)
        try scratch.write(herdrSettings, to: ".claude/settings.json", mode: 0o640)
        try scratch.install()
        #expect(scratch.mode(".zshrc") == 0o600)
        #expect(scratch.mode(".claude/settings.json") == 0o640)
    }

    @Test func aNewSettingsFileIsPrivate() throws {
        let scratch = ScratchHome()
        try scratch.install([.claudeHooks])
        #expect(scratch.mode(".claude/settings.json") == 0o600)
    }

    @Test func hooksGoBesideHerdrs() throws {
        let scratch = ScratchHome()
        try scratch.write(herdrSettings, to: ".claude/settings.json", mode: 0o600)
        try scratch.install([.claudeHooks])
        let hooks = try #require(try scratch.settings()["hooks"] as? [String: [[String: Any]]])
        let start = try #require(hooks["SessionStart"])
        #expect(start.count == 2)
        #expect(start[0]["matcher"] as? String == "^(startup|resume|clear|compact|fork)$")
        let herdr = try #require((start[0]["hooks"] as? [[String: Any]])?.first)
        #expect(herdr["command"] as? String == "bash '/Users/sample/.claude/hooks/herdr-agent-state.sh' session")
        #expect(herdr["timeout"] as? Int == 10)
        for event in AgentHook.events { #expect(hooks[event.name] != nil, "\(event.name)") }
    }

    @Test func onlyAPermissionRequestWaits() throws {
        let scratch = ScratchHome()
        try scratch.install([.claudeHooks])
        let hooks = try #require(try scratch.settings()["hooks"] as? [String: [[String: Any]]])
        for event in AgentHook.events {
            let handler = try #require((hooks[event.name]?.first?["hooks"] as? [[String: Any]])?.first)
            #expect(handler["type"] as? String == "command")
            #expect(handler["command"] as? String == scratch.setup.hookCommand)
            if event.waits {
                #expect(handler["timeout"] as? Int == 600)
                #expect(handler["async"] == nil)
            } else {
                #expect(handler["async"] as? Bool == true)
            }
        }
        #expect(AgentHook.events.filter(\.waits).map(\.name) == ["PermissionRequest"])
    }

    @Test func undoingHooksLeavesSettingsByteForByte() throws {
        let scratch = ScratchHome()
        try scratch.write(herdrSettings, to: ".claude/settings.json", mode: 0o600)
        try scratch.install([.claudeHooks, .claudeStatusLine])
        #expect(scratch.read(".claude/settings.json") != herdrSettings)
        try scratch.undo([.claudeHooks, .claudeStatusLine])
        #expect(scratch.read(".claude/settings.json") == herdrSettings)
    }

    @Test func changesMadeInTheMeantimeSurviveUndoing() throws {
        let scratch = ScratchHome()
        try scratch.write(herdrSettings, to: ".claude/settings.json", mode: 0o600)
        try scratch.install([.claudeHooks])
        var document = try OrderedJSON(parsing: try #require(scratch.read(".claude/settings.json")))
        document["theme"] = .text("dark")
        try scratch.write(document.printed() + "\n", to: ".claude/settings.json")
        try scratch.undo([.claudeHooks])
        let settings = try scratch.settings()
        #expect(settings["theme"] as? String == "dark")
        #expect((settings["hooks"] as? [String: Any])?.count == 1)
    }

    @Test func ahookBesideOursInTheSameGroupStays() throws {
        let scratch = ScratchHome()
        try scratch.install([.claudeHooks])
        var document = try OrderedJSON(parsing: try #require(scratch.read(".claude/settings.json")))
        guard case .array(var groups)? = document["hooks"]?["Stop"], case .array(var handlers)? = groups[0]["hooks"] else {
            Issue.record("No Stop hooks")
            return
        }
        handlers.append(.object([.init(key: "type", value: .text("command")), .init(key: "command", value: .text("say done"))]))
        groups[0]["hooks"] = .array(handlers)
        var hooks = try #require(document["hooks"])
        hooks["Stop"] = .array(groups)
        document["hooks"] = hooks
        try scratch.write(document.printed() + "\n", to: ".claude/settings.json")
        try scratch.undo([.claudeHooks])
        let stop = try #require((try scratch.settings()["hooks"] as? [String: [[String: Any]]])?["Stop"])
        #expect((stop.first?["hooks"] as? [[String: Any]])?.map { $0["command"] as? String } == ["say done"])
    }

    @Test func undoingAnEmptyHomesHooksLeavesNoHooksKey() throws {
        let scratch = ScratchHome()
        try scratch.install([.claudeHooks])
        try scratch.undo([.claudeHooks])
        #expect(try scratch.settings().isEmpty)
    }

    @Test func installingHooksTwiceAddsThemOnce() throws {
        let scratch = ScratchHome()
        try scratch.install([.claudeHooks])
        let once = scratch.read(".claude/settings.json")
        try scratch.install([.claudeHooks])
        #expect(scratch.read(".claude/settings.json") == once)
    }

    @Test func aMissingHookIsPutBack() throws {
        let scratch = ScratchHome()
        try scratch.install([.claudeHooks])
        var document = try OrderedJSON(parsing: try #require(scratch.read(".claude/settings.json")))
        var hooks = try #require(document["hooks"])
        hooks["Stop"] = nil
        document["hooks"] = hooks
        try scratch.write(document.printed() + "\n", to: ".claude/settings.json")
        #expect(scratch.setup.state(of: .claudeHooks) == .outOfDate)
        try scratch.install([.claudeHooks])
        #expect(scratch.setup.state(of: .claudeHooks) == .installed)
    }

    @Test func aStatusLineYouHaveStays() throws {
        let scratch = ScratchHome()
        let original = """
        {
          "statusLine": {
            "type": "command",
            "command": "my-status",
            "padding": 2
          }
        }

        """
        try scratch.write(original, to: ".claude/settings.json")
        #expect(scratch.setup.state(of: .claudeStatusLine) == .blocked("You have a status line already, so it stays."))
        #expect(scratch.setup.installChanges(for: [.claudeStatusLine]).filter { $0.item == .claudeStatusLine }.isEmpty)
        try scratch.install([.claudeStatusLine])
        try scratch.undo([.claudeStatusLine])
        #expect(scratch.read(".claude/settings.json") == original)
    }

    @Test func settingsThatArentJSONAreLeftAlone() throws {
        let scratch = ScratchHome()
        let broken = "{ \"model\": oops\n"
        try scratch.write(broken, to: ".claude/settings.json")
        #expect(scratch.setup.state(of: .claudeHooks) == .blocked("~/.claude/settings.json isn't valid JSON, so it stays."))
        try scratch.install([.claudeHooks, .claudeStatusLine])
        #expect(scratch.read(".claude/settings.json") == broken)
    }

    @Test func settingsThatArentAnObjectAreLeftAlone() throws {
        let scratch = ScratchHome()
        try scratch.write("[1, 2]\n", to: ".claude/settings.json")
        guard case .blocked = scratch.setup.state(of: .claudeHooks) else { Issue.record("Not blocked"); return }
    }

    @Test func oddHooksAreToldApart() throws {
        let scratch = ScratchHome()
        try scratch.write("{\n  \"hooks\": 4\n}\n", to: ".claude/settings.json")
        #expect(throws: TerminalSetup.Failure.self) { try scratch.install([.claudeHooks]) }
        #expect(scratch.read(".claude/settings.json") == "{\n  \"hooks\": 4\n}\n")
    }

    @Test func aChangeAfterTheReviewStopsTheInstall() throws {
        let scratch = ScratchHome()
        try scratch.write("before\n", to: ".zshrc")
        let reviewed = scratch.setup.fingerprint
        try scratch.write("changed\n", to: ".zshrc")
        #expect(throws: TerminalSetup.Failure.changedSinceReview) {
            try scratch.setup.install([.longCommands], reviewed: reviewed)
        }
        #expect(scratch.read(".zshrc") == "changed\n")
    }

    @Test func aChangeAfterTheReviewStopsTheUndo() throws {
        let scratch = ScratchHome()
        try scratch.install([.longCommands])
        let reviewed = scratch.setup.fingerprint
        try scratch.write("changed\n", to: ".zshrc")
        #expect(throws: TerminalSetup.Failure.changedSinceReview) {
            try scratch.setup.undo([.longCommands], reviewed: reviewed)
        }
    }

    @Test func undoingEverythingLeavesAFreshHomeFresh() throws {
        let scratch = ScratchHome()
        try scratch.install()
        try scratch.undo()
        for item in SetupItem.allCases { #expect(scratch.setup.state(of: item) == .notInstalled) }
        #expect(!FileManager.default.fileExists(atPath: scratch.setup.linkURL.path))
    }

    @Test func undoOnlyTakesWhatItWasAskedTo() throws {
        let scratch = ScratchHome()
        try scratch.install()
        try scratch.undo([.claudeStatusLine])
        #expect(scratch.setup.state(of: .claudeStatusLine) == .notInstalled)
        #expect(scratch.setup.state(of: .claudeHooks) == .installed)
        #expect(scratch.setup.state(of: .command) == .installed)
    }

    @Test func whatWasThereIsBackedUp() throws {
        let scratch = ScratchHome()
        try scratch.write("mine\n", to: ".zshrc")
        try scratch.install([.longCommands])
        let copies = try FileManager.default.contentsOfDirectory(atPath: scratch.setup.backupsURL.path)
        #expect(copies.count == 1)
        let copy = scratch.setup.backupsURL.appendingPathComponent(try #require(copies.first))
        #expect(try String(contentsOf: copy, encoding: .utf8) == "mine\n")
        var info = stat()
        #expect(stat(copy.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(stat(scratch.setup.backupsURL.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700)
    }

    @Test func onlySoManyBackupsAreKept() throws {
        let scratch = ScratchHome()
        try scratch.write("mine\n", to: ".zshrc")
        for _ in 0..<4 {
            try scratch.install([.longCommands])
            try scratch.undo([.longCommands])
        }
        let copies = try FileManager.default.contentsOfDirectory(atPath: scratch.setup.backupsURL.path)
        #expect(copies.count == 5)
    }

    @Test func nothingScratchIsLeftBesideAFile() throws {
        let scratch = ScratchHome()
        try scratch.install()
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.home.appendingPathComponent(".claude").path) == ["settings.json"])
    }

    @Test func theAppMustBeSomewhereLasting() {
        #expect(TerminalSetup.problem(with: Bundle(path: "/Applications/Safari.app") ?? .main) == nil)
        #expect(TerminalSetup.problem(with: .main) != nil)
    }

    @Test func hooksWontGoInWithSomethingElseAtTheLink() throws {
        let scratch = ScratchHome()
        try scratch.write("#!/bin/sh\n", to: ".local/bin/dynotch")
        guard case .blocked = scratch.setup.state(of: .claudeHooks) else { Issue.record("Not blocked"); return }
        guard case .blocked = scratch.setup.state(of: .claudeStatusLine) else { Issue.record("Not blocked"); return }
        try scratch.install()
        #expect(scratch.read(".claude/settings.json") == nil)
    }

    @Test func hooksCanStillComeOutIfTheLinkWasReplaced() throws {
        let scratch = ScratchHome()
        try scratch.install([.claudeHooks])
        try FileManager.default.removeItem(at: scratch.setup.linkURL)
        try scratch.write("#!/bin/sh\n", to: ".local/bin/dynotch")
        #expect(scratch.setup.canUndo(.claudeHooks))
        try scratch.undo([.claudeHooks])
        #expect(try scratch.settings().isEmpty)
        #expect(scratch.read(".local/bin/dynotch") == "#!/bin/sh\n")
    }

    @Test func removingTheLinkTakesWhatNeedsItToo() throws {
        let scratch = ScratchHome()
        try scratch.write(herdrSettings, to: ".claude/settings.json", mode: 0o600)
        try scratch.install()
        #expect(scratch.setup.undoChanges(for: [.command]).map(\.item) == [.command, .claudeHooks, .claudeStatusLine])
        try scratch.undo([.command])
        #expect(scratch.setup.state(of: .claudeHooks) == .notInstalled)
        #expect(scratch.setup.state(of: .claudeStatusLine) == .notInstalled)
        #expect(scratch.setup.state(of: .longCommands) == .installed)
        #expect(scratch.read(".claude/settings.json") == herdrSettings)
    }
}

@MainActor
struct TerminalSetupModelTests {
    private func model() -> (ScratchHome, TerminalSetupModel) {
        let scratch = ScratchHome()
        return (scratch, TerminalSetupModel(setup: scratch.setup))
    }

    @Test func aReviewStartsWithEverythingThatCanGoIn() {
        let (_, model) = model()
        model.reviewInstall()
        #expect(model.step == .reviewingInstall)
        #expect(model.selection == Set(SetupItem.allCases))
    }

    @Test func nothingHappensUntilInstallIsPressed() {
        let (scratch, model) = model()
        model.reviewInstall()
        model.cancel()
        #expect(model.step == .resting)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: scratch.home.path)) == [])
    }

    @Test func installThenUndo() {
        let (scratch, model) = model()
        model.reviewInstall()
        model.apply()
        #expect(model.step == .resting)
        #expect(model.installedCount == 4)
        #expect(model.message?.hasPrefix("Set up") == true)
        #expect(!model.failed)
        model.reviewUndo()
        model.apply()
        #expect(model.installedCount == 0)
        #expect(!FileManager.default.fileExists(atPath: scratch.setup.linkURL.path))
    }

    @Test func whatTheReviewShowsIsWhatHappens() {
        let (_, model) = model()
        model.reviewInstall()
        // The hooks need the link, so with the link switched off the hooks go too.
        model.toggle(.command)
        #expect(!model.isIncluded(.command))
        #expect(!model.isIncluded(.claudeHooks))
        #expect(!model.isIncluded(.claudeStatusLine))
        #expect(model.isIncluded(.longCommands))
        // Asking for the hooks again brings the link back, and it's on show.
        model.toggle(.claudeHooks)
        #expect(model.isIncluded(.claudeHooks))
        #expect(model.isIncluded(.command))
    }

    @Test func undoKeepsTheLinkWhileSomethingNeedsIt() throws {
        let (scratch, model) = model()
        try scratch.install()
        model.refresh()
        model.reviewUndo()
        model.toggle(.claudeHooks)
        #expect(!model.isIncluded(.claudeHooks))
        #expect(!model.isIncluded(.command))
        #expect(model.isIncluded(.claudeStatusLine))
        model.apply()
        #expect(scratch.setup.state(of: .claudeHooks) == .installed)
        #expect(scratch.setup.state(of: .command) == .installed)
        #expect(scratch.setup.state(of: .claudeStatusLine) == .notInstalled)
    }

    @Test func aFileThatChangedSendsYouBackToLook() throws {
        let (scratch, model) = model()
        try scratch.write("before\n", to: ".zshrc")
        model.reviewInstall()
        try scratch.write("changed\n", to: ".zshrc")
        model.apply()
        #expect(model.step == .reviewingInstall)
        #expect(model.failed)
        #expect(scratch.read(".zshrc") == "changed\n")
        // And the fresh look can go ahead.
        model.apply()
        #expect(model.step == .resting)
        #expect(scratch.read(".zshrc")?.hasPrefix("changed\n") == true)
    }
}
