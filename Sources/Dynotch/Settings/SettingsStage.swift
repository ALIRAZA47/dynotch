import SwiftUI

/// The header of every page: a strip of desk with a menu bar, and a model notch hanging from its top
/// edge that acts out the page's settings as they change, then the page's title. The open notch is
/// drawn the way Orbit draws it, in the theme the notch would have now.
struct SettingsStage: View {
    @ObservedObject var navigation: SettingsNavigation

    static let height: CGFloat = 206
    /// The desk the model hangs over.
    static let deskHeight: CGFloat = 136

    var body: some View {
        let page = navigation.page
        VStack(alignment: .leading, spacing: 0) {
            StageDesk {
                StagePreview(navigation: navigation)
            }
            .frame(height: Self.deskHeight)
            // Decoration, read out by nothing.
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            .padding(.top, 14)
            Spacer(minLength: 0)
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(page.title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(.isHeader)
                    Text(page.subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.secondaryText)
                }
                .id(page)
                .transition(.opacity)
                Spacer(minLength: 0)
                StageAction(page: page)
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 2)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
    }
}

/// The stage's text, on the desk. The desk's grey is darker than the page in light mode, so the
/// second level is a step firmer there than the page's to keep 4.5:1.
struct StageInk {
    let colorScheme: ColorScheme
    var contrast = ColorSchemeContrast.standard

    var primary: Color { colorScheme == .dark ? NotchTheme.hex(0xF5F5F7) : NotchTheme.hex(0x1D1D1F) }
    var secondary: Color {
        colorScheme == .dark ? NotchTheme.hex(contrast == .increased ? 0xD1D1D6 : 0xB4B4BA)
            : NotchTheme.hex(contrast == .increased ? 0x2C2C2E : 0x45454A)
    }
    /// A method that's off. It's news, not a disabled control, so it reads at the second level;
    /// its chip has no fill.
    var off: Color { secondary }
}

/// A strip of desktop in a rounded frame with a hairline, a menu bar along its top, and what's
/// given hanging from the middle of that.
struct StageDesk<Content: View>: View {
    var menuBarHeight: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        ZStack(alignment: .top) {
            Palette.wall
            Palette.menuBar.frame(height: menuBarHeight)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Palette.stroke))
    }
}

/// A button that tries the page out in the real notch.
private struct StageAction: View {
    let page: SettingsPage
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        switch page {
        case .general, .appearance:
            button("Open the Notch") { NotchManager.shared.open(tab: .live) }
        case .nook:
            button("Open the Notch") { NotchManager.shared.open(tab: .live) }
        case .tray where settings.showTrayTab:
            button("Open the Tray") { NotchManager.shared.open(tab: .tray) }
        case .focus where settings.showFocusTab:
            button("Open Focus") { NotchManager.shared.open(tab: .focus) }
        case .permissions:
            button("Privacy & Security", symbol: "gear") { CalendarService.openPrivacySettings("Privacy") }
        default:
            EmptyView()
        }
    }

    private func button(_ title: String, symbol: String = "arrow.up.forward", action: @escaping () -> Void) -> some View {
        CapsuleButton(title: title, symbol: symbol, action: action)
            .transition(.opacity)
    }
}

/// The model notch and a line about it. Closed or open, moving between pages opens and closes it
/// like the real one.
private struct StagePreview: View {
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var permissions = PermissionStatus.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    /// The closed notch is drawn larger than life and the open one smaller, so both fit.
    private static let closedScale: CGFloat = 1.4
    static let openScale: CGFloat = 0.32
    private static let hardwareNotch = CGSize(width: 185, height: 32)
    private static let cycle: TimeInterval = 2.6
    /// How it moves with Reduce Motion: no spring.
    private static let eased = Animation.easeOut(duration: 0.2)

    /// The look as the real notch draws it, following the window for Follow macOS.
    private var theme: NotchTheme {
        var theme = settings.theme(systemIsDark: colorScheme == .dark)
        theme.isHighContrast = contrast == .increased
        return theme
    }

