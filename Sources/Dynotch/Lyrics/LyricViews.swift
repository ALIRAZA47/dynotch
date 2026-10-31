import SwiftUI

/// The line being sung, going by the same position the scrubber does, and only while it's on screen.
/// A note stands in before the first line and in the gaps, so the row keeps its place.
struct LyricLine: View {
    let lyrics: Lyrics
    @ObservedObject private var media = NowPlayingService.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let line = lyrics.line(at: media.elapsed(at: context.date))
            Text(line ?? "♪")
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .id(line)
                .transition(.opacity)
                .animation(.easeOut(duration: 0.2), value: line)
                .accessibilityLabel(line ?? "Instrumental")
        }
    }
}

/// The closed notch's second row, while it's showing lyrics.
struct LyricRow: View {
    @ObservedObject private var service = LyricsService.shared

    var body: some View {
        if let lyrics = service.lyrics {
            // As `ClosedLayout` sizes it, for the song's longest line.
            LyricLine(lyrics: lyrics)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}
