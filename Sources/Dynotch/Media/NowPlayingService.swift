import AppKit
import Combine

/// Now Playing for Apple Music and Spotify. Both apps broadcast their state as
/// distributed notifications; AppleScript fills in the position and artwork and
/// sends playback commands. Other players (browsers, Podcasts...) only report to
/// the private MediaRemote framework, which macOS 15.4+ reserves for Apple's apps.
@MainActor
final class NowPlayingService: ObservableObject {
    static let shared = NowPlayingService()

    enum Player: String, CaseIterable {
        case music, spotify

        var bundleID: String { self == .music ? "com.apple.Music" : "com.spotify.client" }
        var name: String { self == .music ? "Music" : "Spotify" }

        var notification: Notification.Name {
            Notification.Name(self == .music ? "com.apple.Music.playerInfo" : "com.spotify.client.PlaybackStateChanged")
        }

        var isRunning: Bool {
            !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        }

        var isInstalled: Bool {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        }

        var appURL: URL? {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        }
    }

    enum RepeatMode {
        case off, one, all

        var symbol: String { self == .one ? "repeat.1" : "repeat" }
    }

    struct Track: Equatable {
        var title: String
        var artist: String
        var album: String
        var duration: TimeInterval
    }

    @Published private(set) var player: Player?
    @Published private(set) var track: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var artwork: NSImage?
    @Published private(set) var accent: NSColor = .white
    @Published private(set) var shuffle = false
    @Published private(set) var repeatMode: RepeatMode = .off
    /// nil when the player can't favorite tracks over AppleScript (Spotify).
    @Published private(set) var isFavorite: Bool?

    private var position: TimeInterval = 0
    private var positionDate = Date()
    private var artworkKey: String?
    private var observers: [NSObjectProtocol] = []
    private let runner = AppleScriptRunner()

    private init() {}

    func start() {
        let center = DistributedNotificationCenter.default()
        for source in Player.allCases {
            observers.append(center.addObserver(forName: source.notification, object: nil, queue: .main) { [weak self] note in
                // Anything can post a distributed notification; only the player itself gets a hearing.
                guard source.isRunning else { return }
                let info = PlayerInfo(note.userInfo)
                MainActor.assumeIsolated { self?.handle(info, from: source) }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { self?.playerQuit(bundleID) }
        })
        refresh()
    }

    /// The playback position right now, extrapolated from the last report.
    func elapsed(at date: Date = .now) -> TimeInterval {
        let value = isPlaying ? position + date.timeIntervalSince(positionDate) : position
        guard let duration = track?.duration, duration > 0 else { return max(0, value) }
        return min(max(0, value), duration)
    }

    /// Re-reads everything from the running players.
    func refresh(_ only: Player? = nil) {
        for source in only.map({ [$0] }) ?? Player.allCases where source.isRunning {
            Task { await poll(source) }
        }
        if only == nil, let player, !player.isRunning { clear() }
    }

    // MARK: Commands

    func playPause() {
        guard let player else {
            startPreferredPlayer()
            return
        }
        setPlaying(!isPlaying)
        send(player == .music ? "tell application id \"com.apple.Music\" to playpause"
                              : "tell application id \"com.spotify.client\" to playpause")
    }

    func next() {
        guard let player else { return }
        send("tell application id \"\(player.bundleID)\" to next track")
    }

    func previous() {
        guard let player else { return }
        // Music's "back track" restarts the song first, like the media key.
        send(player == .music ? "tell application id \"com.apple.Music\" to back track"
                              : "tell application id \"com.spotify.client\" to previous track")
    }

    func seek(to seconds: TimeInterval) {
        guard let player else { return }
        setPosition(seconds)
        send("tell application id \"\(player.bundleID)\" to set player position to \(String(format: "%.2f", seconds))")
    }

    func toggleShuffle() {
        guard let player else { return }
        shuffle.toggle()
        send(player == .music
             ? "tell application id \"com.apple.Music\" to set shuffle enabled to \(shuffle)"
             : "tell application id \"com.spotify.client\" to set shuffling to \(shuffle)")
    }

    func cycleRepeat() {
        guard let player else { return }
        switch player {
        case .music:
            repeatMode = repeatMode == .off ? .all : repeatMode == .all ? .one : .off
            let value = repeatMode == .off ? "off" : repeatMode == .all ? "all" : "one"
            send("tell application id \"com.apple.Music\" to set song repeat to \(value)")
        case .spotify:
            repeatMode = repeatMode == .off ? .all : .off
            send("tell application id \"com.spotify.client\" to set repeating to \(repeatMode == .all)")
        }
    }

    func toggleFavorite() {
        guard player == .music, let isFavorite else { return }
        self.isFavorite = !isFavorite
        send(Self.musicFavoriteScript(!isFavorite))
    }

    func openPlayer() {
        guard let player else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).first?.activate()
    }

