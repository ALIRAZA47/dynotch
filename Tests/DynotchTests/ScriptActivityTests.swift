import Foundation
import SwiftUI
import Testing
@testable import Dynotch

@MainActor
@Suite(.serialized)
struct ScriptActivityStoreTests {
    private let start = Date(timeIntervalSinceReferenceDate: 0)
    private final class Posted {
        var notices: [(notice: LiveNotice, seconds: TimeInterval)] = []
    }

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func store() -> (ScriptActivityStore, Posted) {
        SnapshotRenderer.useScratchDefaults()
        let posted = Posted()
        return (ScriptActivityStore(post: { posted.notices.append(($0, $1)) }), posted)
    }

    private func request(_ fields: [String: Any]) throws -> SocketRequest {
        var fields = fields
        fields["op"] = "progress"
        return try #require(SocketRequest(line: JSONSerialization.data(withJSONObject: fields)))
    }

    @Test func aScriptStartsAnActivity() {
        let (store, _) = store()
        store.update("deploy", percent: 40, now: at(0))
        #expect(store.activities.map(\.key) == ["deploy"])
        #expect(store.activities.first?.percent == 40)
        #expect(store.activities.first?.fraction == 0.4)
        #expect(store.activities.first?.percentText == "40%")
    }

    @Test func twoScriptsKeepTheirOwnKeys() {
        let (store, _) = store()
        store.update("deploy", percent: 40, now: at(0))
        store.update("backup", percent: 10, now: at(1))
        store.update("deploy", percent: 50, now: at(2))
        #expect(store.activities.map(\.percent) == [50, 10])
    }

    @Test func theFirstStaysInFrontWhileAnotherComesAndGoes() {
        let (store, _) = store()
        store.update("deploy", percent: 40, now: at(0))
        store.update("backup", percent: 10, now: at(1))
        store.update("deploy", percent: 41, now: at(2))
        store.update("backup", percent: 11, now: at(3))
        #expect(store.activities.first?.key == "deploy")
    }

    @Test func whatsLeftOutStaysAsItWas() {
        let (store, _) = store()
        store.update("deploy", percent: 40, detail: "Uploading", symbol: "bolt.fill", tint: .red, now: at(0))
        store.update("deploy", percent: nil, now: at(1))
        let activity = store.activities.first
        #expect(activity?.percent == 40)
        #expect(activity?.detail == "Uploading")
        #expect(activity?.symbol == "bolt.fill")
        #expect(activity?.tint == .red)
    }

    @Test(arguments: [(-5.0, 0), (0.4, 0), (49.5, 50), (100.0, 100), (250.0, 100)])
    func aPercentStaysInRange(input: Double, expected: Int) {
        let (store, _) = store()
        store.update("deploy", percent: input, now: at(0))
        #expect(store.activities.first?.percent == expected)
    }

    @Test(arguments: [Double.nan, .infinity])
    func aPercentThatIsntANumberIsIgnored(input: Double) {
        let (store, _) = store()
        store.update("deploy", percent: 30, now: at(0))
        store.update("deploy", percent: input, now: at(1))
        #expect(store.activities.first?.percent == 30)
    }

