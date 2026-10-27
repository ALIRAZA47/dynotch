import SwiftUI

/// The player on the Nook tab: artwork, track, scrubber and transport controls. It fills the
/// height of the cards beside it: the artwork lines up with their tops, the controls with their bottoms.
struct MediaPlayerView: View {
    @ObservedObject private var media = NowPlayingService.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var outputs = AudioOutputs.shared
    @Environment(\.notchTheme) private var theme

    var body: some View {
        GeometryReader { proxy in
            player(artwork: Self.artworkSide(for: proxy.size.height))
        }
        .opacity(outputs.isPickerShown ? 0 : 1)
        .allowsHitTesting(!outputs.isPickerShown)
        .frame(maxHeight: .infinity)
        .overlay {
            if outputs.isPickerShown {
                OutputPicker(tint: tint)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .onDisappear { outputs.isPickerShown = false }
    }

    /// As large as the height allows once the scrubber and the controls have their room.
    static func artworkSide(for height: CGFloat) -> CGFloat {
        min(96, max(64, (height - 62).rounded()))
    }

    @ViewBuilder
    private func player(artwork side: CGFloat) -> some View {
        if let track = media.track {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    ArtworkView(image: media.artwork, size: side, cornerRadius: theme.cardRadius,
                                glow: settings.artworkTint ? tint : nil)
                        .overlay { ArtworkVolumeOverlay(cornerRadius: theme.cardRadius) }
                        .overlay(alignment: .bottomTrailing) { playerBadge }
                        .overlay {
                            if !outputs.isPickerShown { VolumeScrollArea() }
                        }
                        .onTapGesture { media.openPlayer() }
                        .help("Open \(media.player?.name ?? "player"). Scroll to change the volume.")
                    details(track)
                        .frame(height: side)
                }
                Spacer(minLength: 6)
                PlaybackScrubber(tint: tint)
                Spacer(minLength: 4)
                transport
            }
        } else {
            EmptyPlayerView(artwork: side)
        }
    }

    private func details(_ track: NowPlayingService.Track) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(track.title)
                    .font(NotchFont.title)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(track.title)
                if let favorite = media.isFavorite {
                    Button(action: media.toggleFavorite) {
                        Image(systemName: favorite ? "star.fill" : "star")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(favorite ? tint : theme.tertiary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .help(favorite ? "Remove from favorites" : "Favorite")
                }
                OutputButton(tint: tint)
            }
            Text(track.artist.isEmpty ? " " : track.artist)
                .font(NotchFont.subheadline)
                .foregroundStyle(theme.secondary)
                .lineLimit(1)
            if !track.album.isEmpty {
                Text(track.album)
                    .font(NotchFont.footnote)
                    .foregroundStyle(theme.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            AudioBars(isPlaying: media.isPlaying, color: tint)
                .frame(width: 22, height: 14)
        }
    }

    /// The album art's color, or the accent while Artwork tint is off.
    private var tint: Color {
        settings.artworkTint ? Color(nsColor: media.accent) : theme.accent
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
    @Environment(\.notchTheme) private var theme
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
                        Capsule().fill(theme.track)
                        Capsule()
                            .fill(dragFraction == nil ? theme.primary : tint)
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
            .font(NotchFont.numeric(10.5, .medium))
            .foregroundStyle(theme.secondary)
            .animation(.easeOut(duration: 0.15), value: hovering)
        }
    }
}

/// Nothing is playing: offer to start Music or Spotify.
private struct EmptyPlayerView: View {
    let artwork: CGFloat
    @Environment(\.notchTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.11)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous).strokeBorder(theme.cardStroke))
                Image(systemName: "music.note")
                    .font(.system(size: artwork * 0.34, weight: .medium))
                    .foregroundStyle(theme.tertiary)
            }
            .frame(width: artwork, height: artwork)
            VStack(alignment: .leading, spacing: 4) {
                Text("Nothing playing")
                    .font(NotchFont.title)
                Text("Play something in Music or Spotify and it shows up here.")
                    .font(NotchFont.footnote)
                    .foregroundStyle(theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    ForEach(NowPlayingService.Player.allCases.filter(\.isInstalled), id: \.self) { player in
                        PillButton(title: player.name, symbol: "play.fill") {
                            NowPlayingService.shared.start(player)
                        }
                    }
                }
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) { OutputButton(tint: theme.accent).padding(.top, 4) }
    }
}
