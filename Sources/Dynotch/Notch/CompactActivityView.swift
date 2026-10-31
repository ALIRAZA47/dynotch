import SwiftUI

/// A second activity's glyph at the end of the closed notch's right ear. Each kind watches
/// only its own source, so a ticking timer doesn't redraw the rest of the notch.
struct CompactActivityView: View {
    let activity: CompactActivity

    var body: some View {
        switch activity {
        case .timer: TimerGlyph()
        case .music: MusicGlyph()
        case .micMuted: MuteBadge()
        case .countdown(let countdown): CountdownGlyph(countdown: countdown)
        case .stopwatch: StopwatchGlyph()
        case .download: DownloadGlyph()
        case .focus(let mode): FocusGlyph(mode: mode)
        case .held(let count): HeldBadge(count: count)
        case .keepAwake: KeepAwakeGlyph()
        }
    }
}

/// The focus timer's ring.
private struct TimerGlyph: View {
    @ObservedObject private var timer = PomodoroTimer.shared

    var body: some View {
        ProgressRing(progress: timer.progress, color: timer.phase.color, lineWidth: 2.4)
            .padding(1.5)
    }
}

/// The album art, small.
private struct MusicGlyph: View {
    @ObservedObject private var media = NowPlayingService.shared

    var body: some View {
        ArtworkView(image: media.artwork, size: ClosedLayout.glyphSize, cornerRadius: 4)
    }
}

/// A red disc with a crossed-out microphone, while the mic is muted.
struct MuteBadge: View {
    var size: CGFloat = ClosedLayout.glyphSize

    var body: some View {
        Image(systemName: "mic.slash.fill")
            .font(.system(size: size * 0.52, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.red))
            .accessibilityLabel("Microphone muted")
    }
}

/// How many notices are waiting for a call or a presentation to end.
struct HeldBadge: View {
    let count: Int
    var size: CGFloat = ClosedLayout.glyphSize

    var body: some View {
        Text(count > 9 ? "9+" : "\(count)")
            .font(.system(size: size * 0.6, weight: .bold, design: .rounded))
            .foregroundStyle(.black)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.white.opacity(0.85)))
            .accessibilityLabel(count == 1 ? "1 notice waiting" : "\(count) notices waiting")
    }
}

/// A cup, while Keep Awake is on.
struct KeepAwakeGlyph: View {
    var size: CGFloat = ClosedLayout.glyphSize

    var body: some View {
        Image(systemName: "cup.and.saucer.fill")
            .font(.system(size: size * 0.68, weight: .semibold))
            .foregroundStyle(Color.orange)
            .frame(width: size, height: size)
            .accessibilityLabel("Keep Awake is on")
    }
}

/// The symbol of the Focus that's on, in its color.
struct FocusGlyph: View {
    let mode: FocusMode
    var size: CGFloat = ClosedLayout.glyphSize

    var body: some View {
        Image(systemName: mode.symbol)
            .font(.system(size: size * 0.78, weight: .semibold))
            .foregroundStyle(mode.tint)
            .frame(width: size, height: size)
            .accessibilityLabel("\(mode.name) is on")
    }
}