    @Test func sayingTheSameAgainRedrawsNothing() {
        let (store, _) = store()
        store.update("deploy", percent: 40, now: at(0))
        var changes = 0
        let watching = store.objectWillChange.sink { changes += 1 }
        store.update("deploy", percent: 40.2, now: at(1))
        withExtendedLifetime(watching) { #expect(changes == 0) }
    }

    @Test func thereAreOnlySoManyAtOnce() {
        let (store, _) = store()
        for index in 0..<ScriptActivityStore.mostActivities {
            #expect(store.update("script \(index)", percent: 1, now: at(0)))
        }
        #expect(!store.update("one too many", percent: 1, now: at(0)))
        #expect(store.activities.count == ScriptActivityStore.mostActivities)
        // One already on keeps going.
        #expect(store.update("script 0", percent: 2, now: at(1)))
    }

    @Test func finishingTakesItDownAndSaysSo() throws {
        let (store, posted) = store()
        store.update("deploy", percent: 90, now: at(0))
        store.finish("deploy", as: .done, detail: "2m 14s")
        #expect(store.activities.isEmpty)
        let notice = try #require(posted.notices.first?.notice)
        #expect(notice.text == "Done")
        #expect(notice.detail == "deploy · 2m 14s")
        #expect(notice.fromScript)
        #expect(notice.key == "script.deploy")
        #expect(notice.tint == .green)
    }

    @Test func failingSaysSoForLonger() throws {
        let (store, posted) = store()
        store.update("deploy", percent: 90, now: at(0))
        store.finish("deploy", as: .failed)
        let (notice, seconds) = try #require(posted.notices.first)
        #expect(notice.text == "Failed")
        #expect(notice.detail == "deploy")
        #expect(notice.tint == .red)
        #expect(notice.fromScript)
        #expect(seconds > 4)
    }

    @Test func aNoticeFromOneScriptDoesntReplaceAnothers() {
        let (store, posted) = store()
        store.finish("deploy", as: .done)
        store.finish("backup", as: .done)
        #expect(Set(posted.notices.map(\.notice.key)).count == 2)
    }

    @Test func aFinishCanCarryALink() throws {
        let (store, posted) = store()
        let answer = store.apply(try request(["key": "deploy", "state": "done", "button": "Open", "url": "https://example.com"]))
        #expect(answer["ok"] as? Bool == true)
        #expect(posted.notices.first?.notice.actions.first?.title == "Open")
    }

    @Test func aFinishWontCarryAnythingButAnHttpsLink() throws {
        let (store, posted) = store()
        _ = store.apply(try request(["key": "deploy", "state": "done", "button": "Open", "url": "file:///etc/passwd"]))
        #expect(posted.notices.first?.notice.actions.isEmpty == true)
    }

    @Test func aScriptThatGoesQuietIsTakenDown() throws {
        let (store, posted) = store()
        store.update("deploy", percent: 40, quietAfter: 30, now: at(0))
        store.expire(now: at(29))
        #expect(store.activities.count == 1)
        store.expire(now: at(30))
        #expect(store.activities.isEmpty)
        let notice = try #require(posted.notices.first?.notice)
        #expect(notice.text == "Went quiet")
        #expect(notice.detail == "deploy")
        #expect(notice.fromScript)
    }

    @Test func aWordFromTheScriptPutsItOff() {
        let (store, _) = store()
        store.update("deploy", percent: 40, quietAfter: 30, now: at(0))
        store.update("deploy", percent: 40, quietAfter: 30, now: at(25))
        store.expire(now: at(40))
        #expect(store.activities.count == 1)
        store.expire(now: at(55))
        #expect(store.activities.isEmpty)
    }

    @Test func quietGoesByDefaultAfterTwoMinutes() {
        let (store, _) = store()
        store.update("deploy", percent: 40, now: at(0))
        store.expire(now: at(ScriptActivityStore.quietAfter - 1))
        #expect(store.activities.count == 1)
        store.expire(now: at(ScriptActivityStore.quietAfter))
        #expect(store.activities.isEmpty)
    }

    @Test(arguments: [(1.0, ScriptActivityStore.shortestQuiet), (999_999.0, ScriptActivityStore.longestQuiet)])
    func patienceHasLimits(asked: Double, allowed: TimeInterval) {
        let (store, _) = store()
        store.update("deploy", percent: 40, quietAfter: asked, now: at(0))
        store.expire(now: at(allowed - 1))
        #expect(store.activities.count == 1)
        store.expire(now: at(allowed))
        #expect(store.activities.isEmpty)
    }

    /// `Task.sleep` traps on a time that isn't a number.
    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func patienceThatIsntANumberIsIgnored(asked: Double) {
        let (store, _) = store()
        store.update("deploy", percent: 40, quietAfter: asked, now: at(0))
        store.expire(now: at(ScriptActivityStore.quietAfter - 1))
        #expect(store.activities.count == 1)
        store.expire(now: at(ScriptActivityStore.quietAfter))
        #expect(store.activities.isEmpty)
    }

    @Test func aQuietScriptCanComeBack() {
        let (store, _) = store()
        store.update("deploy", percent: 40, quietAfter: 10, now: at(0))
        store.expire(now: at(10))
        store.update("deploy", percent: 50, now: at(20))
        #expect(store.activities.first?.percent == 50)
    }

    @Test func clearingSaysNothing() throws {
        let (store, posted) = store()
        store.update("deploy", percent: 40, now: at(0))
        _ = store.apply(try request(["key": "deploy", "state": "clear"]))
        #expect(store.activities.isEmpty)
        #expect(posted.notices.isEmpty)
    }

    @Test func aRequestNeedsAName() throws {
        let (store, _) = store()
        #expect(store.apply(try request(["percent": 4]))["ok"] as? Bool == false)
        #expect(store.apply(try request(["key": "  \n ", "percent": 4]))["ok"] as? Bool == false)
    }

    @Test func aRequestOverTheLimitIsToldSo() throws {
        let (store, _) = store()
        for index in 0..<ScriptActivityStore.mostActivities { store.update("\(index)", percent: 1, now: at(0)) }
        let answer = store.apply(try request(["key": "another", "percent": 4]))
        #expect(answer["ok"] as? Bool == false)
    }

    @Test func aSymbolThatDoesntExistIsLeftOut() throws {
        let (store, _) = store()
        _ = store.apply(try request(["key": "deploy", "percent": 4, "symbol": "no.such.symbol"]))
        #expect(store.activities.first?.symbol == ScriptActivity.defaultSymbol)
    }

    @Test func aSymbolAScriptPickedNeedsTheBadge() {
        #expect(!ScriptActivity(key: "a").needsBadge)
        #expect(ScriptActivity(key: "a", symbol: "bolt.fill").needsBadge)
    }

    @Test func textIsCleanedForOneLine() {
        #expect(ScriptActivityStore.cleaned("  deploy\n\u{1B}[31m ", limit: 32) == "deploy[31m")
        #expect(ScriptActivityStore.cleaned(String(repeating: "a", count: 50), limit: 4) == "aaaa")
        #expect(ScriptActivityStore.cleaned(" \t\n", limit: 4) == nil)
        #expect(ScriptActivityStore.cleaned(nil, limit: 4) == nil)
    }

    @Test func withTheSwitchOffNothingIsSaid() throws {
        let (store, posted) = store()
        AppSettings.shared.liveScripts = false
        defer { AppSettings.shared.liveScripts = true }
        store.update("deploy", percent: 40, quietAfter: 10, now: at(0))
        store.finish("deploy", as: .done)
        store.update("backup", percent: 40, quietAfter: 10, now: at(0))
        store.expire(now: at(10))
        #expect(posted.notices.isEmpty)
    }

    @Test func statusReportsEach() throws {
        let (store, _) = store()
        store.update("deploy", percent: 40, detail: "Uploading", quietAfter: 60, now: at(0))
        store.update("backup", percent: nil, now: at(5))
        let report = store.statusReport(at: at(10))
        #expect(report.count == 2)
        #expect(report[0]["key"] as? String == "deploy")
        #expect(report[0]["percent"] as? Int == 40)
        #expect(report[0]["detail"] as? String == "Uploading")
        #expect(report[0]["secondsRunning"] as? Int == 10)
        #expect(report[0]["secondsLeft"] as? Int == 50)
        #expect(report[1]["percent"] is NSNull)
        #expect(JSONSerialization.isValidJSONObject(report))
    }
}

@MainActor
struct ClosedLayoutScriptTests {
    private let notch = CGSize(width: 185, height: 32)

