import SwiftUI

// MARK: Row actions

/// A button on a row: Allow once, Pause, Join, Copy. Where it shows is Settings › Appearance ›
/// Row actions.
struct RowAction: Identifiable {
    enum Role {
        /// A plain filled button.
        case plain
        /// A focus button in the accent: the one to press.
        case primary
        /// A focus button in red: it can't be taken back, or it lets something through.
        case risk
    }

    var id: String { title }
    let title: String
    var symbol: String?
    var role: Role = .plain
    var isEnabled = true
    /// Drawn as its symbol alone, like a player's controls; the title is what VoiceOver and the tooltip say.
    var isIcon = false
    let perform: () -> Void

    /// A control drawn as its symbol: play, pause, next, cancel.
    static func icon(_ symbol: String, _ title: String, role: Role = .plain, perform: @escaping () -> Void) -> RowAction {
        RowAction(title: title, symbol: symbol, role: role, isIcon: true, perform: perform)
    }

    /// A row's main action is its last: the focus button at the end.
    static func main(of actions: [RowAction]) -> RowAction? {
        actions.last { $0.role != .plain } ?? actions.last
    }
}

/// The row under the pointer, for the placements that show its actions away from it: in a bar over
/// the command field, or in the band beside the camera. It stays the hot row after the pointer
/// leaves, so the pointer can travel to those buttons.
@MainActor
final class RowActionHost: ObservableObject {
    struct Hot {
        let id: String
        let title: String
        let actions: [RowAction]
    }

    @Published private(set) var hot: Hot?

    func setHot(_ hot: Hot) {
        guard self.hot?.id != hot.id || self.hot?.actions.map(\.title) != hot.actions.map(\.title) else { return }
        self.hot = hot
    }

    func clear() {
        if hot != nil { hot = nil }
    }
}

private struct RowActionHostKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: RowActionHost? = nil
}

extension EnvironmentValues {
    /// The shell's host for the hot row's actions. Nil outside the open notch.
    var rowActionHost: RowActionHost? {
        get { self[RowActionHostKey.self] }
        set { self[RowActionHostKey.self] = newValue }
    }
}

/// One of a row's buttons, drawn for its role.
struct RowActionButton: View {
    let action: RowAction
    var height: CGFloat = 26
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action.perform) {
            if action.isIcon {
                // The main control is a solid face of the accent; the others are filled a shade off the panel.
                let isMain = action.role != .plain
                Image(systemName: action.symbol ?? "circle")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(isMain ? theme.onAccent : theme.primary)
                    .frame(width: height + 4, height: height)
                    .background(theme.controlShape.fill(isMain
                        ? (action.role == .risk ? theme.alert : theme.accent).opacity(hovering ? 0.88 : 1)
                        : hovering ? theme.controlHover : theme.hover))
                    .contentShape(theme.controlShape)
            } else {
            switch action.role {
            case .primary:
                FocusButtonLabel(title: action.title, symbol: action.symbol, height: height, hovering: hovering)
            case .risk:
                FocusButtonLabel(title: action.title, symbol: action.symbol, tint: theme.alert, height: height, hovering: hovering)
            case .plain:
                HStack(spacing: 5) {
                    if let symbol = action.symbol {
                        Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                    }
                    Text(action.title).font(NotchFont.bodyStrong).lineLimit(1).fixedSize()
                }
                .foregroundStyle(theme.primary)
                .padding(.horizontal, 12)
                .frame(height: height)
                .background(theme.controlShape.fill(hovering ? theme.controlHover : theme.hover))
                .contentShape(theme.controlShape)
            }
            }
        }
        .buttonStyle(PressableButtonStyle(scale: 0.96))
        .help(action.title)
        .disabled(!action.isEnabled)
        .opacity(action.isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .accessibilityLabel(action.title)
    }
}

/// The actions behind a row's ··· button.
private struct RowMoreButton: View {
    let actions: [RowAction]
    @Environment(\.notchTheme) private var theme

    var body: some View {
        MenuButton(help: "Actions") { hovering in
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(hovering ? theme.primary : theme.secondary)
                .frame(width: 28, height: 26)
                .background(theme.controlShape.fill(hovering ? theme.controlHover : theme.hover))
        } items: {
            actions.map { action in MenuEntry.item(action.title, isEnabled: action.isEnabled, action: action.perform) }
        }
    }
}

// MARK: Row

