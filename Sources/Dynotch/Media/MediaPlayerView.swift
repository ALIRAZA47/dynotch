import SwiftUI

/// The player on the Nook tab: artwork, track, scrubber and transport controls.
struct MediaPlayerView: View {
    @ObservedObject private var media = NowPlayingService.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        if let track = media.track {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top, spacing: 13) {
                    ArtworkView(image: media.artwork, size: 84, cornerRadius: 14, glow: settings.artworkTint ? tint : nil)
                        .overlay(alignment: .bottomTrailing) { playerBadge }
                        .onTapGesture { media.openPlayer() }
                        .help("Open \(media.player?.name ?? "player")")
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(track.title)
                                .font(.system(size: 15, weight: .semibold))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if let favorite = media.isFavorite {
                                Button(action: media.toggleFavorite) {
                                    Image(systemName: favorite ? "star.fill" : "star")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(favorite ? tint : Color.notchTertiary)
                                        .contentTransition(.symbolEffect(.replace))
                                }
                                .buttonStyle(PressableButtonStyle())
                                .help(favorite ? "Remove from favorites" : "Favorite")
                            }
                        }
                        Text(track.artist.isEmpty ? " " : track.artist)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.notchSecondary)
                            .lineLimit(1)
                        if !track.album.isEmpty {
                            Text(track.album)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.notchTertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        AudioBars(isPlaying: media.isPlaying, color: tint)
                            .frame(width: 22, height: 14)
                    }
                    .frame(height: 84)
                }
                PlaybackScrubber(tint: tint)
                transport
            }
        } else {
            EmptyPlayerView()
        }
    }

    private var tint: Color {
        settings.artworkTint ? Color(nsColor: media.accent) : .white
    }

    @ViewBuilder
    private var playerBadge: some View {
        if let url = media.player?.appURL {
            Image(nsImage: IconCache.icon(forFile: url.path, side: 24))
                .resizable()
                .frame(width: 24, height: 24)
                .shadow(color: .black.opacity(0.5), radius: 3)
                .offset(x: 6, y: 6)
        }
    }

    private var transport: some View {
        HStack(spacing: 0) {
            IconButton(symbol: "shuffle", size: 12, isActive: media.shuffle, activeColor: tint, help: "Shuffle",
                       action: media.toggleShuffle)
            Spacer(minLength: 0)
            IconButton(symbol: "backward.fill", size: 16, help: "Previous", action: media.previous)
            Spacer(minLength: 0)
            IconButton(symbol: media.isPlaying ? "pause.fill" : "play.fill", size: 22,
                       help: media.isPlaying ? "Pause" : "Play", action: media.playPause)
                .contentTransition(.symbolEffect(.replace))
            Spacer(minLength: 0)
            IconButton(symbol: "forward.fill", size: 16, help: "Next", action: media.next)
            Spacer(minLength: 0)
            IconButton(symbol: media.repeatMode.symbol, size: 12, isActive: media.repeatMode != .off, activeColor: tint,
                       help: "Repeat", action: media.cycleRepeat)
        }
        .frame(height: 30)
    }
}

/// Elapsed time, a draggable bar and the time left.
struct PlaybackScrubber: View {
    var tint: Color
    @ObservedObject private var media = NowPlayingService.shared
    @ViewState private var dragFraction: Double?
    @ViewState private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = media.track?.duration ?? 0
            let elapsed = dragFraction.map { $0 * duration } ?? media.elapsed(at: context.date)
            let fraction = duration > 0 ? elapsed / duration : 0
            HStack(spacing: 8) {
                Text(Format.duration(elapsed))
                    .frame(width: 34, alignment: .leading)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule()
                            .fill(dragFraction == nil ? Color.white : tint)
                            .frame(width: max(0, proxy.size.width * min(1, fraction)))
                    }
                    .frame(height: hovering || dragFraction != nil ? 7 : 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragFraction = min(1, max(0, value.location.x / max(1, proxy.size.width)))
                        }
                        .onEnded { value in
                            let target = min(1, max(0, value.location.x / max(1, proxy.size.width)))
                            if duration > 0 { media.seek(to: target * duration) }
                            dragFraction = nil
                        })
                }
                .frame(height: 12)
                .onHover { hovering = $0 }
                .disabled(duration <= 0)
                Text(duration > 0 ? "-" + Format.duration(max(0, duration - elapsed)) : "LIVE")
                    .frame(width: 40, alignment: .trailing)
            }
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Color.notchSecondary)
            .animation(.easeOut(duration: 0.15), value: hovering)
        }
    }
}

/// Nothing is playing: offer to start Music or Spotify.
private struct EmptyPlayerView: View {
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.11)], startPoint: .top, endPoint: .bottom))
                Image(systemName: "music.note")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.35))
            }
            .frame(width: 84, height: 84)
            VStack(alignment: .leading, spacing: 4) {
                Text("Nothing playing")
                    .font(.system(size: 15, weight: .semibold))
                Text("Play something in Music or Spotify and it shows up here.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.notchSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    ForEach(NowPlayingService.Player.allCases.filter(\.isInstalled), id: \.self) { player in
                        PillButton(title: player.name, symbol: "play.fill") {
                            NowPlayingService.shared.start(player)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
