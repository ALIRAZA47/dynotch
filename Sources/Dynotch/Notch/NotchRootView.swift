import SwiftUI

/// Fills the panel; the notch hangs from its top center.
struct NotchRootView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        let metrics = viewModel.metrics
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if viewModel.isOpen {
                    OpenNotchView(viewModel: viewModel)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .top))
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
            .background(Color.black)
            .clipShape(NotchShape(topRadius: metrics.topRadius, bottomRadius: metrics.bottomRadius))
            .shadow(color: .black.opacity(viewModel.isOpen && settings.showOpenShadow ? 0.5 : 0), radius: 18, y: 8)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}

/// The notch at rest: blends into the hardware cutout, with live activities in its ears.
struct ClosedNotchView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var media = NowPlayingService.shared
    @ObservedObject private var timer = PomodoroTimer.shared
    @ObservedObject private var settings = AppSettings.shared

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
        settings.artworkTint ? Color(nsColor: media.accent) : .white
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
