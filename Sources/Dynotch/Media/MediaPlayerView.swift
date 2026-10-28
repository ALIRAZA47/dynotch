import SwiftUI

/// The player on the Nook tab: the artwork beside the track, then the scrubber and the controls.
/// It sits straight on the notch, lit by a soft glow in the artwork's color, with the stack of
/// widgets beside it.
struct MediaPlayerView: View {
    @ObservedObject private var media = NowPlayingService.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var outputs = AudioOutputs.shared
    @Environment(\.notchTheme) private var theme

    var body: some View {
        GeometryReader { proxy in
            player(artwork: Self.artworkSide(for: proxy.size.height))
        }
        .background(alignment: .topLeading) { glow }
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
        min(84, max(56, (height - 98).rounded()))
    }

    @ViewBuilder
    private func player(artwork side: CGFloat) -> some View {
        if let track = media.track {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 14) {
                    ArtworkView(image: media.artwork, size: side, cornerRadius: theme.cardRadius,
                                glow: settings.artworkTint ? tint : nil)
                        .overlay { ArtworkVolumeOverlay(cornerRadius: theme.cardRadius) }
                        .overlay {
                            if !outputs.isPickerShown { VolumeScrollArea() }
                        }
                        .onTapGesture { media.openPlayer() }
                        .help("Open \(media.player?.name ?? "player"). Scroll to change the volume.")
                    details(track)
                }
                Spacer(minLength: 8)
                PlaybackScrubber(tint: tint)
                Spacer(minLength: 6)
                transport
            }
        } else {
            EmptyPlayerView(artwork: side)
        }
    }

    private func details(_ track: NowPlayingService.Track) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(track.title)
                    .font(NotchFont.title)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(track.title)
                if media.canFavorite {
                    let favorite = media.isFavorite ?? false
                    Button(action: media.toggleFavorite) {
                        Image(systemName: favorite ? "star.fill" : "star")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(favorite ? theme.accent : theme.tertiary)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .help(favorite ? "Remove from favorites" : "Favorite")
                }
            }
            Text(byline(track))
                .font(NotchFont.subheadline)
                .foregroundStyle(theme.secondary)
                .lineLimit(1)
                .help(byline(track))
            HStack(spacing: 8) {
                AudioBars(isPlaying: media.isPlaying, color: tint)
                    .frame(width: 16, height: 12)
                Text(playingOn)
                    .font(NotchFont.caption)
                    .foregroundStyle(theme.tertiary)
                    .lineLimit(1)
            }
            .padding(.top, 9)
        }
    }

    /// The artist and the album, whichever there are.
    private func byline(_ track: NowPlayingService.Track) -> String {
        let parts = [track.artist, track.album].filter { !$0.isEmpty }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }

    /// Which player, and where the sound goes.
    private var playingOn: String {
        let player = media.player?.name ?? "Playing"
        guard let output = outputs.current?.name else { return player }
        return "\(player) on \(output)"
    }

    /// The album art's color, or the accent while Artwork tint is off.
    private var tint: Color {
        settings.artworkTint ? Color(nsColor: media.accent) : theme.accent
    }

    /// The artwork's color, glowing faintly behind it.
    @ViewBuilder
    private var glow: some View {
        if settings.artworkTint, media.track != nil {
            RadialGradient(colors: [tint.opacity(0.24), tint.opacity(0)], center: .center, startRadius: 0, endRadius: 130)
                .frame(width: 300, height: 200)
                .offset(x: -50, y: -46)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var transport: some View {
        HStack(spacing: 0) {
            IconButton(symbol: "shuffle", size: 12, isActive: media.shuffle, activeColor: tint, idleOpacity: 0.5,
                       help: "Shuffle", action: media.toggleShuffle)
            Spacer(minLength: 0)
            IconButton(symbol: "backward.fill", size: 16, help: "Previous", action: media.previous)
            Spacer(minLength: 0)
            PlayButton(isPlaying: media.isPlaying, action: media.playPause)
            Spacer(minLength: 0)
            IconButton(symbol: "forward.fill", size: 16, help: "Next", action: media.next)
            Spacer(minLength: 0)
            IconButton(symbol: media.repeatMode.symbol, size: 12, isActive: media.repeatMode != .off, activeColor: tint,
                       idleOpacity: 0.5, help: "Repeat", action: media.cycleRepeat)
            Spacer(minLength: 0)
            OutputButton(tint: tint)
        }
        .frame(height: 40)
    }
}

/// The big round play and pause button, white like the one in Music.
struct PlayButton: View {
    let isPlaying: Bool
    var side: CGFloat = 40
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: side * 0.4, weight: .bold))
                .foregroundStyle(Color.black)
                // The triangle's weight sits left of its frame's center.
                .offset(x: isPlaying ? 0 : side * 0.04)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: side, height: side)
                .background(Circle().fill(Color.white.opacity(hovering ? 1 : 0.94)))
                .shadow(color: .black.opacity(0.45), radius: 6, y: 3)
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.9))
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .help(isPlaying ? "Pause" : "Play")
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
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
                            .fill(tint)
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
                Text(duration > 0 ? "−" + Format.duration(max(0, duration - elapsed)) : "Live")
                    .frame(width: 40, alignment: .trailing)
            }
            .font(NotchFont.numeric(10.5))
            .foregroundStyle(theme.tertiary)
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
