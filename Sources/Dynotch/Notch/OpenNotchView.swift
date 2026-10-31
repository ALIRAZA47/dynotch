import SwiftUI

/// The expanded notch: a header row beside the camera, then the selected tab, or the command field.
struct OpenNotchView: View {
    @ObservedObject var viewModel: NotchViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let band = viewModel.geometry.closedSize.height
        VStack(spacing: 0) {
            OpenHeaderView(viewModel: viewModel)
                // Beside a menu bar shorter than the controls, on a display without a notch, the
                // header hangs from the top edge at their height, and the content stays clear of it.
                .frame(height: max(band, NotchTheme.headerControlHeight))
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

/// The tabs on the left of the camera; the command field and the ··· menu on the right. Every
/// control in it is 28 points tall, centered in the band beside the camera.
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
                CommandPill(viewModel: viewModel)
                MoreMenu(viewModel: viewModel)
            }
            .frame(width: side, alignment: .trailing)
        }
    }
}

/// The tabs in a track pressed into the slab. The selected one is a jewel of the accent with its
/// name in ink, the one tab whose light spills onto the glass around it; in the command field it
/// goes back to plain glass, so none is picked out.
private struct TabSwitcher: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 2) {
            ForEach(settings.enabledTabs) { tab in
                TabButton(tab: tab, isSelected: viewModel.visibleTab == tab, isMuted: viewModel.isCommandMode,
                          namespace: selection) {
                    // The jewel slides to the tab; with Reduce Motion it eases there without the spring.
                    withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .notchTab) {
                        viewModel.endCommand()
                        viewModel.tab = tab
                    }
                }
            }
        }
        .padding(2)
        .glass(.well, in: Capsule())
    }
}

/// A tab: its symbol, and its name too while it's selected.
private struct TabButton: View {
    let tab: NotchTab
    let isSelected: Bool
    /// The command field covers the tabs, so the selected one goes back to plain glass.
    let isMuted: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        let depth: GlassDepth = isMuted ? .control : .lens(theme.accent)
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
            // Ink on the jewel, white on glass.
            .foregroundStyle(isSelected ? theme.ink(on: depth) : hovering ? theme.primary : theme.primary.opacity(0.55))
            .padding(.horizontal, isSelected ? 10 : 8)
            .frame(minWidth: 30)
            .frame(height: 24)
            .background {
                if isSelected {
                    // Lit under the pointer only in the command field, where clicking it goes back to the tab.
                    GlassSurface(depth: depth, shape: Capsule(), isLit: isMuted && hovering, spills: !isMuted)
                        .matchedGeometryEffect(id: "selection", in: namespace)
                } else if hovering {
                    GlassSurface(depth: .control, shape: Capsule())
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

/// Opens the command field, with its shortcut beside it on keycaps. In the field it turns into a
/// jewel of the accent that reads Command and esc, and closes it.
private struct CommandPill: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        let isActive = viewModel.isCommandMode
        // Each key on its own keycap.
        let keys = isActive ? ["esc"] : settings.commandShortcut ? "⌃⌥K".map(String.init) : []
        Button {
            withAnimation(.notchTab) {
                if isActive { viewModel.endCommand() } else { viewModel.beginCommand() }
            }
        } label: {
            // As much as the room beside the ··· menu holds: the title and the keys, then the keys
            // alone, then the magnifier alone.
            ViewThatFits(in: .horizontal) {
                face(isActive: isActive, showsTitle: true, keys: keys)
                face(isActive: isActive, showsTitle: false, keys: keys)
                face(isActive: isActive, showsTitle: false, keys: [])
            }
        }
        .buttonStyle(PressableButtonStyle(scale: 0.95))
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .help(isActive ? "Close the command field" : "Start a timer, add a note or a reminder, switch a profile…")
        .accessibilityLabel(isActive ? "Close the command field" : "Command field")
    }

    /// A capsule of glass, or the accent's jewel while the field is open: the magnifier, maybe the
    /// title, and the keys, each on its own keycap.
    private func face(isActive: Bool, showsTitle: Bool, keys: [String]) -> some View {
        // Set close, so the title and all three keys fit beside the ··· menu at the default width,
        // beside a hardware notch or the default virtual one. The magnifier and the title bring a
        // little room of their own, so the gaps look about 6 points wide.
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .bold))
            if showsTitle {
                Text(isActive ? "Command" : "Type a command")
                    .font(isActive ? NotchFont.bodyStrong : NotchFont.body)
                    .lineLimit(1)
            }
            if !keys.isEmpty {
                HStack(spacing: 2) {
                    ForEach(keys, id: \.self) { key in
                        Keycap(label: key, style: isActive ? .onLens : .notch)
                    }
                }
                .padding(.leading, 1)
            }
        }
        // Ink on the jewel; on glass it comes forward under the pointer.
        .foregroundStyle(isActive ? theme.onAccent : hovering ? theme.secondary : theme.tertiary)
        .padding(.leading, 10)
        // The keys sit as far in from the end as from the top and bottom.
        .padding(.trailing, keys.isEmpty ? 10 : 5)
        // As tall as the tab track across the camera, so the header reads as one line.
        .frame(height: NotchTheme.headerControlHeight)
        .glass(isActive ? .lens(theme.accent) : .control, in: Capsule(), isLit: hovering)
        .contentShape(Capsule())
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
                    if hovering { GlassSurface(depth: .control, shape: Circle()) }
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

/// The player, and beside it the stack of widgets.
struct HomeTabView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        GeometryReader { proxy in
            let widgets = settings.homeWidgets
            HStack(spacing: NotchTheme.gap) {
                // Two groups, so VoiceOver reads the whole player, then the card, rather than by height.
                MediaPlayerView()
                    .frame(width: widgets.isEmpty ? proxy.size.width : (proxy.size.width * 0.525).rounded())
                    .accessibilityElement(children: .contain)
                if !widgets.isEmpty {
                    NookStack(widgets: widgets, turns: viewModel.stackTurns)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityElement(children: .contain)
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
