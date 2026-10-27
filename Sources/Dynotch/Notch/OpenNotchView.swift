import SwiftUI

/// The expanded notch: a header row beside the camera, then the selected tab.
struct OpenNotchView: View {
    @ObservedObject var viewModel: NotchViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            OpenHeaderView(viewModel: viewModel)
                .frame(height: viewModel.geometry.closedSize.height)
            content
                .id(viewModel.visibleTab)
                // The old tab fades out quickly, so the two don't muddle together on the way.
                .transition(.asymmetric(
                    insertion: (reduceMotion ? AnyTransition.opacity : .opacity.combined(with: .offset(y: 5)))
                        .animation(.spring(response: 0.32, dampingFraction: 0.86).delay(0.04)),
                    removal: .opacity.animation(.easeOut(duration: 0.1))))
                .padding(.top, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, NotchTheme.inset)
        .padding(.bottom, NotchTheme.inset)
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
        let side = max(0, (settings.openWidth - NotchTheme.inset * 2 - viewModel.geometry.closedSize.width) / 2 - 6)
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(settings.enabledTabs) { tab in
                    TabButton(tab: tab, isSelected: viewModel.visibleTab == tab, namespace: tabSelection) {
                        withAnimation(.notchTab) { viewModel.tab = tab }
                    }
                }
            }
            .frame(width: side, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                BatteryBadge()
                IconButton(symbol: "gearshape.fill", size: 12, help: "Settings") {
                    SettingsWindowController.shared.show()
                }
            }
            .frame(width: side, alignment: .trailing)
        }
    }
}

/// A tab in the header: its symbol, and its name too while it's selected.
private struct TabButton: View {
    let tab: NotchTab
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 14)
                if isSelected {
                    Text(tab.title)
                        .font(NotchFont.bodyStrong)
                        .fixedSize()
                }
            }
            .foregroundStyle(isSelected || hovering ? theme.primary : theme.primary.opacity(0.5))
            .padding(.horizontal, isSelected ? 10 : 7)
            .frame(height: 24)
            .background {
                if isSelected {
                    Capsule()
                        .fill(theme.selection)
                        .matchedGeometryEffect(id: "selection", in: namespace)
                } else if hovering {
                    Capsule().fill(theme.control)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.92))
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .help(tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct BatteryBadge: View {
    @ObservedObject private var power = PowerMonitor.shared
    @Environment(\.notchTheme) private var theme

    var body: some View {
        if power.hasBattery {
            HStack(spacing: 4) {
                Text("\(power.level)%")
                    .font(NotchFont.numeric(11))
                    .foregroundStyle(theme.secondary)
                Image(systemName: power.symbol)
                    .font(.system(size: 13))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(power.tint, theme.secondary)
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
            HStack(spacing: NotchTheme.gap) {
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

/// Four cards side by side. The Pomodoro needs the least room; the timers need a little more
/// than the reminders and notes, which share what's left.
struct FocusTabView: View {
    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: NotchTheme.gap) {
                PomodoroWidget(compact: false)
                    .frame(width: (proxy.size.width * 0.2).rounded())
                TimersWidget()
                    .frame(width: (proxy.size.width * 0.27).rounded())
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
            HStack(spacing: NotchTheme.gap) {
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
