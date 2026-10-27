import SwiftUI

/// Named timers started from text like "tea 4m", and a stopwatch, next to the Pomodoro.
struct TimersWidget: View {
    @ObservedObject private var store = TimerStore.shared
    @ViewState private var draft = ""
    @ViewState private var isInvalid = false
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        WidgetCard(title: "Timers", symbol: "hourglass") {
            if !store.countdowns.isEmpty {
                Text("\(store.countdowns.count)")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
            }
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                field
                if store.countdowns.isEmpty {
                    Text("Type a name and a time, like tea 4m or laundry 45.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.notchTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    Scroller(.vertical) {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(store.countdowns) { countdown in
                                row(countdown)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }
                    // Takes what's left between the field and the stopwatch, however many timers there are.
                    .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
                    .clipped()
                }
                stopwatchRow
            }
        }
    }

    // MARK: New timer

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.notchTertiary)
            if isSnapshot {
                Text("tea 4m, nap 20")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.notchTertiary)
            } else {
                TextField("tea 4m, nap 20", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .onSubmit(submit)
                    .onChange(of: draft) { isInvalid = false }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.red.opacity(isInvalid ? 0.75 : 0), lineWidth: 1))
        .help("A name and a time: tea 4m, eggs 90s, nap 1h30. A number on its own is minutes.")
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
        return HStack(spacing: 5) {
            SmallButton(help: running ? "Pause" : "Resume", side: 16, action: { store.togglePause(countdown) }) {
                ZStack {
                    ProgressRing(progress: countdown.progress(at: store.now),
                                 color: running ? TimerStore.tint : Color.notchSecondary, lineWidth: 2)
                    if !running {
                        Image(systemName: "play.fill")
                            .font(.system(size: 5.5, weight: .black))
                            .foregroundStyle(Color.notchSecondary)
                    }
                }
                .frame(width: 13, height: 13)
            }
            Text(countdown.name)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(running ? Color.white : Color.notchSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(Format.duration(countdown.remaining(at: store.now).rounded(.up)))
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(running ? TimerStore.tint : Color.notchSecondary)
            SmallButton(help: "Cancel", side: 16, action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { store.cancel(countdown) }
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(Color.notchTertiary)
            }
        }
        .frame(height: 20)
    }

    private var stopwatchRow: some View {
        let stopwatch = store.stopwatch
        return HStack(spacing: 6) {
            Image(systemName: "stopwatch")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(stopwatch.isReset ? Color.notchTertiary : TimerStore.stopwatchTint)
                .frame(width: 13)
            Text(Format.duration(stopwatch.elapsed(at: store.now)))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(stopwatch.isRunning ? TimerStore.stopwatchTint : stopwatch.isReset ? Color.notchSecondary : .white)
            Spacer(minLength: 4)
            if !stopwatch.isReset {
                SmallButton(help: "Reset the stopwatch", action: store.resetStopwatch) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.notchSecondary)
                }
            }
            SmallButton(help: stopwatch.isRunning ? "Pause the stopwatch" : "Start the stopwatch", action: store.toggleStopwatch) {
                Image(systemName: stopwatch.isRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(TimerStore.stopwatchTint)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
    }
}

/// A borderless glyph button for the rows, with room around it to hit.
private struct SmallButton<Label: View>: View {
    let help: String
    var side: CGFloat = 18
    let action: () -> Void
    @ViewBuilder let label: Label
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            label
                .frame(width: side, height: side)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
