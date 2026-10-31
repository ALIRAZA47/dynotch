import Foundation
import Testing
@testable import Dynotch

private let track = NowPlayingService.Track(title: "Midnight City", artist: "M83", album: "Hurry Up, We're Dreaming", duration: 243.4)
private let other = NowPlayingService.Track(title: "Wait", artist: "M83", album: "Hurry Up, We're Dreaming", duration: 343)

/// Made-up words, in what LRCLIB's documentation shows.
private func record(_ synced: String? = "[00:01.00] One\n[00:02.00] Two\n", instrumental: Bool = false) -> Data {
    let lyrics = synced.map { "\"\($0.replacingOccurrences(of: "\n", with: "\\n"))\"" } ?? "null"
    return Data("""
    {"id":1,"name":"Midnight City","trackName":"Midnight City","artistName":"M83","albumName":"Hurry Up, We're Dreaming",
     "duration":243,"instrumental":\(instrumental),"hasWordSync":false,"plainLyrics":"One\\nTwo\\n","syncedLyrics":\(lyrics),"lyricsfile":"version: '1.0'"}
    """.utf8)
}

private func response(_ status: Int, _ headers: [String: String] = ["Content-Type": "application/json"]) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "https://lrclib.net/api/get")!, statusCode: status, httpVersion: "HTTP/2", headerFields: headers)!
}

struct LyricsParsingTests {
    @Test func aLineAndItsTime() {
        #expect(Lyrics(lrc: "[01:02.50] Hello")?.lines == [.init(time: 62.5, text: "Hello")])
    }

    @Test(arguments: [("[01:02] a", 62.0), ("[01:02.5] a", 62.5), ("[01:02.500] a", 62.5), ("[01:02:50] a", 62.5), ("[100:00.00] a", 6000.0)])
    func waysOfWritingATime(lrc: String, seconds: Double) {
        #expect(Lyrics(lrc: lrc)?.lines.first?.time == seconds)
    }

    @Test func aChorusCanHaveSeveralTimes() {
        #expect(Lyrics(lrc: "[00:10.00][00:30.00] Chorus\n[00:20.00] Verse")?.lines.map(\.text) == ["Chorus", "Verse", "Chorus"])
    }

    @Test func linesComeBackInTheOrderTheyreSung() {
        #expect(Lyrics(lrc: "[00:20.00] Second\n[00:10.00] First")?.lines.map(\.text) == ["First", "Second"])
    }

    @Test func windowsLineEndingsAndTags() {
        let lyrics = Lyrics(lrc: "[ar:M83]\r\n[ti:Midnight City]\r\n[length:04:03]\r\n[00:01.00] One\r\n")
        #expect(lyrics?.lines.map(\.text) == ["One"])
    }

    @Test(arguments: ["", "Just words", "[ar:M83]", "[00:01.00]", "[00:01.00]\n[00:02.00]  ", "[99:99.99] a", "[-1:00.00] a"])
    func nothingWithATimeIsNothing(lrc: String) {
        #expect(Lyrics(lrc: lrc) == nil)
    }

    @Test func whatComesFromAStrangerIsTrimmed() throws {
        let lyrics = try #require(Lyrics(lrc: "[00:01.00] One\u{0007}\u{202E}\n[00:02.00] " + String(repeating: "x", count: 5000)))
        #expect(lyrics.lines[0].text.hasPrefix("One"))
        #expect(!lyrics.lines[0].text.contains("\u{0007}"))
        #expect(lyrics.lines[1].text.count == 300)
        let long = String(repeating: "[00:01.00] a\n", count: 10_000)
        #expect(try #require(Lyrics(lrc: long)).lines.count == 3000)
    }

