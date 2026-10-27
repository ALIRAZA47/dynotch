import SwiftUI

/// A second activity's glyph at the end of the closed notch's right ear. Each kind watches
/// only its own source, so a ticking timer doesn't redraw the rest of the notch.
struct CompactActivityView: View {
    let activity: CompactActivity

    var body: some View {
        switch activity {
        case .timer: TimerGlyph()
        case .music: MusicGlyph()
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
