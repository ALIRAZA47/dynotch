import SwiftUI

/// A download's ring: how much has arrived, or an arc turning round it while the size isn't known.
/// The arc turns in Core Animation, so the app doesn't wake for each frame.
struct DownloadRing: View {
    var fraction: Double?
    var lineWidth: CGFloat = 2.6
    var arrowSize: CGFloat = 7
    /// A faint, wider copy of the arc under it (`ProgressRing.halo`), for the glance's ring. The
    /// closed notch's rings stay plain. The turning arc has none.
    var halo = false

    var body: some View {
        ZStack {
            if let fraction {
                ProgressRing(progress: fraction, color: DownloadMonitor.tint, lineWidth: lineWidth, halo: halo)
            } else {
                SpinningArc(color: DownloadMonitor.tint, lineWidth: lineWidth)
            }
            Image(systemName: "arrow.down")
                .font(.system(size: arrowSize, weight: .black))
                .foregroundStyle(DownloadMonitor.tint)
        }
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
            .font(NotchFont.numeric(12.5))
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