    @Test func theLineAtAMoment() throws {
        let lyrics = try #require(Lyrics(lrc: "[00:10.00] One\n[00:20.00] Two\n[00:30.00]\n[00:40.00] Three"))
        #expect(lyrics.line(at: 0) == nil)
        #expect(lyrics.line(at: 9.99) == nil)
        #expect(lyrics.line(at: 10) == "One")
        #expect(lyrics.line(at: 19.99) == "One")
        #expect(lyrics.line(at: 20) == "Two")
        #expect(lyrics.line(at: 35) == nil)
        #expect(lyrics.line(at: 40) == "Three")
        #expect(lyrics.line(at: 9999) == "Three")
    }

    @Test func theRowFitsTheLongestLine() throws {
        let short = try #require(Lyrics(lrc: "[00:10.00] One"))
        let long = try #require(Lyrics(lrc: "[00:10.00] One\n[00:20.00] A much longer line than that"))
        #expect(long.rowWidth > short.rowWidth)
    }
}

struct LyricsClientTests {
    private func query(_ track: NowPlayingService.Track) throws -> [String: String] {
        let url = try #require(LyricsClient.request(for: track)?.url)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    /// What goes to a third party, and all of it.
    @Test func itSendsTheFourThingsAndNoMore() throws {
        let request = try #require(LyricsClient.request(for: track, version: "1.5.0"))
        #expect(request.httpMethod == "GET")
        #expect(request.url?.scheme == "https")
        #expect(request.url?.host == "lrclib.net")
        #expect(request.url?.path == "/api/get")
        #expect(try query(track) == ["track_name": "Midnight City", "artist_name": "M83",
                                     "album_name": "Hurry Up, We're Dreaming", "duration": "243"])
        #expect(request.allHTTPHeaderFields == ["User-Agent": "Dynotch v1.5.0 (https://github.com/ALIRAZA47/dynotch)", "Accept": "application/json"])
        #expect(request.httpBody == nil)
    }

    @Test func noAlbumIsLeftOut() throws {
        var track = track
        track.album = ""
        #expect(try query(track)["album_name"] == nil)
    }

    /// It takes 1 to 3600, and answers anything else with a 400.
    @Test(arguments: [0.0, 0.4, 3601.0, 9000.0])
    func aLengthItWontTakeIsLeftOut(duration: TimeInterval) throws {
        var track = track
        track.duration = duration
        #expect(try query(track)["duration"] == nil)
    }

    @Test(arguments: ["", " "].prefix(1))
    func itNeedsATitleAndAnArtist(empty: String) {
        var noTitle = track, noArtist = track
        noTitle.title = empty
        noArtist.artist = empty
        #expect(LyricsClient.request(for: noTitle) == nil)
        #expect(LyricsClient.request(for: noArtist) == nil)
    }

    @Test(arguments: ["C+C Music Factory", "AC/DC & Friends?", "100% = Sigur Rós", "a b#c"])
    func oddCharactersReachTheServerIntact(title: String) throws {
        var track = track
        track.title = title
        #expect(try query(track)["track_name"] == title)
        let url = try #require(LyricsClient.request(for: track)?.url?.absoluteString)
        if title.contains("+") { #expect(url.contains("C%2BC")) }
    }

    // MARK: Answers

    @Test func lyricsWithTimes() {
        guard case .found(let lyrics) = LyricsClient.answer(to: record(), response(200)) else {
            Issue.record("It should have found lyrics")
            return
        }
        #expect(lyrics.lines.map(\.text) == ["One", "Two"])
    }

    @Test func noneOfThoseAreLyrics() {
        #expect(LyricsClient.answer(to: record(nil), response(200)) == .none)
        #expect(LyricsClient.answer(to: record(nil, instrumental: true), response(200)) == .none)
        #expect(LyricsClient.answer(to: record("Plain words with no times"), response(200)) == .none)
        #expect(LyricsClient.answer(to: Data("{}".utf8), response(404)) == .none)
        #expect(LyricsClient.answer(to: Data("{}".utf8), response(400)) == .none)
    }

    @Test func itHonorsWhatItsToldToWait() {
        #expect(LyricsClient.answer(to: Data(), response(429, ["Retry-After": "12"])) == .wait(12))
        #expect(LyricsClient.answer(to: Data(), response(503, ["Retry-After": "1"])) == .wait(1))
        #expect(LyricsClient.answer(to: Data(), response(429, [:])) == .wait(nil))
        #expect(LyricsClient.answer(to: Data(), response(429, ["Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"])) == .wait(nil))
    }

    /// As it answered on 2026-10-31: Cloudflare's own 502, in plain text. That says nothing about the track.
    @Test func aServerFailureSaysNothingAboutTheTrack() {
        #expect(LyricsClient.answer(to: Data("error code: 502".utf8), response(502, ["Content-Type": "text/plain; charset=UTF-8"])) == .failed)
        #expect(LyricsClient.answer(to: Data(), response(500)) == .failed)
    }

    @Test func aBodyThatIsntWhatItSaysIsLeftAlone() {
        #expect(LyricsClient.answer(to: Data("<html>".utf8), response(200, ["Content-Type": "text/html"])) == .failed)
        #expect(LyricsClient.answer(to: Data("not json".utf8), response(200)) == .failed)
        #expect(LyricsClient.answer(to: Data(count: 3_000_000), response(200)) == .failed)
        #expect(LyricsClient.answer(to: record(), URLResponse()) == .failed)
    }
}

