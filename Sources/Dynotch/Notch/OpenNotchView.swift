import SwiftUI

/// The expanded notch: a header row beside the camera, then the selected tab.
struct OpenNotchView: View {
    @ObservedObject var viewModel: NotchViewModel

    var body: some View {
        VStack(spacing: 0) {
            OpenHeaderView(viewModel: viewModel)
                .frame(height: viewModel.geometry.closedSize.height)
            content
                .id(viewModel.visibleTab)
                .transition(.opacity.combined(with: .offset(y: 4)))
                .padding(.top, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.visibleTab {
        case .home: HomeTabView()
        case .tray: TrayTabView(viewModel: viewModel)
        case .focus: FocusTabView()
        case .stats: StatsTabView()
        }
    }
}

struct OpenHeaderView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var settings = AppSettings.shared
    @Namespace private var tabSelection

    var body: some View {
        // Each side gets what's left of the width once the camera housing is excluded.
        let side = max(0, (settings.openWidth - 36 - viewModel.geometry.closedSize.width) / 2 - 6)
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(settings.enabledTabs) { tab in
                    TabButton(tab: tab, isSelected: viewModel.visibleTab == tab, namespace: tabSelection) {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { viewModel.tab = tab }
                    }
                }
            }
            .frame(width: side, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                BatteryBadge()
                IconButton(symbol: "gearshape.fill", size: 11.5, help: "Settings") {
                    SettingsWindowController.shared.show()
                }
            }
            .frame(width: side, alignment: .trailing)
        }
    }
}

private struct TabButton: View {
    let tab: NotchTab
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 11, weight: .semibold))
                if isSelected {
                    Text(tab.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .fixedSize()
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.white.opacity(hovering ? 0.85 : 0.45))
            .padding(.horizontal, isSelected ? 10 : 7)
            .frame(height: 22)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Color.white.opacity(0.14))
                        .matchedGeometryEffect(id: "selection", in: namespace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tab.title)
    }
}

private struct BatteryBadge: View {
    @ObservedObject private var power = PowerMonitor.shared

    var body: some View {
        if power.hasBattery {
            HStack(spacing: 4) {
                Text("\(power.level)%")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.notchSecondary)
                Image(systemName: power.symbol)
                    .font(.system(size: 13))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(power.tint, Color.white.opacity(0.5))
            }
            .help(power.statusDescription)
        }
    }
}

// MARK: Tabs

struct HomeTabView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        GeometryReader { proxy in
            let widgets = settings.homeWidgets
            HStack(spacing: 12) {
                MediaPlayerView()
                    .frame(width: widgets.isEmpty ? proxy.size.width : (proxy.size.width * 0.5).rounded())
                ForEach(Array(widgets.enumerated()), id: \.offset) { _, widget in
                    HomeWidgetView(widget: widget)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

struct HomeWidgetView: View {
    let widget: HomeWidget

    var body: some View {
        switch widget {
        case .calendar: CalendarWidget()
        case .mirror: MirrorWidget()
        case .shortcuts: ShortcutsWidget()
        case .timer: PomodoroWidget(compact: true)
        case .devices: DevicesWidget()
        case .toggles: QuickTogglesWidget(compact: true)
        case .notes: NotesWidget()
        case .weather: WeatherWidget()
        case .none: EmptyView()
        }
    }
}

struct FocusTabView: View {
    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 12) {
                PomodoroWidget(compact: false)
                    .frame(width: (proxy.size.width * 0.3).rounded())
                RemindersWidget()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                NotesWidget()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct StatsTabView: View {
    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 12) {
                SystemStatsWidget()
                    .frame(width: (proxy.size.width * 0.38).rounded())
                DevicesWidget()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                QuickTogglesWidget(compact: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
