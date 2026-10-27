import SwiftUI

/// The widgets beside the player, one at a time like a stack of cards. It turns by itself to
/// whichever matters now: the calendar shortly before an event, the weather before rain, the
/// batteries when one runs low. The dots on its edge turn it by hand.
struct NookStack: View {
    let widgets: [HomeWidget]
    @ObservedObject private var calendar = CalendarService.shared
    @ObservedObject private var weather = WeatherService.shared
    @ObservedObject private var power = PowerMonitor.shared
    @ObservedObject private var devices = DeviceBatteryMonitor.shared
    /// Turned to by hand, or by something that needed the room. Stays until the next turn.
    @ViewState private var picked: HomeWidget?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let urgent = urgentWidget(at: context.date)
            let shown = picked.flatMap { widgets.contains($0) ? $0 : nil } ?? urgent ?? widgets[0]
            HomeWidgetView(widget: shown)
                .id(shown)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)),
                                        removal: .opacity.animation(.easeOut(duration: 0.1))))
                .overlay(alignment: .trailing) {
                    if widgets.count > 1 {
                        pager(shown: shown)
                            .padding(.trailing, 4)
                    }
                }
                .onChange(of: urgent) { _, widget in
                    guard let widget else { return }
                    withAnimation(.notchTab) { picked = widget }
                }
        }
    }

    /// One dot a widget; the one showing is longer.
    private func pager(shown: HomeWidget) -> some View {
        VStack(spacing: 0) {
            ForEach(widgets, id: \.self) { widget in
                let isShown = widget == shown
                Button {
                    withAnimation(.notchTab) { picked = widget }
                } label: {
                    Capsule()
                        .fill(Color.white.opacity(isShown ? 0.75 : 0.25))
                        .frame(width: 4, height: isShown ? 12 : 4)
                        .frame(width: 12, height: isShown ? 18 : 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle(scale: 0.8))
                .help(widget.title)
                .accessibilityLabel(widget.title)
                .accessibilityAddTraits(isShown ? .isSelected : [])
            }
        }
    }

    /// The first widget in the stack with something that can't wait.
    private func urgentWidget(at now: Date) -> HomeWidget? {
        widgets.first { widget in
            switch widget {
            case .calendar:
                calendar.hasEventAccess && calendar.events(on: now).contains { event in
                    !event.isAllDay && event.end > now && event.start.timeIntervalSince(now) < 15 * 60
                }
            case .weather:
                weather.conditions.map { $0.isRaining || ($0.rainStart.map { $0.timeIntervalSince(now) < 30 * 60 } ?? false) } ?? false
            case .devices:
                (power.hasBattery && !power.isCharging && power.level <= 20)
                    || devices.devices.contains { ($0.lowest ?? 100) <= 20 }
            default:
                false
            }
        }
    }
}