struct LyricsLimiterTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func theFirstGoesAtOnce() {
        #expect(LyricsLimiter().wait(at: now) == 0)
    }

    @Test func aGapBetweenRequests() {
        var limiter = LyricsLimiter()
        limiter.noteRequest(at: now)
        #expect(limiter.wait(at: now) == LyricsLimiter.gap)
        #expect(limiter.wait(at: now.addingTimeInterval(LyricsLimiter.gap)) == 0)
    }

    @Test func noMoreThanSoManyAMinute() {
        var limiter = LyricsLimiter()
        for second in 0..<LyricsLimiter.perMinute { limiter.noteRequest(at: now.addingTimeInterval(Double(second))) }
        let next = now.addingTimeInterval(Double(LyricsLimiter.perMinute))
        #expect(limiter.wait(at: next) == 15)
        #expect(limiter.wait(at: now.addingTimeInterval(60)) == 0)
    }

    @Test func aHoldLastsAtLeastWhatWasAsked() {
        var limiter = LyricsLimiter()
        limiter.hold(for: 10, from: now, extra: 0)
        #expect(limiter.wait(at: now) == 10)
        #expect(limiter.wait(at: now.addingTimeInterval(10)) == 0)
    }

    @Test func theJitterIsOnTop() {
        var limiter = LyricsLimiter()
        limiter.hold(for: 10, from: now, extra: 0.3)
        #expect(limiter.wait(at: now) == 13)
        for _ in 0..<50 {
            var limiter = LyricsLimiter()
            limiter.hold(for: 10, from: now)
            #expect((10...13).contains(limiter.wait(at: now)))
        }
    }

    @Test func aShorterHoldDoesntShortenALongerOne() {
        var limiter = LyricsLimiter()
        limiter.hold(for: 30, from: now, extra: 0)
        limiter.hold(for: 1, from: now, extra: 0)
        #expect(limiter.wait(at: now) == 30)
    }
}

/// A stand-in for LRCLIB. Nothing here reaches the network.
private final class Server: @unchecked Sendable {
    private let lock = NSLock()
    private var titles: [String] = []
    private var holding: [CheckedContinuation<Void, Never>] = []
    var isHolding = false
    var answer: @Sendable (String) -> (Data, URLResponse) = { _ in (record(), response(200)) }

    var asked: [String] { lock.withLock { titles } }

    /// Lets the requests that were kept waiting answer.
    func release() {
        let waiting = lock.withLock {
            isHolding = false
            let waiting = holding
            holding = []
            return waiting
        }
        waiting.forEach { $0.resume() }
    }

    var fetch: LyricsClient.Fetch {
        { [self] request in
            let title = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "track_name" }?.value ?? ""
            lock.withLock { titles.append(title) }
            if lock.withLock({ isHolding }) {
                await withCheckedContinuation { continuation in lock.withLock { holding.append(continuation) } }
            }
            return answer(title)
        }
    }
}

