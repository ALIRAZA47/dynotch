import AppKit
import SwiftUI

// MARK: Stage

/// Orbit's Music section while something plays: the cover, blurred and dimmed, is the card's
/// ground; on it the cover itself at a moderate size, the title big, the artist and album, the
/// scrubber and the controls, and the line being sung under a hairline when there are lyrics.
/// With Artwork tint off the card is a plain Orbit card in the panel's own light or dark.
struct MusicStage: View {
    let track: NowPlayingService.Track
    let lyrics: Lyrics?
    @ObservedObject private var media = NowPlayingService.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let artwork = settings.artworkTint ? media.artwork : nil
        let ink = artwork == nil ? theme : MusicInk.theme(from: theme)
        GeometryReader { proxy in
            let layout = MusicLayout(size: proxy.size, hasLyrics: lyrics != nil)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: layout.gap) {
                    MusicArt(image: media.artwork, side: layout.art, onArt: artwork != nil)
                    details(layout: layout, onArt: artwork != nil)
                        .frame(height: max(layout.art, layout.detailsMinimum))
                }
                .frame(maxHeight: .infinity)
                if let lyrics {
                    lyricRow(lyrics)
                }
            }
            .padding(MusicLayout.padding)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .environment(\.notchTheme, ink)
        .background { MusicBackdrop(artwork: artwork) }
        .clipShape(theme.cardShape)
    }

    private func details(layout: MusicLayout, onArt: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MusicKicker(isPlaying: media.isPlaying, onArt: onArt)
            Text(track.title)
                .font(.system(size: layout.titleSize, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(MusicInk.primary)
                .lineLimit(1)
                .padding(.top, layout.isCompact ? 3 : 6)
                .help(track.title)
            Text(byline)
                .font(.system(size: layout.isCompact ? 13 : 15))
                .foregroundStyle(MusicInk.secondary)
                .lineLimit(1)
                .padding(.top, 2)
                .help(byline)
            Spacer(minLength: 6)
            MusicScrubber(onArt: onArt)
            MusicTransport(onArt: onArt, buttonHeight: layout.buttonHeight, showsOutputName: layout.showsOutputName)
                .padding(.top, layout.isCompact ? 6 : 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The line being sung, under a hairline across the card.
    private func lyricRow(_ lyrics: Lyrics) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MusicInk.line.frame(height: 1)
            LyricLine(lyrics: lyrics)
                .font(.system(size: 13.5).italic())
                .foregroundStyle(MusicInk.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 18)
                .padding(.top, 9)
        }
        .padding(.top, 10)
    }

    /// The artist and the album, whichever there are.
    private var byline: String {
        let parts = [track.artist, track.album].filter { !$0.isEmpty }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }
}

/// How the stage shares out its room: the cover as large as the height allows, up to a point,
/// and a smaller title and controls when the panel is short.
struct MusicLayout {
    static let padding: CGFloat = 14
    /// The cover's side.
    let art: CGFloat
    let gap: CGFloat
    let titleSize: CGFloat
    let buttonHeight: CGFloat
    let isCompact: Bool
    /// The output button has room for the output's name.
    let showsOutputName: Bool

    /// What the title column needs: the state line, title, byline, scrubber and controls.
    var detailsMinimum: CGFloat { isCompact ? 118 : 146 }

    init(size: CGSize, hasLyrics: Bool) {
        let inner = CGSize(width: size.width - Self.padding * 2, height: size.height - Self.padding * 2)
        let top = inner.height - (hasLyrics ? 38 : 0)
        isCompact = top < 152
        gap = isCompact ? 16 : 22
        art = max(64, min(top, 220, (inner.width * 0.26).rounded())).rounded()
        titleSize = isCompact ? 22 : top > 210 ? 32 : 28
        buttonHeight = isCompact ? 28 : 32
        showsOutputName = inner.width - art - gap > 440
    }
}

// MARK: Ink

/// The colors on the cover's ground: Orbit's dark theme with Increase Contrast's quieter text a
/// step up, whatever the panel's light or dark, as the ground is dimmed toward black. Views read
/// them from the environment through `MusicInk`'s styles.
enum MusicInk {
    static func theme(from panel: NotchTheme) -> NotchTheme {
        var ink = NotchTheme(accent: panel.accentChoice, isDark: true, radius: panel.radius)
        ink.isHighContrast = true
        return ink
    }

    static let primary = InkStyle(\.primary)
    static let secondary = InkStyle(\.secondary)
    static let line = InkStyle(\.line)

    /// A theme color, read where it's drawn, so the stage's ink or the panel's applies.
    struct InkStyle: ShapeStyle, View {
        let color: KeyPath<NotchTheme, Color>
        init(_ color: KeyPath<NotchTheme, Color>) { self.color = color }

        func resolve(in environment: EnvironmentValues) -> Color {
            environment.notchTheme[keyPath: color]
        }

        var body: some View { Rectangle().fill(self) }
    }
}

// MARK: Ground

/// The card's ground: the cover blurred across it and dimmed toward black just far enough for the
/// second lines on it to read at 4.5:1 where it's brightest. Without a cover, a plain card.
struct MusicBackdrop: View {
    let artwork: NSImage?
    @Environment(\.notchTheme) private var theme

    var body: some View {
        if let artwork {
            let ink = MusicInk.theme(from: theme)
            GeometryReader { proxy in
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .blur(radius: 40, opaque: true)
                    .saturation(1.3)
                    .scaleEffect(1.15)
            }
            .overlay(ink.background.opacity(Self.dimming(for: artwork)))
            .overlay(theme.cardShape.strokeBorder(ink.line, lineWidth: 1))
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        } else {
            CardSurface()
        }
    }

    // MARK: Contrast

    /// How far the ground dims toward the ink's background, from 0.42 for a dark cover to 0.86 for
    /// a white one. The blur spreads the cover's color about as far as one cell of an 8 × 8 grid,
    /// so the brightest cell is the brightest the ground gets under the text.
    @MainActor
    static func dimming(for image: NSImage) -> Double {
        if let known = cache.object(forKey: image) { return known.doubleValue }
        let ink = MusicInk.theme(from: .standard)
        let text = NotchTheme.luminance(of: ink.secondary)
        let base = Luminance.rgb(of: NSColor(ink.background)) ?? [0.086, 0.086, 0.094]
        var needed = 0.42
        for rgb in cells(of: image) {
            needed = max(needed, dimming(rgb, toward: base, under: text))
        }
        let value = min(0.86, needed)
        cache.setObject(NSNumber(value: value), forKey: image)
        return value
    }

    /// The least dimming that puts text of luminance `text` at 4.6:1 on `rgb`.
    static func dimming(_ rgb: [Double], toward base: [Double], under text: Double) -> Double {
        func mixed(_ amount: Double) -> Double {
            Luminance.of(zip(rgb, base).map { $0 * (1 - amount) + $1 * amount })
        }
        if NotchTheme.contrast(text, mixed(0)) >= 4.6 { return 0 }
        var low = 0.0, high = 1.0
        for _ in 0..<14 {
            let middle = (low + high) / 2
            if NotchTheme.contrast(text, mixed(middle)) < 4.6 { low = middle } else { high = middle }
        }
        return high
    }

    /// The cover's colors on an 8 × 8 grid, in sRGB.
    private static func cells(of image: NSImage) -> [[Double]] {
        let side = 8
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?
            .retagging(with: .sRGB)
        else { return [[1, 1, 1]] }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        var out: [[Double]] = []
        for y in 0..<side {
            for x in 0..<side {
                if let rgb = rep.colorAt(x: x, y: y).flatMap(Luminance.rgb(of:)) { out.append(rgb) }
            }
        }
        return out.isEmpty ? [[1, 1, 1]] : out
    }

    @MainActor private static let cache = NSCache<NSImage, NSNumber>()
}

// MARK: Pieces

/// The cover, sharp, with the volume over it for a moment after it changes. Scrolling over it
/// changes the volume; a click opens the player.
private struct MusicArt: View {
    let image: NSImage?
    let side: CGFloat
    let onArt: Bool
    @ObservedObject private var media = NowPlayingService.shared
    @ObservedObject private var outputs = AudioOutputs.shared
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let shape = theme.cardShape
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                shape.fill(theme.hover)
                Image(systemName: "music.note")
                    .font(.system(size: side * 0.32, weight: .medium))
                    .foregroundStyle(theme.tertiary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay(shape.strokeBorder(theme.line, lineWidth: 1))
        .shadow(color: .black.opacity(onArt ? 0.35 : 0), radius: 14, y: 8)
        .overlay { ArtworkVolumeOverlay(cornerRadius: theme.cardRadius) }
        .overlay {
            if !outputs.isPickerShown { VolumeScrollArea() }
        }
        .contentShape(shape)
        .onTapGesture { media.openPlayer() }
        .help("Open \(media.player?.name ?? "player"). Scroll to change the volume.")
        .accessibilityElement()
        .accessibilityLabel("Album art")
        .accessibilityHint("Opens \(media.player?.name ?? "the player")")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { media.openPlayer() }
    }
}

/// PLAYING or PAUSED in small capitals, after the bars that move with the music.
private struct MusicKicker: View {
    let isPlaying: Bool
    let onArt: Bool
    @Environment(\.notchTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            AudioBars(isPlaying: isPlaying, color: onArt ? theme.primary : theme.accentText)
                .frame(width: 14, height: 11)
            Text(isPlaying ? "Playing" : "Paused")
                .textCase(.uppercase)
                .font(.system(size: 11.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(theme.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isPlaying ? "Playing" : "Paused")
    }
}

/// Elapsed time, a thin bar to drag and the time left, in SF Mono.
struct MusicScrubber: View {
    let onArt: Bool
    @ObservedObject private var media = NowPlayingService.shared
    @Environment(\.notchTheme) private var theme
    @ViewState private var dragFraction: Double?
    @ViewState private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = media.track?.duration ?? 0
            let elapsed = dragFraction.map { $0 * duration } ?? media.elapsed(at: context.date)
            let fraction = duration > 0 ? min(1, max(0, elapsed / duration)) : 0
            HStack(spacing: 10) {
                Text(Format.duration(elapsed))
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: 32, alignment: .leading)
                GeometryReader { proxy in
                    let bar = RoundedRectangle(cornerRadius: 2, style: .continuous)
                    ZStack(alignment: .leading) {
                        bar.fill(onArt ? theme.primary.opacity(0.25) : theme.track)
                        bar.fill(onArt ? theme.primary : theme.accent)
                            .frame(width: max(0, proxy.size.width * fraction))
                    }
                    .frame(height: hovering || dragFraction != nil ? 6 : 4)
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
                .frame(height: 14)
                .onHover { hovering = $0 }
                .disabled(duration <= 0)
                Text(duration > 0 ? "−" + Format.duration(max(0, duration - elapsed)) : "Live")
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: 38, alignment: .trailing)
            }
            .font(NotchFont.time(11.5, .medium))
            .foregroundStyle(theme.secondary)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Position in track")
            .accessibilityValue(duration > 0 ? "\(Format.duration(elapsed)) of \(Format.duration(duration))" : "Live")
            .accessibilityAdjustableAction { direction in
                guard duration > 0 else { return }
                let step: TimeInterval = direction == .increment ? 10 : -10
                media.seek(to: min(duration, max(0, media.elapsed() + step)))
            }
        }
    }
}

