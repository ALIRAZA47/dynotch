import SwiftUI

/// A download's ring: how much has arrived, or a turning arc while the size isn't known.
struct DownloadRing: View {
    var fraction: Double?
    var lineWidth: CGFloat = 2.6
    var arrowSize: CGFloat = 7

    var body: some View {
        ZStack {
            if let fraction {
                ProgressRing(progress: fraction, color: DownloadMonitor.tint, lineWidth: lineWidth)
            } else {
                TurningArc(color: DownloadMonitor.tint, lineWidth: lineWidth)
            }
            Image(systemName: "arrow.down")
                .font(.system(size: arrowSize, weight: .black))
                .foregroundStyle(DownloadMonitor.tint)
        }
    }
}

private struct TurningArc: View {
    let color: Color
    let lineWidth: CGFloat
    @ViewState private var turning = false

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.22), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(turning ? 360 : 0))
                .animation(.linear(duration: 1.2).repeatForever(autoreverses: false), value: turning)
        }
        .onAppear { turning = true }
    }
}

/// The left ear while a download has the notch.
struct DownloadLabel: View {
    @ObservedObject private var monitor = DownloadMonitor.shared

    var body: some View {
        DownloadRing(fraction: monitor.fraction)
            .frame(width: 17, height: 17)
    }
}

/// The right ear while a download has the notch: the percentage, or the size so far.
struct DownloadAmount: View {
    @ObservedObject private var monitor = DownloadMonitor.shared

    var body: some View {
        Text(Self.text(fraction: monitor.fraction, received: monitor.received))
            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(DownloadMonitor.tint)
    }

    static func text(fraction: Double?, received: Int64) -> String {
        fraction.map { "\(Int(($0 * 100).rounded(.down)))%" } ?? Format.bytes(received)
    }
}

/// A download's ring, as a second activity.
struct DownloadGlyph: View {
    @ObservedObject private var monitor = DownloadMonitor.shared

    var body: some View {
        DownloadRing(fraction: monitor.fraction, lineWidth: 2.4, arrowSize: 6)
            .padding(1.5)
    }
}