    var body: some View {
        let page = navigation.page
        // Only the Live Activities page cycles through samples.
        TimelineView(.periodic(from: .now, by: page == .activities && !reduceMotion ? Self.cycle : 3600)) { context in
            let featured = featuredActivity(tick: Int(context.date.timeIntervalSinceReferenceDate / Self.cycle))
            ZStack(alignment: .top) {
                notch(featured: featured)
                caption(featured: featured)
                    .id(page)
                    .transition(.opacity)
                    .padding(.leading, 14)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isOpen ? .bottomLeading : .bottom)
            }
            .animation(reduceMotion ? Self.eased : .notchActivity, value: featured)
        }
        .animation(reduceMotion ? Self.eased : .notchOpen, value: page)
        .animation(reduceMotion ? Self.eased : .snappy(duration: 0.25), value: theme)
        .environment(\.notchTheme, theme)
    }

    // MARK: Notch

    @ViewBuilder
    private func notch(featured: LiveActivityKind?) -> some View {
        let page = navigation.page
        if isOpen {
            OrbitModel(tab: page == .tray ? .tray : .live, maxScale: Self.openScale, maxHeight: SettingsStage.deskHeight - 6)
        } else {
            let activity = closedActivity(featured: featured)
            let secondary = page == .activities ? featured?.sampleSecondary : nil
            let layout = ClosedLayout(activity: activity, secondary: secondary, notch: Self.hardwareNotch)
            let hovering = page == .general
            let scale = Self.closedScale
            PreviewNotch(size: CGSize(width: (layout.totalWidth + (hovering ? 14 : 0)) * scale,
                                      height: (layout.totalHeight + (hovering ? 3 : 0)) * scale),
                         topRadius: 6 * scale,
                         bottomRadius: (layout.rowHeight > 0 ? 16 : hovering ? 12 : 10) * scale) {
                ClosedPreview(activity: activity, secondary: secondary, layout: layout, scale: scale,
                              timerText: "\(settings.focusMinutes):00", tintArtwork: settings.artworkTint)
            }
        }
    }

    private var isOpen: Bool {
        [.appearance, .nook, .tray].contains(navigation.page)
    }

    private func closedActivity(featured: LiveActivityKind?) -> ClosedActivity {
        switch navigation.page {
        case .activities:
            return featured?.sample ?? .idle
        case .focus:
            return .timer
        case .permissions:
            let allGranted = permissions.grantedCount == permissions.totalCount
            return .notice(LiveNotice(key: "permissions", symbol: allGranted ? "checkmark.shield.fill" : "lock.shield.fill",
                                      tint: allGranted ? .green : .orange,
                                      text: "\(permissions.grantedCount)/\(permissions.totalCount)"))
        case .about:
            return .music
        default:
            return .idle
        }
    }

    /// The activity on show: the one under the pointer, or each one that's on, in turn.
    private func featuredActivity(tick: Int) -> LiveActivityKind? {
        guard navigation.page == .activities else { return nil }
        if let spotlight = navigation.spotlight { return spotlight }
        let shown = LiveActivityKind.allCases.filter { $0.isShown(with: settings) }
        guard !shown.isEmpty else { return nil }
        return shown[tick % shown.count]
    }

    // MARK: Caption

    @ViewBuilder
    private func caption(featured: LiveActivityKind?) -> some View {
        switch navigation.page {
        case .general:
            HStack(spacing: 6) {
                MethodChip(symbol: "cursorarrow", text: settings.openOnHover
                    ? String(format: "Hover %.2fs", settings.hoverDelay) : "Hover", isOn: settings.openOnHover)
                MethodChip(symbol: "hand.draw", text: "Swipe", isOn: settings.swipeGestures)
                MethodChip(symbol: "keyboard", text: "⌃⌥N", isOn: settings.globalShortcut)
            }
        case .appearance:
            CaptionText("\(Int(settings.openWidth)) × \(Int(settings.openHeight)) pt\n\(theme.isDark ? "Dark" : "Light") · \(settings.notchAccent.title)")
        case .nook:
            CaptionText("\(settings.enabledTabs.count) sections\n\(settings.sectionPlacement.title)", isNumeric: false)
        case .activities:
            ActivityDots(featured: featured)
        case .focus:
            FocusRound()
        case .permissions:
            CaptionText("\(permissions.grantedCount) of \(permissions.totalCount) allowed")
        default:
            EmptyView()
        }
    }
}

