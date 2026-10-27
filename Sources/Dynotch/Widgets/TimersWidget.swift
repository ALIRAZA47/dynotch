import SwiftUI

/// Named timers started from text like "tea 4m", and a stopwatch, beside the Pomodoro's dial on
/// the Focus tab. The timers take what's left between the title and the stopwatch.
struct TimersList: View {
    @ObservedObject private var store = TimerStore.shared
    @ViewState private var draft = ""
    @ViewState private var isInvalid = false
    @Environment(\.notchTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CardTitle(title: "Timers", symbol: "hourglass") {
                if !store.countdowns.isEmpty {
                    Text("\(store.countdowns.count)")
                        .font(NotchFont.numeric(10.5))
                }
            }
            if store.countdowns.isEmpty {
                Text("Type a name and a time, like tea 4m or laundry 45.")
                    .font(NotchFont.footnote)
                    .foregroundStyle(theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Scroller(.vertical, fadesOverflow: true) {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(store.countdowns) { countdown in
                            row(countdown)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
                .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
            }
            stopwatchRow
            CardField(placeholder: "tea 4m, nap 20", text: $draft, isInvalid: isInvalid, onSubmit: submit)
                .onChange(of: draft) { isInvalid = false }
                .help("A name and a time: tea 4m, eggs 90s, nap 1h30. A number on its own is minutes.")
        }
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if withAnimation(.spring(response: 0.3, dampingFraction: 0.85), { store.start(text) }) {
            draft = ""
        } else {
            withAnimation(.easeOut(duration: 0.15)) { isInvalid = true }
        }
    }

    // MARK: Rows

    private func row(_ countdown: Countdown) -> some View {
        let running = countdown.isRunning
        return HStack(spacing: 4) {
            SmallButton(help: running ? "Pause" : "Resume", action: { store.togglePause(countdown) }) {
                ZStack {
                    ProgressRing(progress: countdown.progress(at: store.now),
                                 color: running ? TimerStore.tint : theme.secondary, lineWidth: 2)
                    if !running {
                        Image(systemName: "play.fill")
                            .font(.system(size: 5.5, weight: .black))
                            .foregroundStyle(theme.secondary)
                    }
                }
                .frame(width: 13, height: 13)
            }
            Text(countdown.name)
                .font(NotchFont.body)
                .foregroundStyle(running ? theme.primary : theme.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(countdown.name)
            Text(Format.duration(countdown.remaining(at: store.now).rounded(.up)))
                .font(NotchFont.numeric(12))
                .foregroundStyle(running ? TimerStore.tint : theme.secondary)
                .layoutPriority(1)
            SmallButton(help: "Cancel", action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { store.cancel(countdown) }
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(theme.tertiary)
            }
        }
        .padding(.horizontal, 1)
        .frame(height: 22)
    }

    private var stopwatchRow: some View {
        let stopwatch = store.stopwatch
        return HStack(spacing: 6) {
            Image(systemName: "stopwatch")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(stopwatch.isReset ? theme.tertiary : TimerStore.stopwatchTint)
                .frame(width: 16)
            Text(Format.duration(stopwatch.elapsed(at: store.now)))
                .font(NotchFont.numeric(11.5))
                .foregroundStyle(stopwatch.isRunning ? TimerStore.stopwatchTint : stopwatch.isReset ? theme.secondary : theme.primary)
            Spacer(minLength: 4)
            if !stopwatch.isReset {
                SmallButton(help: "Reset the stopwatch", action: store.resetStopwatch) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(theme.secondary)
                }
            }
            SmallButton(help: stopwatch.isRunning ? "Pause the stopwatch" : "Start the stopwatch", action: store.toggleStopwatch) {
                Image(systemName: stopwatch.isRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(TimerStore.stopwatchTint)
            }
        }
        .padding(.horizontal, 1)
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous).fill(theme.control))
    }
}

/// A borderless glyph button for the rows, with room around it to hit.
private struct SmallButton<Label: View>: View {
    let help: String
    var side: CGFloat = 16
    let action: () -> Void
    @ViewBuilder let label: Label
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            label
                .frame(width: side, height: side)
                .background(Circle().fill(hovering ? theme.controlHover : .clear))
                .contentShape(Circle().inset(by: -2))
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .help(help)
        .accessibilityLabel(help)
    }
}
