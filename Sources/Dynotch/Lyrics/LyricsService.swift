import Combine
import Foundation

/// Asks LRCLIB for one track's lyrics, and reads what it says. A title, an artist, an album and a
/// length go out, with no account and no key, and nothing else about the Mac or who's listening.
enum LyricsClient {
    /// What came of asking.
    enum Answer: Equatable {
        case found(Lyrics)
        /// It's looked and there are none, or none with times, or the song has no words.
        case none
        /// The server's busy or says to slow down. Nil when it didn't say for how long.
        case wait(TimeInterval?)
        /// The network, or the server, didn't come through. That says nothing about the track.
        case failed
    }

    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// No cookies and nothing kept on disk.
    private static let session = URLSession(configuration: .ephemeral)
    static let live: Fetch = { try await session.data(for: $0) }

    /// A response larger than this isn't lyrics.
    private static let largest = 2_000_000

    /// Nil without a title and an artist, which LRCLIB needs. It only takes a length from 1 to 3600
    /// seconds, and goes without one otherwise.
    static func request(for track: NowPlayingService.Track, version: String = UpdateChecker.currentVersion) -> URLRequest? {
        guard !track.title.isEmpty, !track.artist.isEmpty else { return nil }
        var items = [URLQueryItem(name: "track_name", value: track.title), URLQueryItem(name: "artist_name", value: track.artist)]
        if !track.album.isEmpty { items.append(URLQueryItem(name: "album_name", value: track.album)) }
        let seconds = Int(track.duration.rounded())
        if (1...3600).contains(seconds) { items.append(URLQueryItem(name: "duration", value: String(seconds))) }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "lrclib.net"
        components.path = "/api/get"
        components.queryItems = items
        // A plus stays a plus in a query, and the server would read it as a space: "C+C Music Factory".
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        // LRCLIB asks every client to say who it is.
        request.setValue("Dynotch v\(version) (https://github.com/ALIRAZA47/dynotch)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private struct Record: Decodable {
        let instrumental: Bool?
        let syncedLyrics: String?
    }

    /// The status first: an error from the network's edge may not be JSON.
    static func answer(to data: Data, _ response: URLResponse) -> Answer {
        guard let response = response as? HTTPURLResponse else { return .failed }
        switch response.statusCode {
        case 200:
            guard data.count <= largest, response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("json") == true,
                  let record = try? JSONDecoder().decode(Record.self, from: data) else { return .failed }
            guard record.instrumental != true, let lyrics = record.syncedLyrics.flatMap(Lyrics.init(lrc:)) else { return .none }
            return .found(lyrics)
        case 400, 404:
            return .none
        case 429, 503:
            return .wait(response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        default:
            return .failed
        }
    }
}

/// How fast LRCLIB may be asked: one request at a time, about 45 a minute, and never before a
/// `Retry-After` it's given is up, with a little over so everyone it told doesn't come back at once.
struct LyricsLimiter {
    static let perMinute = 45
    /// Between one request and the next.
    static let gap: TimeInterval = 0.5
    /// When the server asks for a wait without saying how long, or the request fails.
    static let defaultWait: TimeInterval = 60

    private var sent: [Date] = []
    private var heldUntil = Date.distantPast

    /// How long until the next request may go.
    func wait(at now: Date) -> TimeInterval {
        var wait = heldUntil.timeIntervalSince(now)
        if let last = sent.last { wait = max(wait, Self.gap - now.timeIntervalSince(last)) }
        let inLastMinute = sent.filter { now.timeIntervalSince($0) < 60 }
        if inLastMinute.count >= Self.perMinute { wait = max(wait, 60 - now.timeIntervalSince(inLastMinute[0])) }
        return max(wait, 0)
    }

    mutating func noteRequest(at now: Date) {
        sent.append(now)
        sent.removeAll { now.timeIntervalSince($0) >= 60 }
    }

    /// `extra` is the jitter, up to 30% over.
    mutating func hold(for seconds: TimeInterval, from now: Date, extra: Double = .random(in: 0...0.3)) {
        heldUntil = max(heldUntil, now.addingTimeInterval(seconds * (1 + extra)))
    }
}

/// The lyrics of what's playing. Off until asked for, since it sends the song's name to a third party.
/// A track is only looked up once it's been playing for a moment, so what's skipped past or sits
/// paused goes nowhere. Answers are kept per track in memory, including that there aren't any, so a
/// song is asked about once a run. Dynotch's own players are the only source.
@MainActor
final class LyricsService: ObservableObject {
    static let shared = LyricsService()

    /// The lyrics of the track playing, when it has any with times.
    @Published private(set) var lyrics: Lyrics?

    /// One track, whatever the player says about its length this time.
    private struct Key: Hashable {
        let title: String
        let artist: String
        let album: String

        init(_ track: NowPlayingService.Track) {
            (title, artist, album) = (track.title, track.artist, track.album)
        }
    }

    /// How many tracks are remembered, oldest answers going first.
    private static let keptTracks = 200
    /// How many times a track's asked about before leaving it until it next comes up.
    static let tries = 3

    private let fetch: LyricsClient.Fetch
    private let settle: Duration
    private let failureWait: TimeInterval
    /// Lyrics, or nil for none, in the order they arrived.
    private var cache: [Key: Lyrics?] = [:]
    private var cacheOrder: [Key] = []
    private var limiter = LyricsLimiter()
    private var track: NowPlayingService.Track?
    private var lookup: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    /// The tests pass their own `fetch`, so they never reach the network, and don't wait as long.
    init(fetch: @escaping LyricsClient.Fetch = LyricsClient.live, settle: Duration = .seconds(2),
         failureWait: TimeInterval = LyricsLimiter.defaultWait) {
        self.fetch = fetch
        self.settle = settle
        self.failureWait = failureWait
    }

    func start() {
        let media = NowPlayingService.shared
        Publishers.CombineLatest3(media.$track, media.$isPlaying, AppSettings.shared.$showsLyrics)
            .sink { [weak self] track, isPlaying, isOn in self?.update(track: track, isPlaying: isPlaying, isOn: isOn) }
            .store(in: &cancellables)
    }

    /// What's playing now. Turning this off forgets everything.
    func update(track next: NowPlayingService.Track?, isPlaying: Bool, isOn: Bool) {
        guard isOn else {
            lookup?.cancel()
            lookup = nil
            cache = [:]
            cacheOrder = []
            track = nil
            if lyrics != nil { lyrics = nil }
            return
        }
        let isNew = next.map(Key.init) != track.map(Key.init)
        track = next
        if isNew {
            lookup?.cancel()
            lookup = nil
            let known = next.flatMap { cache[Key($0)] ?? nil }
            if lyrics != known { lyrics = known }
        }
        guard isPlaying else {
            // Paused before it's been asked about, it goes nowhere until it plays again.
            lookup?.cancel()
            lookup = nil
            return
        }
        guard let next, lookup == nil, cache[Key(next)] == nil else { return }
        lookup = Task { [weak self] in await self?.lookUp(Key(next)) }
    }

    /// Waits to see the track stays, then asks, as many times as it takes and as often as allowed.
    /// The track is read each time, as the player may have said more about it since.
    private func lookUp(_ key: Key) async {
        guard (try? await Task.sleep(for: settle)) != nil else { return }
        for _ in 0..<Self.tries {
            let wait = limiter.wait(at: .now)
            if wait > 0 {
                guard (try? await Task.sleep(for: .seconds(wait))) != nil else { return }
            }
            guard let track, Key(track) == key else { return }
            guard let request = LyricsClient.request(for: track) else {
                remember(nil, for: key)
                break
            }
            limiter.noteRequest(at: .now)
            let answer: LyricsClient.Answer
            if let (data, response) = try? await fetch(request) {
                answer = LyricsClient.answer(to: data, response)
            } else {
                answer = .failed
            }
            guard !Task.isCancelled else { return }
            switch answer {
            case .found(let lyrics):
                remember(lyrics, for: key)
                self.lyrics = lyrics
                lookup = nil
                return
            case .none:
                remember(nil, for: key)
                lookup = nil
                return
            case .wait(let seconds):
                limiter.hold(for: seconds ?? failureWait, from: .now)
            case .failed:
                limiter.hold(for: failureWait, from: .now)
            }
        }
        lookup = nil
    }

    private func remember(_ lyrics: Lyrics?, for key: Key) {
        if cache.updateValue(lyrics, forKey: key) == nil { cacheOrder.append(key) }
        if cacheOrder.count > Self.keptTracks { cache[cacheOrder.removeFirst()] = nil }
    }

    // MARK: Snapshots

    func loadSample(_ lyrics: Lyrics?) {
        self.lyrics = lyrics
    }
}