    @Test func aScriptMakesRoomForTheLineAlongTheFoot() {
        let layout = ClosedLayout(activity: .script(ScriptActivity(key: "deploy", percent: 40)), notch: notch)
        #expect(layout.footHeight == ClosedLayout.footLineHeight + ClosedLayout.footGap)
        #expect(layout.totalHeight == notch.height + layout.footHeight)
    }

    @Test func nothingElseDoes() {
        for activity: ClosedActivity in [.idle, .music, .timer, .download, .stopwatch] {
            #expect(ClosedLayout(activity: activity, notch: notch).footHeight == 0)
        }
    }

    @Test func aLongNameIsCutAtTheEarsWidth() {
        let ten = ClosedLayout(activity: .script(ScriptActivity(key: String(repeating: "a", count: 10))), notch: notch)
        let thirty = ClosedLayout(activity: .script(ScriptActivity(key: String(repeating: "a", count: 30))), notch: notch)
        #expect(ten.earWidth == thirty.earWidth)
    }

    @Test func aGlyphBesideItWidensTheEars() {
        let script = ClosedActivity.script(ScriptActivity(key: "deploy", percent: 40))
        let alone = ClosedLayout(activity: script, notch: notch)
        let beside = ClosedLayout(activity: script, secondary: .timer, notch: notch)
        #expect(beside.earWidth == alone.earWidth + ClosedLayout.glyphSize + ClosedLayout.glyphSpacing)
    }

