import SwiftUI

/// The expanded notch: a header row beside the camera, then the selected tab, or the command field.
struct OpenNotchView: View {
    @ObservedObject var viewModel: NotchViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            OpenHeaderView(viewModel: viewModel)
                .frame(height: viewModel.geometry.closedSize.height)
            content
                .id(viewModel.isCommandMode ? "command" : viewModel.visibleTab.rawValue)
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
        if viewModel.isCommandMode {
            CommandView(viewModel: viewModel)
        } else {
            switch viewModel.visibleTab {
            case .home: HomeTabView(viewModel: viewModel)
            case .tray: TrayTabView(viewModel: viewModel)
            case .focus: FocusTabView()
            case .stats: ControlTabView()
            }
        }
    }
}

/// The tabs on the left of the camera; the command field and the ··· menu on the right.
struct OpenHeaderView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        // Each side gets what's left of the width once the camera housing is excluded.
        let side = max(0, (settings.openWidth - NotchTheme.inset * 2 - viewModel.geometry.closedSize.width) / 2 - 6)
        HStack(spacing: 0) {
            TabSwitcher(viewModel: viewModel)
                .frame(width: side, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                CommandPill(viewModel: viewModel, showsTitle: side >= 196)
                MoreMenu(viewModel: viewModel)
            }
            .frame(width: side, alignment: .trailing)
        }
    }
}

/// The tabs in a track. The selected one shows its name; in the command field none is picked out.
private struct TabSwitcher: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.notchTheme) private var theme
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 2) {
            ForEach(settings.enabledTabs) { tab in
                TabButton(tab: tab, isSelected: viewModel.visibleTab == tab, isMuted: viewModel.isCommandMode,
                          namespace: selection) {
                    withAnimation(.notchTab) {
                        viewModel.endCommand()
                        viewModel.tab = tab
                    }
                }
            }
        }
        .padding(2)
        .background(Capsule().fill(theme.control.opacity(0.85)))
    }
}

/// A tab: its symbol, and its name too while it's selected.
private struct TabButton: View {
    let tab: NotchTab
    let isSelected: Bool
    /// The command field covers the tabs, so the selected one goes grey.
    let isMuted: Bool
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
            .foregroundStyle(isSelected || hovering ? theme.primary : theme.primary.opacity(0.55))
            .padding(.horizontal, isSelected ? 10 : 8)
            .frame(minWidth: 30)
            .frame(height: 24)
            .background {
                if isSelected {
                    Capsule()
                        .fill(isMuted ? theme.controlHover : theme.selection)
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

/// Opens the command field, with its shortcut beside it. In the field it reads Command and esc, and closes it.
private struct CommandPill: View {
    @ObservedObject var viewModel: NotchViewModel
    var showsTitle: Bool
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        let isActive = viewModel.isCommandMode
        let key = isActive ? "esc" : settings.commandShortcut ? "⌃⌥K" : nil
        Button {
            withAnimation(.notchTab) {
                if isActive { viewModel.endCommand() } else { viewModel.beginCommand() }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10.5, weight: .bold))
                if showsTitle || isActive {
                    Text(isActive ? "Command" : "Type a command")
                        .font(isActive ? NotchFont.bodyStrong : NotchFont.body)
                        .lineLimit(1)
                }
                if let key {
                    Text(key)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.primary.opacity(isActive ? 0.85 : 0.6))
                        .padding(.horizontal, 5)
                        .frame(height: 17)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(theme.primary.opacity(isActive ? 0.14 : 0.09)))
                        .padding(.leading, 2)
                }
            }
            .foregroundStyle(isActive ? theme.primary : hovering ? theme.secondary : theme.tertiary)
            .padding(.leading, 9)
            .padding(.trailing, key == nil ? 9 : 4)
            .frame(height: 24)
            .background(Capsule().fill(isActive ? theme.selection : hovering ? theme.controlHover : theme.control))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.95))
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .help(isActive ? "Close the command field" : "Start a timer, add a note or a reminder, switch a profile…")
        .accessibilityLabel(isActive ? "Close the command field" : "Command field")
    }
}

/// Settings, the layout and the profiles, behind ···.
private struct MoreMenu: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var profiles = ProfileStore.shared
    @Environment(\.notchTheme) private var theme

    var body: some View {
        MenuButton(help: "More") { hovering in
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(hovering ? theme.primary : theme.secondary)
                .frame(width: 26, height: 24)
                .background(Capsule().fill(hovering ? theme.control : .clear))
        } items: {
            entries
        }
    }

    private var entries: [MenuEntry] {
        var entries: [MenuEntry] = [
            .item("Settings…") { SettingsWindowController.shared.show() },
            .item("Edit Layout…") { SettingsWindowController.shared.show(page: .nook) },
        ]
        if !profiles.profiles.isEmpty {
            entries.append(.separator)
            entries.append(.item("Profiles", isEnabled: false) {})
            for profile in profiles.profiles {
                entries.append(.item(profile.name, isChecked: profile.id == profiles.activeID) {
                    profiles.switchTo(profile)
                })
            }
        }
        return entries
    }
}

// MARK: Tabs

/// The player, and beside it the stack of widgets.
struct HomeTabView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        GeometryReader { proxy in
            let widgets = settings.homeWidgets
            HStack(spacing: NotchTheme.gap) {
                MediaPlayerView()
                    .frame(width: widgets.isEmpty ? proxy.size.width : (proxy.size.width * 0.525).rounded())
                if !widgets.isEmpty {
                    NookStack(widgets: widgets, turns: viewModel.stackTurns)
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
        case .timer: PomodoroWidget()
        case .devices: DevicesWidget()
        case .toggles: QuickTogglesWidget()
        case .notes: NotesWidget()
        case .weather: WeatherWidget()
        case .none: EmptyView()
        }
    }
}

/// The timers on the left, the reminders or the notes on the right.
struct FocusTabView: View {
    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: NotchTheme.gap) {
                TimersCard()
                    .frame(width: (proxy.size.width * 0.49).rounded())
                FocusListsCard()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// The Pomodoro's dial with its controls under it, and the named timers beside it.
private struct TimersCard: View {
    var body: some View {
        GeometryReader { proxy in
            // As large as the room left under it for the controls allows.
            let dial = min(116, max(72, proxy.size.height - NotchTheme.cardPadding.top * 2 - 42))
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 8) {
                    PomodoroDial(side: dial)
                    PomodoroControls()
                }
                .frame(width: max(dial, 104))
                TimersList()
            }
            .padding(12)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .background(CardSurface())
    }
}

/// The reminders or the notes, one at a time, under a switch between them.
private struct FocusListsCard: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var calendar = CalendarService.shared
    @ViewState private var editor = NoteEditorHandle()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                CardSegments(selection: $settings.focusShowsNotes, segments: [
                    .init(value: false, title: "Reminders",
                          count: calendar.hasReminderAccess && !calendar.reminders.isEmpty ? calendar.reminders.count : nil),
                    .init(value: true, title: "Notes"),
                ])
                Spacer(minLength: 0)
                if settings.focusShowsNotes {
                    NotesActions(editor: editor)
                }
            }
            if settings.focusShowsNotes {
                NoteBody(editor: editor)
            } else {
                RemindersList()
            }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 12, trailing: 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(CardSurface())
    }
}

/// Toggles, the display and sound levels, and the batteries with the system underneath.
struct ControlTabView: View {
    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: NotchTheme.gap) {
                ControlToggleGrid()
                    .frame(width: (proxy.size.width * 0.34).rounded())
                LevelControls()
                    .frame(width: (proxy.size.width * 0.29).rounded())
                DevicesWidget(showsSystem: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
