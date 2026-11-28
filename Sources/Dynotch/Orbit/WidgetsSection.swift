import SwiftUI

/// Orbit's Widgets section: the widgets picked in Settings, side by side as cards, each with all
/// of the panel's height. Before Orbit they were a stack showing one card at a time beside the
/// player; with the player in its own section there's room for both at once, so nothing has to
/// turn to the one that matters now.
struct WidgetsSection: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        let widgets = settings.homeWidgets
        Group {
            if widgets.isEmpty {
                EmptyState(symbol: "square.grid.2x2", message: "Pick up to two widgets to keep here.") {
                    PillButton(title: "Choose Widgets") { SettingsWindowController.shared.show(page: .nook) }
                }
                .background(CardSurface())
            } else {
                HStack(spacing: NotchTheme.gap) {
                    ForEach(widgets, id: \.self) { widget in
                        HomeWidgetView(widget: widget)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel(widget.title)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .orbitHeader("Widgets", subtitle: widgets.isEmpty ? nil : widgets.map(\.title).joined(separator: " · ")) {
            OrbitButton(title: "Edit", symbol: "slider.horizontal.3", style: .ghost, help: "Choose widgets") {
                SettingsWindowController.shared.show(page: .nook)
            }
        }
    }
}

/// One widget's card.
struct HomeWidgetView: View {
    let widget: HomeWidget

    var body: some View {
        switch widget {
        case .calendar: CalendarWidget()
        case .mirror: MirrorWidget()
        case .shortcuts: ShortcutsWidget()
        case .timer: PomodoroWidget()
        case .devices: DevicesWidget()
        case .toggles: QuickTogglesWidget()
        case .notes: NotesWidget()
        case .weather: WeatherWidget()
        case .clock: WorldClockWidget()
        case .none: EmptyView()
        }
    }
}