    @Test func aScriptsGlanceIsItsOwn() {
        let activity = ScriptActivity(key: "deploy", percent: 40)
        #expect(GlanceContent(activity: .script(activity)) == .script(activity))
    }

    @Test func theMainActivityAlreadyShowsItsOwnGlyph() {
        let deploy = ScriptActivity(key: "deploy", percent: 40)
        #expect(CompactActivity.script(deploy).isShown(by: .script(ScriptActivity(key: "deploy", percent: 41))))
        #expect(!CompactActivity.script(deploy).isShown(by: .script(ScriptActivity(key: "backup"))))
    }

    @Test func waitingToolCallsShowEvenWithNothingElse() {
        #expect(CompactActivity.agentsWaiting(2).isStatus)
        #expect(!CompactActivity.script(ScriptActivity(key: "a")).isStatus)
    }
}

@MainActor
@Suite(.serialized)
struct ScriptPriorityTests {
    private func content(with activities: [ScriptActivity]) -> ClosedContent {
        SnapshotRenderer.useScratchDefaults()
        ScriptActivityStore.shared.loadSample(activities)
        // Works out what the closed notch shows, past anything other tests left waiting.
        for _ in 0...NoticeQueue.mostWaiting { LiveActivityCenter.shared.dismissNotice() }
        return LiveActivityCenter.shared.content
    }

    @Test func aScriptTakesTheNotchWhenNothingElseIsOn() {
        defer { _ = content(with: []) }
        let activity = ScriptActivity(key: "deploy", percent: 40)
        #expect(content(with: [activity]).activity == .script(activity))
    }

    @Test func theSwitchTakesItAway() {
        defer {
            AppSettings.shared.liveScripts = true
            _ = content(with: [])
        }
        _ = content(with: [])
        AppSettings.shared.liveScripts = false
        #expect(content(with: [ScriptActivity(key: "deploy", percent: 40)]).activity == .idle)
    }

    @Test func theFirstScriptIsTheOneOnShow() {
        defer { _ = content(with: []) }
        let deploy = ScriptActivity(key: "deploy", percent: 40)
        #expect(content(with: [deploy, ScriptActivity(key: "backup")]).activity == .script(deploy))
    }

    @Test func statusNamesTheKindAndNotTheWords() {
        let notice = LiveNotice(key: "notification", symbol: "message.fill", tint: .green, text: "Anna", detail: "A secret")
        #expect(ClosedActivity.notice(notice).statusName == "notice")
        #expect(ClosedActivity.script(ScriptActivity(key: "deploy")).statusName == "script")
    }
}