/// The closed notch at preview size, hanging from the top edge: black, with white on black as the
/// real one has, whatever the window around it.
private struct PreviewNotch<Content: View>: View {
    let size: CGSize
    let topRadius: CGFloat
    let bottomRadius: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: size.width, height: size.height, alignment: .top)
            .padding(.horizontal, topRadius)
            .background(Color.black)
            .clipShape(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius))
            .environment(\.colorScheme, .dark)
    }
}

/// A line on the desk, in the stage's second color.
struct CaptionText: View {
    let text: String
    /// Numbers roll as they change; a line that's a sentence cross-fades instead.
    let isNumeric: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    init(_ text: String, isNumeric: Bool = true) {
        self.text = text
        self.isNumeric = isNumeric
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
            .foregroundStyle(StageInk(colorScheme: colorScheme, contrast: contrast).secondary)
            .contentTransition(isNumeric ? .numericText() : .opacity)
    }
}

// MARK: Closed notch

/// The closed notch with a live activity in its ears, like `ClosedNotchView` but with sample content.
private struct ClosedPreview: View {
    let activity: ClosedActivity
    var secondary: CompactActivity?
    let layout: ClosedLayout
    let scale: CGFloat
    let timerText: String
    let tintArtwork: Bool
    @Environment(\.notchTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leading
                    .padding(.leading, 10 * scale)
                    .frame(width: layout.earWidth * scale, height: layout.notchHeight * scale, alignment: .leading)
                Color.clear.frame(width: layout.notchWidth * scale)
                HStack(spacing: ClosedLayout.glyphSpacing * scale) {
                    trailing
                    if let secondary {
                        glyph(secondary)
                            .frame(width: ClosedLayout.glyphSize * scale, height: ClosedLayout.glyphSize * scale)
                    }
                }
                .padding(.trailing, 11 * scale)
                .frame(width: layout.earWidth * scale, height: layout.notchHeight * scale, alignment: .trailing)
            }
            if layout.rowHeight > 0 {
                detail
                    .font(.system(size: 12 * scale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    // As in `ClosedNotchView`: the peek's semibold title gets 2 points more each side.
                    .padding(.horizontal, (activity == .trackPeek ? 14 : 16) * scale)
                    .frame(height: layout.rowHeight * scale, alignment: .top)
            }
            if layout.footHeight > 0, case .script(let activity) = activity {
                ScriptFootLine(activity: activity, height: ClosedLayout.footLineHeight * scale)
                    .padding(.horizontal, ClosedLayout.footInset * scale)
                    .frame(height: layout.footHeight * scale, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
    }

    @ViewBuilder
    private var leading: some View {
        switch activity {
        case .idle:
            EmptyView()
        case .music, .trackPeek, .lyrics:
            RoundedRectangle(cornerRadius: 6 * scale, style: .continuous)
                .fill(Palette.sunset)
                .frame(width: (layout.notchHeight - 12) * scale, height: (layout.notchHeight - 12) * scale)
        case .timer:
            ProgressRing(progress: 0.3, color: PomodoroTimer.Phase.focus.color, lineWidth: 2.6 * scale)
                .frame(width: 17 * scale, height: 17 * scale)
        case .notice(let notice):
            Image(systemName: notice.symbol)
                .font(.system(size: 13 * scale, weight: .semibold))
                .foregroundStyle(notice.tint)
        case .countdown(let countdown):
            HStack(spacing: 6 * scale) {
                ProgressRing(progress: countdown.progress(at: .now), color: TimerStore.tint, lineWidth: 2.6 * scale)
                    .frame(width: 17 * scale, height: 17 * scale)
                Text(countdown.name)
                    .font(.system(size: 12 * scale, weight: .semibold))
                    .foregroundStyle(theme.primary)
                    .lineLimit(1)
            }
        case .stopwatch:
            Image(systemName: "stopwatch.fill")
                .font(.system(size: 13 * scale, weight: .semibold))
                .foregroundStyle(TimerStore.stopwatchTint)
        case .download:
            DownloadRing(fraction: 0.45, lineWidth: 2.6 * scale, arrowSize: 7 * scale)
                .frame(width: 17 * scale, height: 17 * scale)
        case .recording:
            RecordingDot(size: 11 * scale)
        case .script(let activity):
            HStack(spacing: 6 * scale) {
                Image(systemName: activity.symbol)
                    .font(.system(size: 12 * scale, weight: .semibold))
                    .foregroundStyle(activity.tint ?? theme.accent)
                Text(activity.key)
                    .font(.system(size: 12 * scale, weight: .semibold))
                    .foregroundStyle(theme.primary)
                    .lineLimit(1)
            }
        case .ci(let run):
            CILabel(run: run)
                .scaleEffect(scale, anchor: .leading)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch activity {
        case .idle:
            EmptyView()
        case .music, .trackPeek, .lyrics:
            AudioBars(isPlaying: true, color: tintArtwork ? Color(red: 1, green: 0.45, blue: 0.55) : theme.accent)
                .frame(width: 20 * scale, height: 14 * scale)
        case .timer:
            Text(timerText)
                .font(NotchFont.numeric(12.5 * scale))
                .foregroundStyle(PomodoroTimer.Phase.focus.color)
        case .notice(let notice):
            switch notice.kind {
            case .meter(let level):
                LevelBar(level: level)
                    .frame(width: 62 * scale, height: 5 * scale)
            case .info:
                Text(notice.text)
                    .font(NotchFont.numeric(12.5 * scale))
                    .foregroundStyle(notice.tint)
                    .lineLimit(1)
            }
        case .countdown(let countdown):
            Text(Format.duration(countdown.remaining(at: .now).rounded(.up)))
                .font(NotchFont.numeric(12.5 * scale))
                .foregroundStyle(TimerStore.tint)
        case .stopwatch:
            Text("12:34")
                .font(NotchFont.numeric(12.5 * scale))
                .foregroundStyle(TimerStore.stopwatchTint)
        case .download:
            Text("45%")
                .font(NotchFont.numeric(12.5 * scale))
                .foregroundStyle(DownloadMonitor.tint)
        case .recording:
            Text("12:34")
                .font(NotchFont.numeric(12.5 * scale))
                .foregroundStyle(.white)
        case .script(let activity):
            Text(activity.percentText ?? "")
                .font(NotchFont.numeric(12.5 * scale))
                .foregroundStyle(activity.tint ?? theme.accent)
        case .ci(let run):
            CIStatus(run: run)
                .scaleEffect(scale, anchor: .trailing)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch activity {
        case .trackPeek:
            TrackPeekLine(title: "Midnight City", artist: "M83", scale: scale)
        case .notice(let notice):
            if let detail = notice.detail { Text(detail) }
        default:
            EmptyView()
        }
    }

    /// A second activity's glyph, like `CompactActivityView` but with sample content.
    @ViewBuilder
    private func glyph(_ activity: CompactActivity) -> some View {
        switch activity {
        case .timer:
            ProgressRing(progress: 0.3, color: PomodoroTimer.Phase.focus.color, lineWidth: 2.4 * scale)
                .padding(1.5 * scale)
        case .music:
            RoundedRectangle(cornerRadius: 4 * scale, style: .continuous)
                .fill(Palette.sunset)
        case .micMuted:
            MuteBadge(size: ClosedLayout.glyphSize * scale)
        case .countdown(let countdown):
            ProgressRing(progress: countdown.progress(at: .now), color: TimerStore.tint, lineWidth: 2.4 * scale)
                .padding(1.5 * scale)
        case .stopwatch:
            ProgressRing(progress: 0.55, color: TimerStore.stopwatchTint, lineWidth: 2.4 * scale)
                .padding(1.5 * scale)
        case .download:
            DownloadRing(fraction: 0.45, lineWidth: 2.4 * scale, arrowSize: 6 * scale)
                .padding(1.5 * scale)
        case .recording:
            RecordingDot(size: 10 * scale)
        case .focus(let mode):
            FocusGlyph(mode: mode, size: ClosedLayout.glyphSize * scale)
        case .held(let count):
            HeldBadge(count: count, size: ClosedLayout.glyphSize * scale)
        case .keepAwake:
            KeepAwakeGlyph(size: ClosedLayout.glyphSize * scale)
        case .script(let activity):
            ProgressRing(progress: activity.fraction ?? 0, color: activity.tint ?? theme.accent, lineWidth: 2.4 * scale)
                .padding(1.5 * scale)
        case .agentsWaiting(let count):
            AgentsWaitingBadge(count: count, size: ClosedLayout.glyphSize * scale)
        case .ci(let run):
            CIGlyph(run: run)
                .scaleEffect(scale)
        }
    }
}


/// How the notch opens, as an info chip on the desk: filled while that way is on, an outline while
/// it's off.
private struct MethodChip: View {
    let symbol: String
    let text: String
    let isOn: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let ink = StageInk(colorScheme: colorScheme, contrast: contrast)
        let shape = RoundedRectangle(cornerRadius: max(theme.radius, 2), style: .continuous)
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            Text(text).font(.system(size: 12, weight: .medium)).monospacedDigit()
        }
        .foregroundStyle(isOn ? ink.primary : ink.off)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background {
            if isOn {
                shape.fill(Palette.sidebar).overlay(shape.strokeBorder(Palette.stroke))
            } else {
                shape.strokeBorder(ink.off.opacity(0.5))
            }
        }
    }
}

/// A dot per live activity: solid for the one on show, faint for those turned off.
private struct ActivityDots: View {
    let featured: LiveActivityKind?
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 6) {
            CaptionText(featured.map { $0.isShown(with: settings) ? $0.title : "\($0.title) · Off" }
                        ?? "Nothing shows in the closed notch", isNumeric: false)
            HStack(spacing: 5) {
                ForEach(LiveActivityKind.allCases) { kind in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.primary.opacity(kind == featured ? 0.95 : kind.isShown(with: settings) ? 0.4 : 0.12))
                        .frame(width: kind == featured ? 14 : 5, height: 5)
                }
            }
        }
    }
}

