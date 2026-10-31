import SwiftUI

/// CPU, memory and network in one quiet line, at the foot of the Control tab's batteries. Disk
/// space and the upload rate are in its tooltip.
struct SystemFooter: View {
    @ObservedObject private var monitor = SystemMonitor.shared
    @Environment(\.notchTheme) private var theme
    /// Snapshots show their sample, which a real reading would replace.
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        // The etched line is a point taller than a hairline, so the gap under it is a point less.
        VStack(spacing: 6) {
            EtchedDivider()
            // The size the card's width allows for the widest readings, so it holds as the numbers
            // change. Past those, a step smaller rather than a reading cut short.
            ViewThatFits(in: .horizontal) {
                steadyRow(10.5)
                steadyRow(10)
                steadyRow(9.5)
                row(9.5)
            }
            .minimumScaleFactor(0.85)
            .labelStyle(CompactLabelStyle())
            .lineLimit(1)
        }
        .help("Memory: \(Format.memory(monitor.memoryUsed)) of \(Format.memory(monitor.memoryTotal)) · "
              + "Disk: \(Format.bytes(monitor.diskFree)) free · Upload: \(Format.rate(monitor.upload))")
        .accessibilityElement(children: .combine)
        .onAppear { if !isSnapshot { monitor.beginObserving() } }
        .onDisappear { if !isSnapshot { monitor.endObserving() } }
    }

    /// The readings at `size`, in a row that only fits where the widest ones would.
    private func steadyRow(_ size: CGFloat) -> some View {
        ZStack {
            HStack(spacing: 4) {
                Text("CPU 99%")
                Text("Mem 99%")
                Label("888 bytes/s", systemImage: "arrow.down")
            }
            .font(NotchFont.numeric(size))
            .fixedSize()
            .hidden()
            .accessibilityHidden(true)
            row(size, isWhole: true)
        }
    }

    /// The readings at `size`. With `isWhole` none can give up width, so the row fits or it doesn't.
    private func row(_ size: CGFloat, isWhole: Bool = false) -> some View {
        HStack(spacing: 0) {
            Text("CPU \(Int((monitor.cpu * 100).rounded()))%")
                .foregroundStyle(monitor.cpu > 0.85 ? Color.orange : theme.tertiary)
                .fixedSize(horizontal: isWhole, vertical: false)
            Spacer(minLength: 4)
            Text("Mem \(Int((monitor.memoryFraction * 100).rounded()))%")
                .foregroundStyle(monitor.memoryFraction > 0.9 ? Color.orange : theme.tertiary)
                .fixedSize(horizontal: isWhole, vertical: false)
            Spacer(minLength: 4)
            Label(Format.rate(monitor.download), systemImage: "arrow.down")
                .foregroundStyle(theme.tertiary)
                .fixedSize(horizontal: isWhole, vertical: false)
                .layoutPriority(1)
        }
        .font(NotchFont.numeric(size))
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 8.5, weight: .bold))
            configuration.title
        }
    }
}
