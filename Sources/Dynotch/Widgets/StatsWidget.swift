import SwiftUI

struct SystemStatsWidget: View {
    @ObservedObject private var monitor = SystemMonitor.shared

    var body: some View {
        WidgetCard(title: "System", symbol: "cpu") {
            VStack(spacing: 9) {
                StatRow(label: "CPU", value: "\(Int((monitor.cpu * 100).rounded()))%",
                        fraction: monitor.cpu, color: color(for: monitor.cpu)) {
                    Sparkline(values: monitor.cpuHistory, color: color(for: monitor.cpu))
                        .frame(width: 44, height: 14)
                }
                StatRow(label: "Memory",
                        value: "\(Format.memory(monitor.memoryUsed)) of \(Format.memory(monitor.memoryTotal))",
                        fraction: monitor.memoryFraction, color: color(for: monitor.memoryFraction))
                StatRow(label: "Disk", value: "\(Format.bytes(monitor.diskFree)) free",
                        fraction: monitor.diskUsedFraction, color: color(for: monitor.diskUsedFraction))
                HStack(spacing: 12) {
                    Label(Format.rate(monitor.download), systemImage: "arrow.down")
                    Label(Format.rate(monitor.upload), systemImage: "arrow.up")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.notchSecondary)
                .labelStyle(CompactLabelStyle())
            }
        }
        .onAppear { monitor.beginObserving() }
        .onDisappear { monitor.endObserving() }
    }

    private func color(for fraction: Double) -> Color {
        fraction > 0.85 ? .red : fraction > 0.65 ? .orange : Color(red: 0.4, green: 0.8, blue: 1)
    }
}

private struct StatRow<Accessory: View>: View {
    let label: String
    let value: String
    let fraction: Double
    let color: Color
    @ViewBuilder var accessory: Accessory

    init(label: String, value: String, fraction: Double, color: Color,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.label = label
        self.value = value
        self.fraction = fraction
        self.color = color
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
                accessory
                Text(value)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.notchSecondary)
                    .lineLimit(1)
            }
            LevelBar(level: fraction, color: color)
                .frame(height: 4)
        }
    }
}

private struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                guard values.count > 1 else { return }
                let step = proxy.size.width / CGFloat(values.count - 1)
                for (index, value) in values.enumerated() {
                    let point = CGPoint(x: CGFloat(index) * step, y: proxy.size.height * (1 - CGFloat(min(1, value))))
                    index == 0 ? path.move(to: point) : path.addLine(to: point)
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
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