/// One round of the focus timer, to scale: focus sessions, short breaks and the long break.
private struct FocusRound: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var colorScheme

    private let width: CGFloat = 320
    private let gap: CGFloat = 3

    var body: some View {
        let sessions = settings.sessionsPerRound
        let total = CGFloat(sessions * settings.focusMinutes + (sessions - 1) * settings.shortBreakMinutes
            + settings.longBreakMinutes)
        let room = width - gap * CGFloat(sessions * 2 - 1)
        // On the light desk the phases' pale colors would all but vanish, so they take the window's deeper shades.
        let onLight = colorScheme == .light
        let focus = onLight ? WindowAccent(choice: .red).color : PomodoroTimer.Phase.focus.color
        let rest = onLight ? WindowAccent(choice: .green).color : PomodoroTimer.Phase.shortBreak.color
        VStack(spacing: 6) {
            HStack(spacing: gap) {
                ForEach(0..<sessions, id: \.self) { index in
                    let last = index == sessions - 1
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(focus)
                        .frame(width: max(4, room * CGFloat(settings.focusMinutes) / total))
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(rest.opacity(last ? 1 : onLight ? 0.8 : 0.55))
                        .frame(width: max(3, room * CGFloat(last ? settings.longBreakMinutes : settings.shortBreakMinutes) / total))
                }
            }
            .frame(height: 6)
            CaptionText("\(sessions) × \(settings.focusMinutes) min focus · \(FocusSettings.roundLength(settings)) a round")
        }
    }
}

