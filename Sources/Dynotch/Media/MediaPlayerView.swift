import SwiftUI

/// The player on the Nook tab: the artwork beside the track, then the scrubber and the controls.
/// It sits straight on the notch, in the light the artwork casts on the glass around it, with the
/// stack of widgets beside it.
struct MediaPlayerView: View {
    @ObservedObject private var media = NowPlayingService.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var outputs = AudioOutputs.shared
    @Environment(\.notchTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            player(artwork: Self.artworkSide(for: proxy.size.height))
        }
        .background(alignment: .topLeading) { light }
        .opacity(outputs.isPickerShown ? 0 : 1)
        .allowsHitTesting(!outputs.isPickerShown)
        .frame(maxHeight: .infinity)
        .overlay {
            if outputs.isPickerShown {
                OutputPicker(tint: tint)
                    // With Reduce Motion it only fades, without the small zoom.
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
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
                                glow: settings.artworkTint && media.artwork != nil ? tint : nil)
                        .overlay { ArtworkVolumeOverlay(cornerRadius: theme.cardRadius) }
                        .overlay {
                            if !outputs.isPickerShown { VolumeScrollArea() }
                        }
                        .onTapGesture { media.openPlayer() }
                        .help("Open \(media.player?.name ?? "player"). Scroll to change the volume.")
                    details(track, artwork: side)
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

    private func details(_ track: NowPlayingService.Track, artwork side: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // The Nook's one display line, a step smaller beside the smallest art.
                Text(track.title)
                    .font(NotchFont.display(side < 64 ? 17 : 19))
                    .foregroundStyle(theme.primary)
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

    /// The artwork's light on the glass around it, while Artwork tint is on. Off, the player sits on
    /// plain black or glass, as the accent has no light of its own.
    @ViewBuilder
    private var light: some View {
        if settings.artworkTint, media.track != nil {
            ArtLight(palette: media.palette, fallback: media.accent)
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

/// The light the artwork casts on the glass around it: one static gradient, the cover's top-left
/// color at its heart just past the art and its bottom-right color toward its edge, fading out
/// exactly at its frame's edges so it has no seam. It comes in below the player's top edge, so none
/// reaches the camera band, and it has faded out before the transport row. Fainter on Liquid Glass,
/// which carries light of its own.
private struct ArtLight: View {
    /// [top-left half, bottom-right half, whole], from `NowPlayingService.palette`.
    let palette: [NSColor]
    /// The art's one color, for both stops when there's no palette.
    let fallback: NSColor
    @Environment(\.notchTheme) private var theme

    /// The light's frame, and where it sits from the player's top-left corner.
    private static let size = CGSize(width: 340, height: 230)
    private static let offset = CGSize(width: -88, height: -68)
    /// How far below the player's top edge the light takes to come in.
    private static let fadeIn: CGFloat = 16

    var body: some View {
        let heart = palette.first ?? fallback
        let edge = palette.count > 1 ? palette[1] : heart
        let (inner, outer) = theme.isGlass ? (0.18, 0.08) : (0.26, 0.12)
        EllipticalGradient(stops: [
            .init(color: Color(nsColor: heart).opacity(inner * dimming(heart)), location: 0),
            .init(color: Color(nsColor: edge).opacity(outer * dimming(edge)), location: 0.55),
            .init(color: Color(nsColor: edge).opacity(0), location: 1),
        ], center: .center, endRadiusFraction: 0.5)
        .frame(width: Self.size.width, height: Self.size.height)
        .mask(alignment: .top) {
            VStack(spacing: 0) {
                Color.clear.frame(height: -Self.offset.height)
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.fadeIn)
                Color.black
            }
        }
        .offset(Self.offset)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// How much of its light a color may give. The byline and the "on AirPods" line sit in the light's
    /// heart, so a pale cover's light, white, yellow or green, would brighten the glass under them past
    /// 4.5:1: a color brighter than the cap (in relative luminance) dims to it. Colorful covers are
    /// under it and keep all their light. Liquid Glass is brighter already and has less to spare.
    private func dimming(_ color: NSColor) -> Double {
        let cap = theme.isGlass ? 0.2 : 0.55
        return min(1, cap / max(0.001, Luminance.rgb(of: color).map(Luminance.of) ?? 1))
    }
}

/// The big round play and pause button, white like the one in Music: a pearl of white glass, lit
/// from above, standing a little off the notch.
struct PlayButton: View {
    let isPlaying: Bool
    var side: CGFloat = 40
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: side * 0.4, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.86))
                // The triangle's weight sits left of its frame's center.
                .offset(x: isPlaying ? 0 : side * 0.04)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: side, height: side)
                .background {
                    Circle()
                        .fill(LinearGradient(colors: [.white, Color(white: hovering ? 0.9 : 0.8)],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay(Circle().strokeBorder(LinearGradient(colors: [.white, .white.opacity(0.2)],
                                                                      startPoint: .top, endPoint: .bottom),
                                                       lineWidth: 1))
                        .shadow(color: .black.opacity(0.5), radius: side * 0.175, y: side * 0.1)
                }
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.9))
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .help(isPlaying ? "Pause" : "Play")
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }
}

/// Elapsed time, a draggable bar and the time left. The bar is a groove the played part fills with
/// light, brightest where it has reached.
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
                // On one line whatever the length: an hour's time takes its room from the bar.
                Text(Format.duration(elapsed))
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: 34, alignment: .leading)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(theme.track)
                        Capsule()
                            .fill(LinearGradient(colors: [tint.opacity(0.55), tint], startPoint: .leading, endPoint: .trailing))
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
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: 40, alignment: .trailing)
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
            // Where the art goes: a pane of the slab's glass, waiting for a cover.
            Image(systemName: "music.note")
                .font(.system(size: artwork * 0.34, weight: .medium))
                .foregroundStyle(theme.tertiary)
                .frame(width: artwork, height: artwork)
                .glass(.pane, in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("Nothing playing")
                    .font(NotchFont.title)
                    .foregroundStyle(theme.primary)
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