/// Shuffle, previous, play or pause, next and repeat; then the favorite, in Music, and the output.
private struct MusicTransport: View {
    let onArt: Bool
    let buttonHeight: CGFloat
    let showsOutputName: Bool
    @ObservedObject private var media = NowPlayingService.shared

    var body: some View {
        HStack(spacing: 8) {
            MusicButton(symbol: "shuffle", help: "Shuffle", isOn: media.shuffle, onArt: onArt, height: buttonHeight,
                        action: media.toggleShuffle)
            MusicButton(symbol: "backward.fill", help: "Previous", onArt: onArt, height: buttonHeight, action: media.previous)
            MusicPlayButton(isPlaying: media.isPlaying, height: buttonHeight + 8, action: media.playPause)
            MusicButton(symbol: "forward.fill", help: "Next", onArt: onArt, height: buttonHeight, action: media.next)
            MusicButton(symbol: media.repeatMode.symbol, help: "Repeat", isOn: media.repeatMode != .off, onArt: onArt,
                        height: buttonHeight, action: media.cycleRepeat)
            Spacer(minLength: 0)
            if media.canFavorite {
                let favorite = media.isFavorite ?? false
                MusicButton(symbol: favorite ? "star.fill" : "star", help: favorite ? "Remove from favorites" : "Favorite",
                            isMarked: favorite, onArt: onArt, height: buttonHeight, action: media.toggleFavorite)
            }
            MusicOutputButton(onArt: onArt, height: buttonHeight, showsName: showsOutputName)
        }
    }
}

