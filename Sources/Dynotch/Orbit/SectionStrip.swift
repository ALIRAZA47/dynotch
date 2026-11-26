import SwiftUI

/// What a section button shows under its icon: a live figure, like 2:41 for the track or 82% for
/// the battery, and whether the section waits on you.
@MainActor
enum SectionFigure {
    static func figure(for tab: NotchTab, at now: Date) -> String? {
        switch tab {
        case .live:
            let count = LiveFeed.items(at: now, viewModel: nil, theme: .standard).count
            return count > 0 ? "\(count)" : nil
        case .music:
            let media = NowPlayingService.shared
            return media.track == nil ? nil : Format.duration(media.elapsed(at: now))
        case .tray:
            let count = TrayStore.shared.items.count
            return count > 0 ? "\(count)" : nil
        case .clipboard:
            let count = ClipboardStore.shared.clips.count
            return count > 0 ? "\(count)" : nil
        case .focus:
            let pomodoro = PomodoroTimer.shared
            if pomodoro.isRunning || pomodoro.progress > 0 { return Format.duration(pomodoro.remaining) }
            if let countdown = TimerStore.shared.countdowns.first { return Format.duration(countdown.remaining(at: now)) }
            return nil
        case .notes:
            let count = NotesStore.shared.notes.count
            return count > 0 ? "\(count)" : nil
        case .calendar:
            let next = CalendarService.shared.events.first { !$0.isAllDay && $0.end > now }
            return next?.start.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
        case .stats:
            let power = PowerMonitor.shared
            return power.hasBattery ? "\(power.level)%" : nil
        case .agents:
            let deck = AgentDeck.shared
            return deck.sessions.isEmpty ? nil : "\(deck.sessions.count)"
        case .home:
            guard let conditions = WeatherService.shared.conditions else { return nil }
            return WeatherService.format(conditions.temperature, units: AppSettings.shared.weatherUnits)
        }
    }

    static func needsYou(_ tab: NotchTab) -> Bool {
        switch tab {
        case .agents, .live: AppSettings.shared.liveAgents && !AgentDeck.shared.approvals.isEmpty
        default: false
        }
    }
}

/// The section buttons, wherever Settings › Appearance › Section buttons puts them. The shell lays
/// this over the panel, outside its clip, at the panel's size.
struct SectionStrip: View {
    @ObservedObject var viewModel: NotchViewModel
    /// The panel's size, flares left out.
    let panel: CGSize
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var deck = AgentDeck.shared
    @Environment(\.notchTheme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var isOut = false

    /// How far the strip under the panel reaches below it.
    static let underHeight: CGFloat = 58
    /// How wide a column beside the panel is.
    static let sideWidth: CGFloat = 60
    /// How far the arc's discs reach past the panel's sides and below it, at most.
    static let arcOverhang: CGFloat = 110
    static let arcDepth: CGFloat = 150
    /// Where the side columns start, below the band.
    static let sideTop: CGFloat = 40

    var body: some View {
        let tabs = settings.enabledTabs
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = isSnapshot ? SnapshotClock.now : context.date
            let buttons = tabs.map { tab in
                SectionButton(tab: tab, figure: SectionFigure.figure(for: tab, at: now),
                              needsYou: SectionFigure.needsYou(tab), isSelected: viewModel.visibleTab == tab,
                              style: settings.sectionPlacement == .band ? .band : settings.sectionPlacement == .arc ? .disc : .tile) {
                    withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .notchTab) {
                        viewModel.endCommand()
                        viewModel.tab = tab
                    }
                }
            }
            placed(buttons)
        }
        .opacity(isOut || isSnapshot ? 1 : 0)
        .offset(y: isOut || isSnapshot || reduceMotion ? 0 : -10)
        .onAppear { withAnimation(.notchStrip) { isOut = true } }
        .onDisappear { isOut = false }
    }

    @ViewBuilder
    private func placed(_ buttons: [SectionButton]) -> some View {
        switch settings.sectionPlacement {
        case .under:
            HStack(spacing: 3) { ForEach(buttons) { $0 } }
                .padding(EdgeInsets(top: 4, leading: 6, bottom: 6, trailing: 6))
                .background(StripShape(fillet: 12, corner: 14, edge: .under).fill(theme.background))
                .overlay(StripShape(fillet: 12, corner: 14, edge: .under, open: true).stroke(theme.line))
                .frame(maxWidth: .infinity)
                .offset(y: panel.height - 1)
                .frame(maxHeight: .infinity, alignment: .top)
        case .sides:
            let half = (buttons.count + 1) / 2
            HStack(alignment: .top, spacing: 0) {
                column(Array(buttons.prefix(half)), edge: .leading)
                Spacer(minLength: 0)
                column(Array(buttons.dropFirst(half)), edge: .trailing)
            }
            .frame(width: panel.width + Self.sideWidth * 2)
            .offset(y: Self.sideTop)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .left, .right:
            let edge: HorizontalEdge = settings.sectionPlacement == .left ? .leading : .trailing
            HStack(alignment: .top, spacing: 0) {
                if edge == .trailing { Spacer(minLength: 0) }
                column(buttons, edge: edge)
                if edge == .leading { Spacer(minLength: 0) }
            }
            .frame(width: panel.width + Self.sideWidth * 2)
            .offset(y: Self.sideTop)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .band:
            // Beside the camera, half each side, in place of the title and the actions.
            let half = (buttons.count + 1) / 2
            let camera = viewModel.geometry.closedSize.width
            HStack(spacing: 0) {
                HStack(spacing: 2) { ForEach(Array(buttons.prefix(half))) { $0 } }
                    .frame(width: (panel.width - camera) / 2 - 10, alignment: .trailing)
                Color.clear.frame(width: camera + 20)
                HStack(spacing: 2) { ForEach(Array(buttons.dropFirst(half))) { $0 } }
                    .frame(width: (panel.width - camera) / 2 - 10, alignment: .leading)
            }
            .frame(height: max(viewModel.geometry.closedSize.height, 32))
            .padding(.top, 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .arc:
            arc(buttons)
        case .hidden:
            EmptyView()
        }
    }

    private func column(_ buttons: [SectionButton], edge: HorizontalEdge) -> some View {
        VStack(spacing: 3) { ForEach(buttons) { $0 } }
            .padding(.vertical, 6)
            .padding(.horizontal, 5)
            .background(UnevenRoundedRectangle(cornerRadii: edge == .leading
                                                ? .init(topLeading: 14, bottomLeading: 14)
                                                : .init(bottomTrailing: 14, topTrailing: 14), style: .continuous)
                .fill(theme.background))
            .frame(width: Self.sideWidth)
    }

    /// Discs along a curve under the panel, highest at the ends.
    private func arc(_ buttons: [SectionButton]) -> some View {
        let reach = panel.width / 2 + Self.arcOverhang - 40
        let count = buttons.count
        return ZStack(alignment: .top) {
            ForEach(Array(buttons.enumerated()), id: \.element.id) { index, button in
                let t = count > 1 ? Double(index) / Double(count - 1) * 2 - 1 : 0
                let x = reach * t
                let y = 122 - 82 * t * t
                button.offset(x: x, y: panel.height - 25 + y)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The strip under the panel: square along its top, where it meets the panel, round at its foot,
/// with a concave fillet at each top corner so it flows out of the panel.
private struct StripShape: Shape {
    enum Edge { case under }
    let fillet: CGFloat
    let corner: CGFloat
    let edge: Edge
    /// Only the outline below the panel, for the hairline.
    var open = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let f = fillet
        let r = min(corner, rect.height / 2)
        path.move(to: CGPoint(x: rect.minX - f, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + f), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.maxY), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - r), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + f))
        path.addQuadCurve(to: CGPoint(x: rect.maxX + f, y: rect.minY), control: CGPoint(x: rect.maxX, y: rect.minY))
        if !open { path.closeSubpath() }
        return path
    }
}

