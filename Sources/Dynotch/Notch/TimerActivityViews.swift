import SwiftUI

/// The left ear while a named timer has the notch: its ring and its name.
struct CountdownLabel: View {
    let countdown: Countdown
    @ObservedObject private var store = TimerStore.shared

    var body: some View {
        HStack(spacing: 6) {
            ProgressRing(progress: countdown.progress(at: store.now), color: TimerStore.tint, lineWidth: 2.6)
                .frame(width: 17, height: 17)
            Text(countdown.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
        }
    }
}

/// The right ear while a named timer has the notch: the time left.
struct CountdownTime: View {
    let countdown: Countdown
    @ObservedObject private var store = TimerStore.shared

    var body: some View {
        Text(Format.duration(countdown.remaining(at: store.now).rounded(.up)))
            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(TimerStore.tint)
    }
}

/// The right ear while the stopwatch has the notch: the time so far.
struct StopwatchTime: View {
    @ObservedObject private var store = TimerStore.shared

    var body: some View {
        Text(Format.duration(store.stopwatch.elapsed(at: store.now)))
            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(TimerStore.stopwatchTint)
    }
}

/// A named timer's ring, as a second activity.
struct CountdownGlyph: View {
    let countdown: Countdown
    @ObservedObject private var store = TimerStore.shared

    var body: some View {
        ProgressRing(progress: countdown.progress(at: store.now), color: TimerStore.tint, lineWidth: 2.4)
            .padding(1.5)
    }
}

/// The stopwatch as a second activity: a ring that fills once a minute.
struct StopwatchGlyph: View {
    @ObservedObject private var store = TimerStore.shared

    var body: some View {
        let seconds = store.stopwatch.elapsed(at: store.now).truncatingRemainder(dividingBy: 60)
        ProgressRing(progress: seconds / 60, color: TimerStore.stopwatchTint, lineWidth: 2.4)
            .padding(1.5)
    }
}