/// A transport button: a symbol on a wash of the ink, solid accent while it's on.
private struct MusicButton: View {
    let symbol: String
    let help: String
    var isOn = false
    /// A favorite: the symbol in the accent's text color on the plain card.
    var isMarked = false
    let onArt: Bool
    let height: CGFloat
    let action: () -> Void
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOn ? theme.onAccent : isMarked && !onArt ? theme.accentText : theme.primary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: height + 8, height: height)
                .background(theme.controlShape.fill(fill))
                .contentShape(theme.controlShape)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.92))
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn || isMarked ? .isSelected : [])
    }

    private var fill: Color {
        if isOn { return theme.accent }
        return onArt ? theme.primary.opacity(hovering ? 0.24 : 0.14) : hovering ? theme.controlHover : theme.hover
    }
}

/// Play or pause: a solid face of the ink with the ground's color for its symbol.
private struct MusicPlayButton: View {
    let isPlaying: Bool
    let height: CGFloat
    let action: () -> Void
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(theme.background)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 60, height: height)
                .background(theme.controlShape.fill(theme.primary.opacity(hovering ? 0.86 : 1)))
                .contentShape(theme.controlShape)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.92))
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .help(isPlaying ? "Pause" : "Play")
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }
}

/// Where the sound goes, with its name where there's room. It swaps the section for the list of
/// outputs, as `OutputButton` does.
struct MusicOutputButton: View {
    var onArt = false
    var height: CGFloat = 28
    var showsName = true
    @ObservedObject private var outputs = AudioOutputs.shared
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        Button {
            if !outputs.isPickerShown { outputs.reload() }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { outputs.isPickerShown.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: outputs.current?.symbol ?? "hifispeaker.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                if showsName, let name = outputs.current?.name {
                    Text(name)
                        .font(NotchFont.bodyStrong)
                        .lineLimit(1)
                        .frame(maxWidth: 150, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .foregroundStyle(theme.primary)
            .padding(.horizontal, showsName && outputs.current != nil ? 12 : 0)
            .frame(minWidth: height + 8, minHeight: height, maxHeight: height)
            .background(theme.controlShape.fill(onArt ? theme.primary.opacity(hovering ? 0.24 : 0.14)
                                                : hovering ? theme.controlHover : theme.hover))
            .contentShape(theme.controlShape)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.96))
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .help(outputs.current.map { "Playing through \($0.name)" } ?? "Choose an output")
        .accessibilityLabel("Output")
        .accessibilityValue(outputs.current?.name ?? "")
    }
}

