import SwiftUI

/// Fills the panel; the notch hangs from its top center.
struct NotchRootView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var mic = MicMonitor.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The system's appearance, read before the notch sets its own: the menu bar follows it.
    @Environment(\.colorScheme) private var menuBarScheme

    var body: some View {
        let metrics = viewModel.metrics
        let theme = settings.theme
        let isLine = viewModel.isLine
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if viewModel.isOpen {
                    OpenNotchView(viewModel: viewModel)
                        .transition(.asymmetric(
                            insertion: (reduceMotion ? AnyTransition.opacity : .opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
                                .animation(.spring(response: 0.4, dampingFraction: 0.82).delay(0.04)),
                            removal: .opacity.animation(.easeOut(duration: 0.1))))
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
                             bottomRadius: metrics.bottomRadius, bandHeight: viewModel.geometry.closedSize.height)
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
            // Glass carries a lighter shadow: a heavy one shows through it.
            .shadow(color: .black.opacity(viewModel.isOpen && settings.showOpenShadow ? (theme.isGlass ? 0.3 : 0.5) : 0),
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
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                }
                .padding(.trailing, 11)
                .frame(width: layout.earWidth, height: layout.notchHeight, alignment: .trailing)
            }
            if layout.rowHeight > 0 {
                detailRow
                    .padding(.horizontal, 16)
                    .frame(height: layout.rowHeight, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { viewModel.open() }
    }

    private var tint: Color {
        settings.artworkTint ? Color(nsColor: media.accent) : theme.accent
    }

    @ViewBuilder
    private var leading: some View {
        switch viewModel.activity {
        case .idle:
            EmptyView()
        case .music, .trackPeek:
            ArtworkView(image: media.artwork, size: viewModel.geometry.closedSize.height - 12, cornerRadius: 6)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        case .timer:
            ProgressRing(progress: timer.progress, color: timer.phase.color, lineWidth: 2.6)
                .frame(width: 17, height: 17)
        case .notice(let notice):
            Image(systemName: notice.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(notice.tint)
                .contentTransition(.symbolEffect(.replace))
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
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(timer.phase.color)
        case .notice(let notice):
            switch notice.kind {
            case .meter(let level):
                LevelBar(level: level)
                    .frame(width: 62, height: 5)
            case .info:
                Text(notice.text)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(notice.tint)
                    .lineLimit(1)
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
                Text(track.artist.isEmpty ? track.title : "\(track.title) · \(track.artist)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
        case .notice(let notice):
            if let detail = notice.detail {
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