/// A ranked row: a time or figure in SF Mono, a glyph, two lines, and a status or the row's
/// buttons on the right. Live, Agents, Calendar and the lists are made of these.
struct OrbitRow: View {
    let id: String
    /// The left column: "Now", "2:41", "10:30". Empty leaves the column out.
    var time: String = ""
    /// How wide the time column is: wider for "10:05 PM" or "All day".
    var timeWidth: CGFloat = 52
    /// A thin bar of color after the time, like a calendar's.
    var mark: Color?
    /// An SF Symbol in a small square, or nothing.
    var symbol: String?
    var title: String
    var subtitle: String?
    /// What it's doing: Playing, Running, Waiting. Hidden while the buttons show.
    var status: String?
    /// The status light beside it.
    var statusColor: Color?
    /// It waits on the person: the time and the glyph take the accent.
    var needsYou = false
    var actions: [RowAction] = []
    /// A row drawn as the one under the pointer, for snapshots.
    var forcesHover = false
    var onTap: (() -> Void)?
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.notchTheme) private var theme
    @Environment(\.rowActionHost) private var host
    @Environment(\.isSnapshot) private var isSnapshot
    @ViewState private var hovering = false

    private var isHot: Bool { hovering || forcesHover }

    var body: some View {
        HStack(spacing: 12) {
            if !time.isEmpty {
                Text(time)
                    .font(NotchFont.time(14))
                    .foregroundStyle(needsYou ? theme.accentText : theme.primary)
                    .lineLimit(1)
                    .frame(width: timeWidth, alignment: .leading)
            }
            if let mark {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(mark)
                    .frame(width: 4, height: 28)
                    .accessibilityHidden(true)
            }
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(needsYou ? theme.accentText : theme.secondary)
                    .frame(width: 30, height: 30)
                    .background(theme.controlShape.fill(needsYou ? theme.accentSoft : theme.hover))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(NotchFont.headline)
                    .foregroundStyle(theme.primary)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(NotchFont.subheadline)
                        .foregroundStyle(theme.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 10)
        .frame(height: NotchTheme.rowHeight)
        .background {
            if isHot {
                theme.controlShape.fill(theme.raised)
                    .overlay(theme.controlShape.strokeBorder(theme.line))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .onHover { inside in
            hovering = inside
            if inside { host?.setHot(.init(id: id, title: title, actions: actions)) }
        }
        // What the buttons say can change under a still pointer: Pause becomes Resume.
        .onChange(of: actions.map(\.title)) {
            if hovering { host?.setHot(.init(id: id, title: title, actions: actions)) }
        }
        .animation(.notchHighlight, value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            ForEach(actions) { action in
                Button(action.title, action: action.perform)
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        let mode = settings.rowActionMode
        let shown: [RowAction] = switch mode {
        case .always: actions
        case .hover: isHot ? actions : []
        case .primary: isHot ? actions : RowAction.main(of: actions).map { [$0] } ?? []
        case .bar, .band, .menu: []
        }
        HStack(spacing: 6) {
            if shown.isEmpty || mode == .primary && !isHot {
                statusView
            }
            ForEach(shown) { action in
                RowActionButton(action: action)
            }
            if mode == .menu, !actions.isEmpty {
                RowMoreButton(actions: actions)
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var statusView: some View {
        if let status {
            HStack(spacing: 6) {
                if let statusColor {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                }
                Text(status)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// A hairline between rows that aren't under the pointer.
struct OrbitRowDivider: View {
    @Environment(\.notchTheme) private var theme

    var body: some View {
        theme.line.frame(height: 1).padding(.horizontal, 10)
    }
}

/// The hot row's actions, for the Action bar placement: over the command field.
struct RowActionBar: View {
    @ObservedObject var host: RowActionHost
    @Environment(\.notchTheme) private var theme

    static let height: CGFloat = 38

    var body: some View {
        HStack(spacing: 8) {
            if let hot = host.hot, !hot.actions.isEmpty {
                Text(hot.title)
                    .font(NotchFont.bodyStrong)
                    .foregroundStyle(theme.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(hot.actions) { action in
                    RowActionButton(action: action)
                }
            } else {
                Text("Point at a row for its actions")
                    .font(NotchFont.footnote)
                    .foregroundStyle(theme.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .background(theme.controlShape.fill(theme.raised).overlay(theme.controlShape.strokeBorder(theme.line)))
    }
}

// MARK: Band header

/// What a section puts in the band beside the camera: its title and a second line on the left of
/// the housing, its buttons on the right.
struct OrbitHeader {
    var title: String
    var subtitle: String?
    var actions: AnyView?
}

struct OrbitHeaderKey: PreferenceKey {
    static let defaultValue: OrbitHeader? = nil
    static func reduce(value: inout OrbitHeader?, nextValue: () -> OrbitHeader?) {
        value = nextValue() ?? value
    }
}

extension View {
    /// Sets the band's title, its second line and the buttons right of the camera for this section.
    func orbitHeader<Actions: View>(_ title: String, subtitle: String? = nil,
                                    @ViewBuilder actions: () -> Actions = { EmptyView() }) -> some View {
        let actions = actions()
        return preference(key: OrbitHeaderKey.self,
                          value: OrbitHeader(title: title, subtitle: subtitle,
                                             actions: Actions.self == EmptyView.self ? nil : AnyView(actions)))
    }
}