    func startPreferredPlayer() {
        let preferred: Player = AppSettings.shared.preferredPlayer == .spotify && Player.spotify.isInstalled ? .spotify : .music
        start(preferred)
    }

    func start(_ source: Player) {
        send("tell application id \"\(source.bundleID)\" to play", refreshing: source)
    }

    // MARK: State

    private func handle(_ info: PlayerInfo, from source: Player) {
        if info.state == "Stopped" {
            if player == source { clear() }
            return
        }
        let playing = info.state == "Playing"
        // Another player is busy; a pause over here shouldn't take over the notch.
        if let current = player, current != source, isPlaying, !playing { return }
        guard !info.title.isEmpty else {
            refresh(source)
            return
        }
        apply(source: source,
              track: Track(title: info.title, artist: info.artist, album: info.album, duration: info.duration),
              playing: playing)
        if let position = info.position { setPosition(position) }
        refresh(source)
    }

    private func poll(_ source: Player) async {
        guard let result = await runner.run(source == .music ? Self.musicStateScript : Self.spotifyStateScript) else { return }
        let state = result.string(0) ?? "stopped"
        guard state != "stopped" else {
            if player == source { clear() }
            return
        }
        let playing = state == "playing"
        if let current = player, current != source, isPlaying, !playing { return }
        guard let title = result.string(1), !title.isEmpty else { return }
        apply(source: source,
              track: Track(title: title, artist: result.string(2) ?? "", album: result.string(3) ?? "",
                           duration: result.number(4) ?? 0),
              playing: playing)
        if let position = result.number(5) { setPosition(position) }
        shuffle = result.string(6) == "true"
        switch result.string(7) {
        case "one": repeatMode = .one
        case "all", "true": repeatMode = .all
        default: repeatMode = .off
        }
        if source == .music {
            let favorite = result.string(8)
            isFavorite = favorite == "true" ? true : favorite == "false" ? false : nil
        } else {
            isFavorite = nil
        }
    }

    private func apply(source: Player, track next: Track, playing: Bool) {
        let isNewTrack = source != player || next.title != track?.title || next.artist != track?.artist
        player = source
        if track != next { track = next }
        setPlaying(playing)
        guard isNewTrack else { return }
        loadArtwork(source: source, track: next)
        if playing { LiveActivityCenter.shared.peekTrack() }
    }

