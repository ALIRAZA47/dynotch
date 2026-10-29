import SwiftUI

/// CPU, memory and network in one quiet line, at the foot of the Control tab's batteries. Disk
/// space and the upload rate are in its tooltip.
struct SystemFooter: View {
    @ObservedObject private var monitor = SystemMonitor.shared
    @Environment(\.notchTheme) private var theme

    var body: some View {
        // The etched line is a point taller than a hairline, so the gap under it is a point less.
        VStack(spacing: 6) {
            EtchedDivider()
            HStack(spacing: 0) {
                Text("CPU \(Int((monitor.cpu * 100).rounded()))%")
                    .foregroundStyle(monitor.cpu > 0.85 ? Color.orange : theme.tertiary)
                Spacer(minLength: 4)
                Text("Mem \(Int((monitor.memoryFraction * 100).rounded()))%")
                    .foregroundStyle(monitor.memoryFraction > 0.9 ? Color.orange : theme.tertiary)
                Spacer(minLength: 4)
                Label(Format.rate(monitor.download), systemImage: "arrow.down")
                    .foregroundStyle(theme.tertiary)
                    .layoutPriority(1)
            }
            .font(NotchFont.numeric(10.5))
            .minimumScaleFactor(0.85)
            .labelStyle(CompactLabelStyle())
            .lineLimit(1)
        }
        .help("Memory: \(Format.memory(monitor.memoryUsed)) of \(Format.memory(monitor.memoryTotal)) · "
              + "Disk: \(Format.bytes(monitor.diskFree)) free · Upload: \(Format.rate(monitor.upload))")
        .accessibilityElement(children: .combine)
        .onAppear { monitor.beginObserving() }
        .onDisappear { monitor.endObserving() }
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