// MARK: Open notch

/// The open notch as Orbit draws it, in miniature: the panel in the notch's theme hanging from the
/// top edge with the camera housing in its band, a section's rows, the command field at its foot,
/// and the section buttons where Settings › Appearance puts them. It's laid out at full size and
/// scaled down, so its proportions follow the size sliders.
struct OrbitModel: View {
    let tab: NotchTab
    /// The most it's scaled by.
    let maxScale: CGFloat
    /// How tall it may be, section buttons included. A taller panel is drawn smaller to fit.
    var maxHeight: CGFloat = .infinity
    @ObservedObject private var settings = AppSettings.shared

    /// Room round the panel for the section buttons, at full size.
    static let sideRoom: CGFloat = 64
    static let footRoom: CGFloat = 64

    var body: some View {
        let panel = CGSize(width: settings.openWidth, height: settings.openHeight)
        let full = CGSize(width: panel.width + Self.sideRoom * 2, height: panel.height + Self.footRoom)
        let scale = min(maxScale, maxHeight / full.height)
        OrbitModelCanvas(tab: tab, panel: panel)
            .frame(width: full.width, height: full.height, alignment: .top)
            .scaleEffect(scale, anchor: .top)
            .frame(width: full.width * scale, height: full.height * scale, alignment: .top)
    }
}