@MainActor
@Suite(.serialized)
struct LyricsServiceTests {
    private let server = Server()
    private let service: LyricsService

    init() {
        SnapshotRenderer.useScratchDefaults()
        service = LyricsService(fetch: server.fetch, settle: .milliseconds(5), failureWait: 0.01)
    }

    /// Waits for something that happens off in a task, however long it takes up to a generous limit.
    private func wait(until condition: () -> Bool) async {
        let limit = Date.now.addingTimeInterval(30)
        while !condition(), .now < limit { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// For the track playing, it's got its answer or stopped asking.
    private func finishLookingUp() async {
        await wait { !service.isLookingUp }
    }

    /// Long enough for what shouldn't go out to have gone, if it was going to. Only for showing that
    /// something didn't happen, which a slow Mac can't turn into a failure.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(60))
    }

    private func play(_ track: NowPlayingService.Track) { service.update(track: track, isPlaying: true, isOn: true) }

    @Test func offNothingIsSent() async {
        service.update(track: track, isPlaying: true, isOn: false)
        await settle()
        #expect(server.asked.isEmpty)
        #expect(service.lyrics == nil)
    }

    @Test func itStartsOff() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Dynotch/App/AppSettings.swift")
        #expect(try String(contentsOf: sources, encoding: .utf8).contains(#"AppSettings.value("showsLyrics", false)"#))
        #expect(UserDefaults.dynotch.object(forKey: "showsLyrics") == nil)
    }

    @Test func aPausedTrackGoesNowhere() async {
        service.update(track: track, isPlaying: false, isOn: true)
        await settle()
        #expect(server.asked.isEmpty)
        service.update(track: track, isPlaying: true, isOn: true)
        await wait { service.lyrics != nil }
        #expect(server.asked == ["Midnight City"])
    }

    @Test func aTrackPausedInItsFirstMomentsGoesNowhere() async {
        play(track)
        service.update(track: track, isPlaying: false, isOn: true)
        await settle()
        #expect(server.asked.isEmpty)
    }

    @Test func aPlayingTrackIsAskedAboutOnce() async {
        play(track)
        await wait { service.lyrics != nil }
        #expect(service.lyrics?.lines.map(\.text) == ["One", "Two"])
        play(track)
        service.update(track: track, isPlaying: false, isOn: true)
        play(track)
        await settle()
        #expect(server.asked == ["Midnight City"])
    }

    @Test func aTrackSkippedPastGoesNowhere() async {
        play(track)
        play(other)
        await wait { service.lyrics != nil }
        #expect(server.asked == ["Wait"])
    }

    @Test func anotherLengthFromThePlayerIsTheSameTrack() async {
        play(track)
        var again = track
        again.duration = 243.04
        play(again)
        await wait { service.lyrics != nil }
        #expect(server.asked == ["Midnight City"])
    }

    @Test func comingBackUsesWhatsKept() async {
        play(track)
        await wait { service.lyrics != nil }
        server.answer = { _ in (Data(), response(404)) }
        play(other)
        await finishLookingUp()
        #expect(service.lyrics == nil)
        play(track)
        #expect(service.lyrics != nil)
        play(other)
        await settle()
        #expect(service.lyrics == nil)
        #expect(server.asked == ["Midnight City", "Wait"])
    }

    @Test func noLyricsIsRememberedToo() async {
        server.answer = { _ in (record(nil, instrumental: true), response(200)) }
        play(track)
        await finishLookingUp()
        play(other)
        await finishLookingUp()
        play(track)
        await settle()
        #expect(server.asked == ["Midnight City", "Wait"])
    }

