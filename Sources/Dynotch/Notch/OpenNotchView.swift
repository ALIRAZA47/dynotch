import SwiftUI

/// The open notch, Orbit's panel: the section's title and buttons in the band beside the camera,
/// the section under it, and the command field at the foot. The section buttons sit outside the
/// panel; `NotchRootView` draws them.
struct OpenNotchView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var settings = AppSettings.shared
    @ViewState private var host = RowActionHost()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let band = NotchViewModel.bandHeight(closedHeight: viewModel.geometry.closedSize.height)
        VStack(spacing: 0) {
            Color.clear.frame(height: band)
            content
                .id(viewModel.isCommandMode ? "command" : viewModel.visibleTab.rawValue)
                // The old section fades out quickly, so the two don't muddle together on the way.
                .transition(.asymmetric(
                    insertion: (reduceMotion ? AnyTransition.opacity : .opacity.combined(with: .offset(y: 6)))
                        .animation(.spring(response: 0.32, dampingFraction: 0.86).delay(0.04)),
                    removal: .opacity.animation(.easeOut(duration: 0.1))))
                .padding(.top, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if !viewModel.isCommandMode {
                VStack(spacing: 8) {
                    if settings.rowActionMode == .bar, viewModel.visibleTab == .live || viewModel.visibleTab == .agents {
                        RowActionBar(host: host)
                    }
                    CommandFoot(viewModel: viewModel)
                }
                .padding(.top, NotchTheme.commandFieldGap)
            }
        }
        .padding(.horizontal, NotchTheme.inset)
        .padding(.bottom, 14)
        .overlayPreferenceValue(OrbitHeaderKey.self) { header in
            BandHeader(viewModel: viewModel, header: header, host: host)
                .frame(height: band)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .environment(\.rowActionHost, host)
        .onChange(of: viewModel.visibleTab) { host.clear() }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isCommandMode {
            CommandView(viewModel: viewModel)
                .orbitHeader("Command", subtitle: "Type, then Return")
        } else {
            switch viewModel.visibleTab {
            case .live: LiveSectionView(viewModel: viewModel)
            case .music: MediaPlayerView().orbitHeader("Music")
            case .home: HomeTabView(viewModel: viewModel).orbitHeader("Widgets")
            case .tray: TrayTabView(viewModel: viewModel).orbitHeader("Tray")
            case .clipboard: ClipboardShelf(viewModel: viewModel).orbitHeader("Clipboard")
            case .focus: FocusTabView().orbitHeader("Focus")
            case .notes: NotesWidget().orbitHeader("Notes")
            case .calendar: CalendarWidget().orbitHeader("Calendar")
            case .stats: ControlSection()
            case .agents: AgentsTabView(viewModel: viewModel).orbitHeader("Agents")
            }
        }
    }
}

/// The band beside the camera: the section's title and its second line left of the housing, its
/// buttons and ··· right of it. With Row actions set to Beside the camera, the row under the
/// pointer's buttons take the right side; with the section buttons there, they take both.
struct BandHeader: View {
    @ObservedObject var viewModel: NotchViewModel
    let header: OrbitHeader?
    @ObservedObject var host: RowActionHost
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.notchTheme) private var theme

    var body: some View {
        // Each side gets what's left of the width once the camera housing is excluded.
        let side = max(0, (settings.openWidth - 36 - viewModel.geometry.closedSize.width) / 2 - 12)
        if settings.sectionPlacement == .band, !viewModel.isCommandMode {
            Color.clear
        } else {
            HStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(header?.title ?? viewModel.visibleTab.title)
                        .font(NotchFont.title)
                        .foregroundStyle(theme.primary)
                        .lineLimit(1)
                        .fixedSize()
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle = header?.subtitle {
                        Text(subtitle)
                            .font(.system(size: 12.5))
                            .foregroundStyle(theme.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(width: side, alignment: .leading)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    if settings.rowActionMode == .band, let hot = host.hot, !hot.actions.isEmpty {
                        ForEach(hot.actions) { action in
                            RowActionButton(action: action, height: NotchTheme.headerControlHeight)
                        }
                    } else if let actions = header?.actions {
                        actions
                    }
                    MoreMenu(viewModel: viewModel)
                }
                .frame(width: side, alignment: .trailing)
            }
            .padding(.horizontal, 18)
        }
    }
}

/// The command field at the panel's foot. A click, or ⌃⌥K, puts the cursor in it; then the
/// section above gives way to what the command can do.
struct CommandFoot: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        Button {
            withAnimation(.notchTab) { viewModel.beginCommand() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("Type a command: tea 4m, note…, tray")
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if settings.commandShortcut {
                    HStack(spacing: 3) {
                        ForEach(["⌃", "⌥", "K"], id: \.self) { Keycap(label: $0) }
                    }
                }
            }
            .foregroundStyle(hovering ? theme.primary : theme.secondary)
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .frame(height: NotchTheme.commandFieldHeight)
            .background(theme.controlShape.fill(theme.field))
            .overlay(theme.controlShape.strokeBorder(hovering ? theme.accent.opacity(0.6) : theme.line))
            .contentShape(theme.controlShape)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.99))
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .help("Start a timer, add a note or a reminder, switch a profile…")
        .accessibilityLabel("Command field")
    }
}

/// Settings, the layout and the profiles, behind ···, on a disc of glass while the pointer is on it.
private struct MoreMenu: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var profiles = ProfileStore.shared
    @Environment(\.notchTheme) private var theme

    var body: some View {
        MenuButton(help: "More") { hovering in
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(hovering ? theme.primary : theme.secondary)
                .frame(width: NotchTheme.headerControlHeight, height: NotchTheme.headerControlHeight)
                .background {
                    if hovering { theme.controlShape.fill(theme.hover) }
                }
                .animation(.notchHighlight, value: hovering)
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

/// Widgets: the stack picked in Settings.
struct HomeTabView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        NookStack(widgets: settings.homeWidgets, turns: viewModel.stackTurns)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
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
        case .clock: WorldClockWidget()
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
                .fixedSize()
                FocusStrip()
                if settings.focusShowsNotes {
                    NotesActions(editor: editor)
                        .fixedSize()
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