// MARK: Nothing playing

/// Nothing is playing: where the cover goes, a line about it, and a button to start Music or
/// Spotify.
struct MusicEmptyState: View {
    @Environment(\.notchTheme) private var theme

    var body: some View {
        GeometryReader { proxy in
            let side = max(64, min(132, proxy.size.height - MusicLayout.padding * 2))
            HStack(spacing: 20) {
                Image(systemName: "music.note")
                    .font(.system(size: side * 0.3, weight: .medium))
                    .foregroundStyle(theme.tertiary)
                    .frame(width: side, height: side)
                    .background(theme.cardShape.fill(theme.hover))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nothing playing")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(theme.primary)
                    Text("Play something in Music or Spotify and it shows up here.")
                        .font(NotchFont.subheadline)
                        .foregroundStyle(theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        ForEach(NowPlayingService.Player.allCases.filter(\.isInstalled), id: \.self) { player in
                            PillButton(title: player.name, symbol: "play.fill", height: 28) {
                                NowPlayingService.shared.start(player)
                            }
                        }
                    }
                    .padding(.top, 10)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(MusicLayout.padding)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
        .background(CardSurface())
        .overlay(alignment: .topTrailing) {
            MusicOutputButton(height: 28, showsName: true).padding(MusicLayout.padding)
        }
    }
}
