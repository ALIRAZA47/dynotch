import SwiftUI

/// The Music section: the stage while something plays (`MusicStage`), an offer to start Music or
/// Spotify while nothing does, and the list of outputs in place of either while it's open. Its
/// title, the player and the output go in the band beside the camera, with a button to open the
/// player.
struct MediaPlayerView: View {
    @ObservedObject private var media = NowPlayingService.shared
    @ObservedObject private var outputs = AudioOutputs.shared
    @ObservedObject private var lyrics = LyricsService.shared
    @Environment(\.notchTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let track = media.track {
                MusicStage(track: track, lyrics: lyrics.lyrics)
            } else {
                MusicEmptyState()
            }
        }
        .opacity(outputs.isPickerShown ? 0 : 1)
        .allowsHitTesting(!outputs.isPickerShown)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if outputs.isPickerShown {
                OutputPicker(tint: theme.accentText)
                    // With Reduce Motion it only fades, without the small zoom.
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .onDisappear { outputs.isPickerShown = false }
        .orbitHeader("Music", subtitle: subtitle) {
            if let player = media.player {
                OrbitButton(title: "Open \(player.name)", symbol: "arrow.up.forward.app", style: .ghost,
                            help: "Open \(player.name)", action: media.openPlayer)
            }
        }
    }

    /// Which player, and where the sound goes.
    private var subtitle: String {
        guard media.track != nil else { return "Nothing playing" }
        let player = media.player?.name ?? "Playing"
        guard let output = outputs.current?.name else { return player }
        return "\(player) · \(output)"
    }
}

/// The glance's round play and pause button, white like the one in Music: a pearl of white glass, lit
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

/// The glance's elapsed time, draggable bar and time left. The Music section has its own,
/// `MusicScrubber`. The bar is a groove the played part fills with
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

