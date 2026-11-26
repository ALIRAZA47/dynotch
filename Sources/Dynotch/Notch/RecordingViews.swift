import SwiftUI

/// A plain red dot beside the camera while recording. It doesn't pulse: a SwiftUI pulse would wake
/// the app every frame.
struct RecordingDot: View {
    var size: CGFloat = 11

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: size, height: size)
            .accessibilityLabel("Recording")
    }
}

/// The time in the right ear, or a word while the file's being saved. A view of its own, so the
/// clock's tick doesn't redraw the rest of the notch.
struct RecordingClock: View {
    @ObservedObject private var recorder = ScreenRecorder.shared

    var body: some View {
        // `ClosedLayout` sizes the ear for this.
        Text(recorder.state == .saving ? "Saving" : Format.duration(recorder.elapsed))
            .font(NotchFont.numeric(12.5))
            .foregroundStyle(.white)
            .lineLimit(1)
    }
}

/// The dot at the end of the right ear, beside a notice that's taken the notch.
struct RecordingGlyph: View {
    var body: some View {
        RecordingDot(size: 10)
            .frame(width: ClosedLayout.glyphSize, height: ClosedLayout.glyphSize)
    }
}

/// The glance while a recording runs: how long it's been, what it is, and Stop. It's the recording's
/// for as long as that goes on, whatever the closed notch is showing, so Stop is always where you
/// expect it. Stop is one size and sits at the end of the line, so the digits changing can't move it.
struct RecordingGlance: View {
    @ObservedObject var viewModel: NotchViewModel
    let band: CGFloat
    @ObservedObject private var recorder = ScreenRecorder.shared
    @Environment(\.notchTheme) private var theme

    private var isSaving: Bool { recorder.state == .saving }

    var body: some View {
        GlanceLayout(band: band) {
            ZStack {
                theme.controlShape.fill(theme.alert.opacity(0.16))
                RecordingDot(size: 18)
            }
        } trailing: {
            EmptyView()
        } center: {
            HStack(spacing: 8) {
                GlanceFigure(caption: caption, figure: isSaving ? "Saving" : Format.duration(recorder.elapsed), tint: theme.primary)
                Spacer(minLength: 0)
                if !isSaving {
                    StopRecordingButton {
                        if viewModel.acceptsStop { recorder.stop() }
                    }
                }
            }
        }
        .onAppear { viewModel.stopAppeared() }
    }

    /// "1280 × 720 · MP4"
    private var caption: String {
        [recorder.plan?.sizeText, recorder.format.title].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Stop: big, one size, a red focus button on the black.
private struct StopRecordingButton: View {
    let action: () -> Void
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            FocusButtonLabel(title: "Stop", symbol: "stop.fill", tint: theme.alert, height: 36, hovering: hovering)
                .frame(minWidth: 92)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.95))
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .help("Stop recording")
        .accessibilityLabel("Stop recording")
    }
}
