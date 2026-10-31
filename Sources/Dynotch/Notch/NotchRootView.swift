import SwiftUI

/// Fills the panel; the notch hangs from its top center.
struct NotchRootView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var mic = MicMonitor.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The system's appearance, read before the notch sets its own: the menu bar follows it.
    @Environment(\.colorScheme) private var menuBarScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// The user's look, with the system's Increase Contrast and Reduce Transparency.
    private var theme: NotchTheme {
        var theme = settings.theme
        theme.isHighContrast = contrast == .increased
        theme.reducesTransparency = reduceTransparency
        return theme
    }

    var body: some View {
        let metrics = viewModel.metrics
        let isLine = viewModel.isLine
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if viewModel.isOpen {
                    OpenNotchView(viewModel: viewModel)
                        .transition(.asymmetric(
                            insertion: (reduceMotion ? AnyTransition.opacity : .opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
                                .animation(.spring(response: 0.4, dampingFraction: 0.82).delay(0.04)),
                            removal: .opacity.animation(.easeOut(duration: 0.1))))
                } else if viewModel.isGlancing {
                    GlanceView(viewModel: viewModel)
                        .transition(.asymmetric(
                            insertion: (reduceMotion ? AnyTransition.opacity : .opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
                                .animation(.spring(response: 0.34, dampingFraction: 0.84).delay(0.05)),
                            removal: .opacity.animation(.easeOut(duration: 0.08))))
                } else {
                    ClosedNotchView(viewModel: viewModel)
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.12)),
                            removal: .opacity.animation(.easeOut(duration: 0.08))))
                }
            }
            .frame(width: metrics.width, height: metrics.height, alignment: .top)
            .padding(.horizontal, metrics.topRadius)
            .background {
                NotchSurface(isGlass: viewModel.isOpen && theme.isGlass, topRadius: metrics.topRadius,
                             bottomRadius: metrics.bottomRadius, bandHeight: viewModel.geometry.closedSize.height,
                             chamfer: viewModel.isOpen)
                // Black fades into a light menu bar; a dark one needs the line a shade lighter than itself.
                if isLine, menuBarScheme == .dark {
                    Color.white.opacity(0.55)
                }
            }
            .clipShape(NotchShape(topRadius: metrics.topRadius, bottomRadius: metrics.bottomRadius))
            .overlay {
                if let color = onAirColor {
                    // A beat before it shows, so the Mirror's camera winding down as the notch closes doesn't flash it.
                    OnAirRing(color: color, metrics: metrics)
                        .transition(.asymmetric(insertion: .opacity.animation(.easeIn(duration: 0.3).delay(0.6)),
                                                removal: .opacity.animation(.easeOut(duration: 0.2))))
                }
            }
            .modifier(SnapshotLayer())
            // Glass carries a lighter shadow: a heavy one shows through it.
            .shadow(color: .black.opacity((viewModel.isOpen || viewModel.isGlancing) && settings.showOpenShadow
                        ? (viewModel.isOpen && theme.isGlass ? 0.3 : 0.5) : 0),
                    radius: 18, y: 8)
            // The line is faint until the pointer finds it.
            .opacity(isLine ? (viewModel.phase == .hovering ? 0.7 : 0.4) : 1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .environment(\.notchTheme, theme)
        .tint(theme.accent)
    }

    /// Green while a camera is on, orange while only the microphone is. The closed notch only.
    private var onAirColor: Color? {
        guard settings.onAirRing, !viewModel.isOpen else { return nil }
        return mic.cameraInUse ? .green : mic.micInUse ? .orange : nil
    }
}

/// One layer in a snapshot, so the shadow below it falls behind the notch. `ImageRenderer` otherwise
/// shades each thing in the notch from the shadow of what's above it, which a real window never does.
private struct SnapshotLayer: ViewModifier {
    @Environment(\.isSnapshot) private var isSnapshot

    func body(content: Content) -> some View {
        if isSnapshot {
            content.compositingGroup()
        } else {
            content
        }
    }
}

/// A thin glowing outline around the closed notch, open along the top edge of the screen.
private struct OnAirRing: View {
    let color: Color
    let metrics: NotchMetrics

    private static let lineWidth: CGFloat = 1.6

    var body: some View {
        // Just outside the black, so the hardware cutout doesn't hide half the line.
        let inset = Self.lineWidth / 2
        NotchShape(topRadius: metrics.topRadius, bottomRadius: metrics.bottomRadius + inset, includesTopEdge: false)
            .stroke(color, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round))
            .padding(-inset)
            .shadow(color: color.opacity(0.75), radius: 3)
            .allowsHitTesting(false)
    }
}