    /// As it did on 2026-10-31: nothing about the track, so it isn't kept, and it stops after a few tries.
    @Test func aFailureIsTriedAFewTimesAndNotRemembered() async {
        server.answer = { _ in (Data("error code: 502".utf8), response(502, ["Content-Type": "text/plain"])) }
        play(track)
        await finishLookingUp()
        #expect(server.asked.count == LyricsService.tries)
        #expect(service.lyrics == nil)
        server.answer = { _ in (record(), response(200)) }
        play(other)
        await finishLookingUp()
        play(track)
        await finishLookingUp()
        #expect(service.lyrics != nil)
        #expect(server.asked.filter { $0 == "Midnight City" }.count == LyricsService.tries + 1)
    }

    @Test func aWaitTheServerAsksForIsHonored() async {
        let answers = Answers([(Data(), response(429, ["Retry-After": "1"])), (record(), response(200))])
        server.answer = { _ in answers.next() }
        let started = Date.now
        play(track)
        await wait { service.lyrics != nil }
        #expect(server.asked.count == 2)
        #expect(Date.now.timeIntervalSince(started) >= 1)
    }

    @Test func turningItOffForgetsItAll() async {
        play(track)
        await wait { service.lyrics != nil }
        service.update(track: track, isPlaying: true, isOn: false)
        #expect(service.lyrics == nil)
        play(track)
        await wait { server.asked.count == 2 }
        #expect(server.asked.count == 2)
    }

    @Test func anAnswerAfterItsTurnedOffIsDropped() async {
        server.isHolding = true
        play(track)
        await wait { server.asked.count == 1 }
        service.update(track: track, isPlaying: true, isOn: false)
        server.release()
        await settle()
        #expect(service.lyrics == nil)
    }

    @Test func anAnswerForASkippedTrackDoesntShowOnTheNext() async {
        server.isHolding = true
        play(track)
        await wait { server.asked.count == 1 }
        server.answer = { _ in (Data(), response(404)) }
        play(other)
        server.isHolding = false
        server.answer = { title in title == "Midnight City" ? (record(), response(200)) : (Data(), response(404)) }
        server.release()
        await wait { server.asked.count == 2 }
        await settle()
        #expect(service.lyrics == nil)
    }

    @Test func aTrackWithNoLyricsClearsTheLast() async {
        play(track)
        await wait { service.lyrics != nil }
        server.answer = { _ in (Data(), response(404)) }
        play(other)
        #expect(service.lyrics == nil)
    }

    @Test func nothingPlayingClearsIt() async {
        play(track)
        await wait { service.lyrics != nil }
        service.update(track: nil, isPlaying: false, isOn: true)
        #expect(service.lyrics == nil)
    }

    @Test func aTrackWithNoArtistIsLeftAlone() async {
        var nameless = track
        nameless.artist = ""
        play(nameless)
        await settle()
        #expect(server.asked.isEmpty)
    }

    // MARK: The closed notch

    private let notch = CGSize(width: 186, height: 37)

    @Test func theRowIsAsWideAsTheLongestLine() {
        let layout = ClosedLayout(activity: .lyrics(rowWidth: 300), notch: notch)
        #expect(layout.totalWidth == 336)
        #expect(layout.rowHeight == 26)
    }

    @Test func aVeryLongLineStopsAtTheWidestRow() {
        #expect(ClosedLayout(activity: .lyrics(rowWidth: 2000), notch: notch).totalWidth == ClosedLayout.maxRowWidth)
    }

    @Test func aShortLineStillFitsTheMusicsEars() {
        let music = ClosedLayout(activity: .music, notch: notch)
        #expect(ClosedLayout(activity: .lyrics(rowWidth: 10), notch: notch).earWidth == music.earWidth)
    }

    @Test func itsStillTheMusic() {
        #expect(CompactActivity.music.isShown(by: .lyrics(rowWidth: 300)))
        #expect(GlanceContent(activity: .lyrics(rowWidth: 300)) == .music)
    }
}

/// Hands out one answer after another.
private final class Answers: @unchecked Sendable {
    private let lock = NSLock()
    private var rest: [(Data, URLResponse)]

    init(_ answers: [(Data, URLResponse)]) { rest = answers }

    func next() -> (Data, URLResponse) { lock.withLock { rest.removeFirst() } }
}