private struct OrbitModelCanvas: View {
    let tab: NotchTab
    let panel: CGSize
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.notchTheme) private var theme

    private static let housing = CGSize(width: 185, height: 32)
    private static let button = CGSize(width: 48, height: 47)

    var body: some View {
        let shape = NotchShape(topRadius: NotchTheme.panelTopRadius, bottomRadius: NotchTheme.panelBottomRadius)
        let tabs = settings.enabledTabs
        ZStack(alignment: .top) {
            strip(tabs)
            VStack(spacing: 0) {
                band(tabs)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                commandField
            }
            .padding(.horizontal, NotchTheme.inset + NotchTheme.panelTopRadius)
            .padding(.bottom, 14)
            .frame(width: panel.width + NotchTheme.panelTopRadius * 2, height: panel.height)
            .background {
                shape.fill(theme.background)
                    .overlay(shape.stroke(theme.line, lineWidth: 1))
                    .shadow(color: .black.opacity(settings.showOpenShadow ? (theme.isDark ? 0.5 : 0.22) : 0), radius: 22, y: 12)
            }
            .environment(\.colorScheme, theme.colorScheme)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Band

    private func band(_ tabs: [NotchTab]) -> some View {
        HStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(NotchFont.title).foregroundStyle(theme.primary)
                Text(subtitle).font(NotchFont.subheadline).foregroundStyle(theme.secondary)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            Color.black
                .frame(width: Self.housing.width, height: Self.housing.height)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10, style: .continuous))
                .frame(maxHeight: .infinity, alignment: .top)
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                if settings.sectionPlacement == .band {
                    ForEach(tabs.prefix(5)) { item in
                        Image(systemName: item.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(item == tab ? theme.onAccent : theme.secondary)
                            .frame(width: 32, height: 26)
                            .background(theme.controlShape.fill(item == tab ? theme.accent : .clear))
                    }
                }
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(theme.secondary)
                    .frame(width: 26)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: 40)
    }

    private var title: String {
        tab == .tray ? "Tray" : "Live now"
    }

    private var subtitle: String {
        tab == .tray ? "3 items" : "4 things"
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if tab == .tray {
            HStack(spacing: NotchTheme.gap) {
                ForEach([("doc.richtext.fill", "Brief.pdf"), ("photo.fill", "Hero.png"), ("doc.zipper", "Build.zip")],
                        id: \.1) { file in
                    VStack(spacing: 8) {
                        Image(systemName: file.0)
                            .font(.system(size: 30, weight: .regular))
                            .foregroundStyle(theme.secondary)
                        Text(file.1).font(NotchFont.subheadline).foregroundStyle(theme.primary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: 120)
                    .background(theme.cardShape.fill(theme.raised).overlay(theme.cardShape.strokeBorder(theme.line)))
                }
            }
            .padding(.top, 8)
        } else {
            VStack(spacing: 0) {
                row(time: "01:02", symbol: "calendar", title: "Design review", subtitle: "Starts in 13m", needsYou: true)
                OrbitRowDivider()
                row(time: "1:20", symbol: "music.note", title: "Midnight City", subtitle: "M83 · Music", status: "Playing")
                OrbitRowDivider()
                row(time: "3:41", symbol: "hourglass", title: "Tea", subtitle: "Ends at 10:22", status: "Running")
                OrbitRowDivider()
                row(time: "25:00", symbol: "hourglass", title: "Bread dough", subtitle: "Paused")
            }
            .padding(.top, 4)
        }
    }

    /// A ranked row as `OrbitRow` lays one out, drawn here without its buttons or the stores behind it.
    private func row(time: String, symbol: String, title: String, subtitle: String, status: String? = nil,
                     needsYou: Bool = false) -> some View {
        HStack(spacing: 12) {
            Text(time)
                .font(NotchFont.time())
                .foregroundStyle(needsYou ? theme.accentText : theme.primary)
                .frame(width: 52, alignment: .leading)
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(needsYou ? theme.accentText : theme.secondary)
                .frame(width: 30, height: 30)
                .background(theme.controlShape.fill(needsYou ? theme.accentSoft : theme.hover))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(NotchFont.headline).foregroundStyle(theme.primary)
                Text(subtitle).font(NotchFont.subheadline).foregroundStyle(theme.secondary)
            }
            Spacer(minLength: 0)
            if needsYou {
                FocusButtonLabel(title: "Join")
            } else if let status {
                HStack(spacing: 6) {
                    Circle().fill(theme.live).frame(width: 7, height: 7)
                    Text(status).font(NotchFont.subheadline).foregroundStyle(theme.secondary)
                }
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: NotchTheme.rowHeight)
        .background {
            if needsYou {
                theme.controlShape.fill(theme.raised).overlay(theme.controlShape.strokeBorder(theme.line))
            }
        }
    }

    private var commandField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium))
            Text("Type a command").font(NotchFont.body)
            Spacer(minLength: 0)
            Text("⌃⌥K").font(NotchFont.keycap)
        }
        .foregroundStyle(theme.tertiary)
        .padding(.horizontal, 12)
        .frame(height: NotchTheme.commandFieldHeight)
        .background(theme.controlShape.fill(theme.field).overlay(theme.controlShape.strokeBorder(theme.line)))
        .padding(.top, NotchTheme.commandFieldGap)
    }

    // MARK: Section buttons

    @ViewBuilder
    private func strip(_ tabs: [NotchTab]) -> some View {
        let edge = theme.background
        switch settings.sectionPlacement {
        case .under:
            HStack(spacing: 3) { buttons(tabs) }
                .padding(.horizontal, 6)
                .padding(.top, 6)
                .padding(.bottom, 6)
                .background(UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14, style: .continuous).fill(edge))
                .padding(.top, panel.height - 1)
        case .left, .right, .sides:
            let split = settings.sectionPlacement == .sides ? (tabs.count + 1) / 2 : tabs.count
            let left = settings.sectionPlacement == .right ? [] : Array(tabs.prefix(split))
            let right = settings.sectionPlacement == .left ? [] : Array(tabs.suffix(tabs.count - (settings.sectionPlacement == .right ? 0 : split)))
            HStack(alignment: .top, spacing: 0) {
                column(left, edge: .leading)
                Spacer(minLength: 0)
                column(right, edge: .trailing)
            }
            .frame(width: panel.width + NotchTheme.panelTopRadius * 2 + Self.button.width * 2 + 8)
            .padding(.top, 44)
        case .arc:
            let count = tabs.count
            ZStack(alignment: .top) {
                ForEach(Array(tabs.enumerated()), id: \.element) { index, item in
                    let t = count > 1 ? Double(index) / Double(count - 1) : 0.5
                    let angle = Double.pi * (0.12 + 0.76 * t)
                    let radiusX = Double(panel.width) / 2 + 20
                    disc(item)
                        .offset(x: -CGFloat(cos(angle) * radiusX), y: panel.height - 18 + CGFloat(sin(angle) * 50))
                }
            }
        case .band, .hidden:
            EmptyView()
        }
    }

    private func column(_ tabs: [NotchTab], edge: HorizontalEdge) -> some View {
        VStack(spacing: 3) { buttons(tabs) }
            .padding(5)
            .background(UnevenRoundedRectangle(topLeadingRadius: edge == .leading ? 12 : 0,
                                               bottomLeadingRadius: edge == .leading ? 12 : 0,
                                               bottomTrailingRadius: edge == .trailing ? 12 : 0,
                                               topTrailingRadius: edge == .trailing ? 12 : 0, style: .continuous)
                .fill(theme.background))
            .opacity(tabs.isEmpty ? 0 : 1)
    }

    private func buttons(_ tabs: [NotchTab]) -> some View {
        ForEach(tabs) { item in
            let selected = item == tab
            Image(systemName: item.symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(selected ? theme.onAccent : theme.secondary)
                .frame(width: Self.button.width, height: Self.button.height)
                .background(theme.controlShape.fill(selected ? theme.accent : .clear))
        }
    }

    private func disc(_ item: NotchTab) -> some View {
        let selected = item == tab
        return Image(systemName: item.symbol)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(selected ? theme.onAccent : theme.secondary)
            .frame(width: 50, height: 50)
            .background(Circle().fill(selected ? theme.accent : theme.raised))
            .overlay(Circle().strokeBorder(theme.line))
    }
}