/// The notch at rest: blends into the hardware cutout, with live activities in its ears.
struct ClosedNotchView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var media = NowPlayingService.shared
    @ObservedObject private var timer = PomodoroTimer.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.notchTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let layout = viewModel.closedLayout
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leading
                    .padding(.leading, 10)
                    .frame(width: layout.earWidth, height: layout.notchHeight, alignment: .leading)
                Color.clear.frame(width: layout.notchWidth)
                HStack(spacing: ClosedLayout.glyphSpacing) {
                    trailing
                    if let secondary = viewModel.secondary {
                        CompactActivityView(activity: secondary)
                            .frame(width: ClosedLayout.glyphSize, height: ClosedLayout.glyphSize)
                            .transition(arrival(from: 0.5))
                    }
                }
                .padding(.trailing, 11)
                .frame(width: layout.earWidth, height: layout.notchHeight, alignment: .trailing)
            }
            if layout.rowHeight > 0 {
                detailRow
                    // The peek's title is semibold, a few points wider than a medium line, so its
                    // row gets 2 points more each side and cuts off no sooner. `ClosedLayout`
                    // widens a notice's row for 16.
                    .padding(.horizontal, viewModel.activity == .trackPeek ? 14 : 16)
                    .frame(height: layout.rowHeight, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { viewModel.activate() }
    }

    private var tint: Color {
        settings.artworkTint ? Color(nsColor: media.accent) : theme.accent
    }

    /// How a glyph comes into an ear: growing from `scale` as it fades in, or only fading with
    /// Reduce Motion, as the notch itself does.
    private func arrival(from scale: CGFloat) -> AnyTransition {
        reduceMotion ? .opacity : .scale(scale: scale).combined(with: .opacity)
    }

    @ViewBuilder
    private var leading: some View {
        switch viewModel.activity {
        case .idle:
            EmptyView()
        case .music, .trackPeek:
            ArtworkView(image: media.artwork, size: viewModel.geometry.closedSize.height - 12, cornerRadius: 6)
                .transition(arrival(from: 0.6))
        case .timer:
            ProgressRing(progress: timer.progress, color: timer.phase.color, lineWidth: 2.6)
                .frame(width: 17, height: 17)
        case .notice(let notice):
            Image(systemName: notice.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(notice.tint)
                .contentTransition(.symbolEffect(.replace))
                .overlay(alignment: .bottomTrailing) {
                    // A script chose the symbol and color above; the badge says so.
                    if notice.fromScript { ScriptBadge() }
                }
        case .countdown(let countdown):
            CountdownLabel(countdown: countdown)
        case .stopwatch:
            Image(systemName: "stopwatch.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(TimerStore.stopwatchTint)
        case .download:
            DownloadLabel()
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch viewModel.activity {
        case .idle:
            EmptyView()
        case .music, .trackPeek:
            AudioBars(isPlaying: media.isPlaying, color: tint)
                .frame(width: 20, height: 14)
        case .timer:
            Text(Format.duration(timer.remaining))
                .font(NotchFont.numeric(12.5))
                .foregroundStyle(timer.phase.color)
        case .notice(let notice):
            switch notice.kind {
            case .meter(let level):
                LevelBar(level: level)
                    .frame(width: 62, height: 5)
            case .info:
                NoticeText(text: notice.text, tint: notice.tint)
            }
        case .countdown(let countdown):
            CountdownTime(countdown: countdown)
        case .stopwatch:
            StopwatchTime()
        case .download:
            DownloadAmount()
        }
    }

    @ViewBuilder
    private var detailRow: some View {
        switch viewModel.activity {
        case .trackPeek:
            if let track = media.track {
                TrackPeekLine(title: track.title, artist: track.artist)
            }
        case .notice(let notice):
            if let detail = notice.detail {
                // `ClosedLayout` widens the notch for this face, up to `maxRowWidth`.
                Text(detail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
        default:
            EmptyView()
        }
    }
}

/// The track peek's line under the camera: the title carries it, and the artist sits back a step.
/// One line, cut off at the end when the row runs out of room. The settings stage draws it too,
/// at its `scale`.
struct TrackPeekLine: View {
    let title: String
    let artist: String
    var scale: CGFloat = 1
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let titleRun = Text(title)
            .font(.system(size: 12 * scale, weight: .semibold))
            .foregroundStyle(theme.primary)
        let artistRun = Text(artist.isEmpty ? "" : " · \(artist)")
            .font(.system(size: 12 * scale, weight: .medium))
            .foregroundStyle(theme.isHighContrast ? theme.secondary : .white.opacity(0.55))
        // One text, so VoiceOver reads the line as before and it truncates as a whole.
        Text("\(titleRun)\(artistRun)")
            .lineLimit(1)
    }
}

/// A notice's word in the right ear, in the notice's color. A color too dark to read on the black,
/// like a deep calendar color, a picked color or a script's tint, is lifted toward white just far
/// enough to reach 4.5:1; the symbol beside the camera keeps it exactly. A view of its own, so the
/// lift is worked out when the notice changes, not each time the notch redraws.
private struct NoticeText: View {
    let text: String
    let tint: Color
    @Environment(\.self) private var environment

    /// 4.6:1 on black, (L + 0.05) / 0.05: a little over WCAG's 4.5, so rounding can't drop under it.
    private static let minimumLuminance = 0.18

    var body: some View {
        // `ClosedLayout` sizes the ear for this face, at 7.5 points a character.
        Text(text)
            .font(NotchFont.numeric(12.5))
            .foregroundStyle(legibleTint)
            .lineLimit(1)
    }

    private var legibleTint: Color {
        let resolved = tint.resolve(in: environment)
        // As it shows on the black: sRGB values seen through the tint's own opacity.
        let shown = [resolved.red, resolved.green, resolved.blue].map { Double(min(max($0, 0), 1) * resolved.opacity) }
        guard Luminance.of(shown) < Self.minimumLuminance else { return tint }
        let lifted = Luminance.lifted(shown, to: Self.minimumLuminance)
        return Color(.sRGB, red: lifted[0], green: lifted[1], blue: lifted[2])
    }
}

/// A tiny terminal on a notice that a `dynotch://` link posted, so it can't pass for one of Dynotch's own.
struct ScriptBadge: View {
    var body: some View {
        Image(systemName: "terminal.fill")
            .font(.system(size: 5.5, weight: .black))
            .foregroundStyle(.black)
            .frame(width: 9, height: 9)
            .background(Circle().fill(.white))
            .offset(x: 4, y: 3)
            .accessibilityLabel("From a script")
    }
}