/// One section button: its icon with its live figure under it, the accent while it's the one showing.
struct SectionButton: View, Identifiable {
    enum Style {
        /// 48 by 47, icon over figure: under the panel and down its sides.
        case tile
        /// Small, icon beside figure, in the band beside the camera.
        case band
        /// A round disc with a shadow, on the arc.
        case disc
    }

    let tab: NotchTab
    let figure: String?
    let needsYou: Bool
    let isSelected: Bool
    let style: Style
    let action: () -> Void
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var id: NotchTab { tab }

    var body: some View {
        Button(action: action) {
            label
                .foregroundStyle(isSelected ? theme.onAccent : hovering ? theme.primary : theme.secondary)
                .background(background)
                .overlay(alignment: .topTrailing) {
                    if needsYou {
                        Circle().fill(isSelected ? theme.onAccent : theme.accent)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().stroke(isSelected ? .clear : theme.background, lineWidth: 2))
                            .offset(x: style == .disc ? -4 : -3, y: style == .disc ? 4 : 3)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.92))
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .help(tab.title)
        .accessibilityLabel(figure.map { "\(tab.title), \($0)" } ?? tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var label: some View {
        switch style {
        case .tile, .disc:
            // The figure's line is kept even when there's no figure, so every icon sits at the same height.
            VStack(spacing: 2) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 22, height: 20)
                Text(figure ?? " ").font(NotchFont.time(10, .semibold)).lineLimit(1).fixedSize()
                    .opacity(figure == nil ? 0 : 1)
            }
            .frame(width: style == .disc ? 50 : 48, height: style == .disc ? 50 : 47)
        case .band:
            HStack(spacing: 3) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 11.5, weight: .medium))
                if let figure {
                    Text(figure).font(NotchFont.time(9.5, .semibold)).lineLimit(1).fixedSize()
                }
            }
            .padding(.horizontal, 6)
            .frame(minWidth: 30)
            .frame(height: 26)
        }
    }

    @ViewBuilder
    private var background: some View {
        switch style {
        case .tile, .band:
            theme.controlShape.fill(isSelected ? theme.accent : hovering ? theme.hover : .clear)
        case .disc:
            Circle().fill(isSelected ? theme.accent : theme.raised)
                .overlay(Circle().strokeBorder(theme.line))
                .shadow(color: .black.opacity(theme.isDark ? 0.35 : 0.18), radius: 11, y: 8)
        }
    }
}