    private func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        position = elapsed()
        positionDate = .now
        isPlaying = playing
    }

    private func setPosition(_ seconds: TimeInterval) {
        position = seconds
        positionDate = .now
    }

    private func clear() {
        player = nil
        track = nil
        isPlaying = false
        artwork = nil
        artworkKey = nil
        accent = .white
        isFavorite = nil
        position = 0
    }

    private func playerQuit(_ bundleID: String?) {
        guard let player, player.bundleID == bundleID else { return }
        clear()
        refresh()
    }

    private func send(_ script: String, refreshing source: Player? = nil) {
        let target = source ?? player
        Task {
            _ = await runner.run(script)
            try? await Task.sleep(for: .milliseconds(350))
            if let target { refresh(target) }
        }
    }

    // MARK: Artwork

    private func loadArtwork(source: Player, track: Track) {
        let key = [source.rawValue, track.title, track.artist, track.album].joined(separator: "\n")
        guard key != artworkKey else { return }
        artworkKey = key
        Task {
            let image = await fetchArtwork(source: source, track: track)
            guard artworkKey == key else { return }
            artwork = image
            accent = image?.vibrantAverageColor() ?? .white
        }
    }

    private func fetchArtwork(source: Player, track: Track) async -> NSImage? {
        switch source {
        case .music:
            if let data = await runner.run(Self.musicArtworkScript)?.data, let image = NSImage(data: data), image.isValid {
                return image
            }
            // Streamed Apple Music tracks often have no local artwork.
            return await Self.catalogArtwork(artist: track.artist, album: track.album.isEmpty ? track.title : track.album)
        case .spotify:
            guard let link = await runner.run(Self.spotifyArtworkScript)?.text, let url = URL(string: link) else { return nil }
            return await Self.download(url)
        }
    }

    /// Artwork comes from Spotify's and Apple's image servers, over HTTPS and from nowhere else:
    /// the link is whatever the player or the search API handed over.
    private static let artworkHosts = ["scdn.co", "spotifycdn.com", "mzstatic.com"]

    private static func download(_ url: URL) async -> NSImage? {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              artworkHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return NSImage(data: data)
    }

    /// Looks the album up in the public iTunes Search API.
    private static func catalogArtwork(artist: String, album: String) async -> NSImage? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(album)"),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["results"] as? [[String: Any]])?.first,
              let link = first["artworkUrl100"] as? String,
              let large = URL(string: link.replacingOccurrences(of: "100x100", with: "600x600")) else { return nil }
        return await download(large)
    }

    // MARK: Scripts

    private static let musicStateScript = """
    tell application id "com.apple.Music"
        set st to (player state as string)
        if st is "stopped" then return {st}
        set nm to ""
        set ar to ""
        set al to ""
        set du to 0
        set ps to 0
        set sh to "false"
        set rp to "off"
        set fv to "unknown"
        try
            set t to current track
            set nm to (name of t) as string
            set ar to (artist of t) as string
            set al to (album of t) as string
            set du to (duration of t) as real
        end try
        try
            set ps to player position as real
        end try
        try
            set sh to (shuffle enabled) as string
        end try
        try
            set rp to (song repeat) as string
        end try
        try
            set fv to (favorited of current track) as string
        on error
            try
                set fv to (loved of current track) as string
            end try
        end try
        return {st, nm, ar, al, du, ps, sh, rp, fv}
    end tell
    """

    private static let spotifyStateScript = """
    tell application id "com.spotify.client"
        set st to (player state as string)
        if st is "stopped" then return {st}
        set nm to ""
        set ar to ""
        set al to ""
        set du to 0
        set ps to 0
        set sh to "false"
        set rp to "false"
        try
            set t to current track
            set nm to (name of t) as string
            set ar to (artist of t) as string
            set al to (album of t) as string
            set du to ((duration of t) as real) / 1000
        end try
        try
            set ps to player position as real
        end try
        try
            set sh to shuffling as string
        end try
        try
            set rp to repeating as string
        end try
        return {st, nm, ar, al, du, ps, sh, rp}
    end tell
    """

    private static let musicArtworkScript = """
    tell application id "com.apple.Music"
        try
            return raw data of artwork 1 of current track
        end try
        return data of artwork 1 of current track
    end tell
    """

    private static let spotifyArtworkScript = """
    tell application id "com.spotify.client" to return artwork url of current track
    """

    private static func musicFavoriteScript(_ favorite: Bool) -> String {
        """
        tell application id "com.apple.Music"
            try
                set favorited of current track to \(favorite)
            on error
                set loved of current track to \(favorite)
            end try
        end tell
        """
    }

    // MARK: Snapshots

    func loadSample(_ track: Track?, artwork: NSImage? = nil, playing: Bool = false, elapsed: TimeInterval = 0) {
        player = track == nil ? nil : .music
        self.track = track
        isPlaying = playing
        self.artwork = artwork
        accent = artwork?.vibrantAverageColor() ?? .white
        isFavorite = track == nil ? nil : true
        setPosition(elapsed)
    }
}

/// The parts of a player's distributed notification we use.
/// Music reports "Total Time" in ms; Spotify reports "Duration" in ms plus a position in seconds.
private struct PlayerInfo: Sendable {
    let state: String
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let position: TimeInterval?

    init(_ info: [AnyHashable: Any]?) {
        let info = info ?? [:]
        state = info["Player State"] as? String ?? ""
        title = info["Name"] as? String ?? ""
        artist = info["Artist"] as? String ?? ""
        album = info["Album"] as? String ?? ""
        duration = ((info["Total Time"] as? NSNumber ?? info["Duration"] as? NSNumber)?.doubleValue ?? 0) / 1000
        position = (info["Playback Position"] as? NSNumber)?.doubleValue
    }
}