// MARK: Model notch elsewhere

/// The header's desk, for windows other than Settings.
struct StageSky: View {
    var body: some View {
        StageDesk { EmptyView() }
    }
}

/// The header's model notch on its own, for the welcome tour: closed with a live activity, under
/// the pointer, or open on a section.
struct ModelNotch: View {
    enum Pose: Equatable {
        case closed(ClosedActivity, secondary: CompactActivity? = nil)
        case hovering
        case open(NotchTab)
    }

    let pose: Pose
    var openScale: CGFloat = 0.32
    /// How tall the open model may be, its section buttons included.
    var openHeight: CGFloat = SettingsStage.deskHeight - 6
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    // As in StagePreview: the closed notch larger than life.
    private static let closedScale: CGFloat = 1.4
    private static let hardwareNotch = CGSize(width: 185, height: 32)

    /// The look as the real notch draws it, following the window for Follow macOS.
    private var theme: NotchTheme {
        var theme = settings.theme(systemIsDark: colorScheme == .dark)
        theme.isHighContrast = contrast == .increased
        return theme
    }

    var body: some View {
        notch
            .environment(\.notchTheme, theme)
    }

    @ViewBuilder
    private var notch: some View {
        switch pose {
        case .open(let tab):
            OrbitModel(tab: tab, maxScale: openScale, maxHeight: openHeight)
        case .closed, .hovering:
            let (activity, secondary): (ClosedActivity, CompactActivity?) = if case .closed(let activity, let secondary) = pose {
                (activity, secondary)
            } else {
                (.idle, nil)
            }
            let layout = ClosedLayout(activity: activity, secondary: secondary, notch: Self.hardwareNotch)
            let hovering = pose == .hovering
            let scale = Self.closedScale
            PreviewNotch(size: CGSize(width: (layout.totalWidth + (hovering ? 14 : 0)) * scale,
                                      height: (layout.totalHeight + (hovering ? 3 : 0)) * scale),
                         topRadius: 6 * scale,
                         bottomRadius: (layout.rowHeight > 0 ? 16 : hovering ? 12 : 10) * scale) {
                ClosedPreview(activity: activity, secondary: secondary, layout: layout, scale: scale,
                              timerText: "\(settings.focusMinutes):00", tintArtwork: settings.artworkTint)
            }
        }
    }
}
