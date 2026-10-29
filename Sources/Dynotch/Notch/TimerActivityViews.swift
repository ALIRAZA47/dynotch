import SwiftUI

/// The left ear while a named timer has the notch: its ring and its name. The name is white, so
/// the amber stays the timer's own: its ring and its time.
struct CountdownLabel: View {
    let countdown: Countdown
    @ObservedObject private var store = TimerStore.shared
    @Environment(\.notchTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            ProgressRing(progress: countdown.progress(at: store.now), color: TimerStore.tint, lineWidth: 2.6)
                .frame(width: 17, height: 17)
            // `ClosedLayout` sizes the ear for this face, at 7 points a letter.
            Text(countdown.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.primary)
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
            .font(NotchFont.numeric(12.5))
            .foregroundStyle(TimerStore.tint)
    }
}

/// The right ear while the stopwatch has the notch: the time so far.
struct StopwatchTime: View {
    @ObservedObject private var store = TimerStore.shared

    var body: some View {
        Text(Format.duration(store.stopwatch.elapsed(at: store.now)))
            .font(NotchFont.numeric(12.5))
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
