import SwiftUI

/// The header of every page: a stage of graphite glass, light or dark with the page and lit from
/// above in the user's accent, with a model notch hanging from its top edge. The notch acts out
/// the page's settings as they change.
struct SettingsStage: View {
    @ObservedObject var navigation: SettingsNavigation
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    static let height: CGFloat = 206

    var body: some View {
        let page = navigation.page
        let ink = StageInk(colorScheme: colorScheme, contrast: contrast)
        ZStack(alignment: .bottom) {
            // Both are decoration. The backdrop's glow is stretched past the stage, where `clipped`
            // hides it but hit testing still finds it: it swallowed clicks on the sidebar's top rows.
            StageBackdrop()
                .allowsHitTesting(false)
            StagePreview(navigation: navigation)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(page.title)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(ink.primary)
                        .accessibilityAddTraits(.isHeader)
                    Text(page.subtitle)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(ink.secondary)
                }
                .id(page)
                .transition(.opacity)
                Spacer(minLength: 0)
                StageAction(page: page)
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 20)
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .clipped()
    }
}

/// The stage's text. On the dark stage it's white at the notch's levels, a step brighter with
/// Increase Contrast; on the light one it's the system's label color, with the second level a
/// little firmer than the system's, which reads under 4.5:1 on the stage's grey.
struct StageInk {
    let colorScheme: ColorScheme
    var contrast = ColorSchemeContrast.standard

    var primary: Color { colorScheme == .dark ? .white : .primary }
    var secondary: Color {
        colorScheme == .dark ? .white.opacity(contrast == .increased ? 0.78 : 0.62) : .primary.opacity(0.7)
    }
    /// A method that's off. It's news, not a disabled control, so it reads at the second level;
    /// its chip has no fill.
    var off: Color { secondary }
}

/// Graphite glass lit from above, light or dark with the page: a bloom of the user's accent where
/// the model notch hangs, on the dark stage a white glow under the top edge, and a line along the
/// foot where the stage meets the page.
private struct StageBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.windowAccent) private var accent

    var body: some View {
        let bloom = accent.color.opacity(Palette.stageBloomOpacity(colorScheme))
        ZStack {
            Palette.stageGradient
            // The light fades out before the stage's left edge, where the window's own gradient takes
            // over behind the sidebar, so no edge shows between them.
            ZStack {
                RadialGradient(colors: [bloom, bloom.opacity(0)], center: .top, startRadius: 0, endRadius: Palette.stageBloomRadius)
                    .scaleEffect(x: Palette.stageBloomStretch, y: 1, anchor: .top)
                RadialGradient(colors: [Palette.stageGlow, Palette.stageGlow.opacity(0)], center: .top, startRadius: 0,
                               endRadius: Palette.stageGlowRadius)
                    .scaleEffect(x: Palette.stageGlowStretch, y: 1, anchor: .top)
            }
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08)],
                                 startPoint: .leading, endPoint: .trailing))
        }
        .overlay(alignment: .bottom) {
            Palette.stageFoot.frame(height: 1)
        }
    }
}

/// A button that tries the page out in the real notch.
private struct StageAction: View {
    let page: SettingsPage
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        switch page {
        case .general, .appearance:
            button("Open the Notch") { NotchManager.shared.open(tab: .home) }
        case .nook:
            button("Open the Nook") { NotchManager.shared.open(tab: .home) }
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
        CapsuleButton(title: title, symbol: symbol, kind: .glass, action: action)
            .transition(.opacity)
    }
}

/// The model notch and a line about it. Closed or open, it's one shape, so moving between pages
/// opens and closes it like the real one.
private struct StagePreview: View {
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var permissions = PermissionStatus.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The closed notch is drawn larger than life and the open one smaller, so both fit.
    private static let closedScale: CGFloat = 1.4
    private static let openScale: CGFloat = 0.46
    private static let hardwareNotch = CGSize(width: 185, height: 32)
    private static let cycle: TimeInterval = 2.6
    /// How it moves with Reduce Motion: no spring.
    private static let eased = Animation.easeOut(duration: 0.2)

    var body: some View {
        let page = navigation.page
        // Only the Live Activities page cycles through samples.
        TimelineView(.periodic(from: .now, by: page == .activities && !reduceMotion ? Self.cycle : 3600)) { context in
            let featured = featuredActivity(tick: Int(context.date.timeIntervalSinceReferenceDate / Self.cycle))
            VStack(spacing: 13) {
                notch(featured: featured)
                caption(featured: featured)
                    .id(page)
                    .transition(.opacity)
            }
            .animation(reduceMotion ? Self.eased : .notchActivity, value: featured)
        }
        .animation(reduceMotion ? Self.eased : .notchOpen, value: page)
        .animation(reduceMotion ? Self.eased : .spring(response: 0.35, dampingFraction: 0.85), value: settings.theme)
        .environment(\.notchTheme, settings.theme)
    }

    // MARK: Notch

    @ViewBuilder
    private func notch(featured: LiveActivityKind?) -> some View {
        let page = navigation.page
        if isOpen {
            let scale = Self.openScale
            let theme = settings.theme
            PreviewNotch(size: CGSize(width: settings.openWidth * scale, height: settings.openHeight * scale),
                         topRadius: theme.topRadius * scale, bottomRadius: theme.bottomRadius * scale,
                         isGlass: theme.isGlass, bandHeight: 32 * scale, shadow: settings.showOpenShadow) {
                OpenPreview(tab: page == .tray ? .tray : .home, scale: scale)
            }
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
            CaptionText("\(Int(settings.openWidth)) × \(Int(settings.openHeight)) pt · \(settings.theme.material.title) · \(settings.notchAccent.title)")
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

/// The notch silhouette at preview size, hanging from the top edge. Black, or glass for an open
/// notch whose theme asks for it. Whatever the stage around it, the notch is dark inside, with
/// white on black as the real one has.
private struct PreviewNotch<Content: View>: View {
    let size: CGSize
    let topRadius: CGFloat
    let bottomRadius: CGFloat
    var isGlass = false
    var bandHeight: CGFloat = 0
    var shadow = false
    @ViewBuilder var content: Content
    /// The stage's appearance, which the shadow follows.
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        let onDark = colorScheme == .dark
        content
            .frame(width: size.width, height: size.height, alignment: .top)
            .padding(.horizontal, topRadius)
            .background(NotchSurface(isGlass: isGlass, topRadius: topRadius, bottomRadius: bottomRadius, bandHeight: bandHeight))
            // Glass carries its own dark layer live. The snapshot's stand-in, on the light stage, needs this.
            .background {
                if isSnapshot, isGlass, !onDark { Color.black.opacity(0.35) }
            }
            .clipShape(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius))
            .environment(\.colorScheme, .dark)
            // Softer on the light stage, and fainter under glass, which would show it through.
            .shadow(color: .black.opacity(shadow ? (onDark ? (isGlass ? 0.35 : 0.6) : (isGlass ? 0.15 : 0.25)) : 0),
                    radius: 12, y: onDark ? 7 : 6)
    }
}

/// A line under the model notch, in the stage's second color.
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
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .monospacedDigit()
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
    }

    @ViewBuilder
    private var leading: some View {
        switch activity {
        case .idle:
            EmptyView()
        case .music, .trackPeek:
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
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch activity {
        case .idle:
            EmptyView()
        case .music, .trackPeek:
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
        case .focus(let mode):
            FocusGlyph(mode: mode, size: ClosedLayout.glyphSize * scale)
        }
    }
}

/// How the notch opens, as an info chip: glass on the stage, dim while that way is off.
private struct MethodChip: View {
    let symbol: String
    let text: String
    let isOn: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let ink = StageInk(colorScheme: colorScheme, contrast: contrast)
        let dark = colorScheme == .dark
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            Text(text).font(.system(size: 12, weight: .medium)).monospacedDigit()
        }
        .foregroundStyle(isOn ? ink.primary : ink.off)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background {
            if isOn {
                Capsule().fill(dark ? AnyShapeStyle(Color.white.opacity(0.13)) : AnyShapeStyle(Palette.wash))
                    .overlay(Capsule().strokeBorder(dark ? LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.06)],
                                                                         startPoint: .top, endPoint: .bottom)
                                                         : Palette.rimGradient))
            } else {
                Capsule().strokeBorder(Palette.stroke)
            }
        }
    }
}

/// A dot per live activity: bright for the one on show, dim for those turned off.
private struct ActivityDots: View {
    let featured: LiveActivityKind?
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 8) {
            CaptionText(featured.map { $0.isShown(with: settings) ? $0.title : "\($0.title) · Off" }
                        ?? "Nothing shows in the closed notch", isNumeric: false)
            HStack(spacing: 5) {
                ForEach(LiveActivityKind.allCases) { kind in
                    Capsule()
                        .fill(Color.primary.opacity(kind == featured ? 0.95 : kind.isShown(with: settings) ? 0.35 : 0.1))
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
        // On the light stage the phases' pale colors would all but vanish, so they take the window's deeper shades.
        let onLight = colorScheme == .light
        let focus = onLight ? WindowAccent(choice: .red).color : PomodoroTimer.Phase.focus.color
        let rest = onLight ? WindowAccent(choice: .green).color : PomodoroTimer.Phase.shortBreak.color
        VStack(spacing: 8) {
            HStack(spacing: gap) {
                ForEach(0..<sessions, id: \.self) { index in
                    let last = index == sessions - 1
                    Capsule()
                        .fill(focus)
                        .frame(width: max(4, room * CGFloat(settings.focusMinutes) / total))
                    Capsule()
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

/// The open notch in miniature: its header and the Nook or the tray.
private struct OpenPreview: View {
    let tab: NotchTab
    let scale: CGFloat
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.notchTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: 32 * scale)
            Group {
                if tab == .tray {
                    TraySketch(cardRadius: theme.cardRadius * scale)
                } else {
                    NookSketch(cardRadius: theme.cardRadius * scale)
                }
            }
            .padding(.top, 8 * scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, NotchTheme.inset * scale)
        .padding(.bottom, NotchTheme.inset * scale)
    }

    /// As the real header has it: the tabs in a track pressed into the slab, the selected one a
    /// jewel of the accent with ink on it, and the command pill and the ··· menu on the right.
    private var header: some View {
        // As in the real header: each side gets what's left beside the camera housing.
        let side = max(0, (settings.openWidth - NotchTheme.inset * 2 - 185) / 2 - 6) * scale
        return HStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(settings.enabledTabs) { item in
                    let selected = item == tab
                    HStack(spacing: 2.5) {
                        Image(systemName: item.symbol).font(.system(size: 6.5, weight: .semibold))
                        if selected {
                            Text(item.title).font(.system(size: 6.5, weight: .semibold)).fixedSize()
                        }
                    }
                    .foregroundStyle(selected ? theme.onAccent : theme.primary.opacity(0.55))
                    .padding(.horizontal, selected ? 5 : 3)
                    .frame(height: 11)
                    .background {
                        if selected { GlassSurface(depth: .lens(theme.accent), shape: Capsule()) }
                    }
                }
            }
            .padding(1)
            .glass(.well, in: Capsule())
            .frame(width: side, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                HStack(spacing: 3) {
                    Image(systemName: "magnifyingglass")
                    Text("Type a command")
                }
                .padding(.horizontal, 5)
                .frame(height: 13)
                .glass(.control, in: Capsule())
                Image(systemName: "ellipsis")
            }
            .font(.system(size: 6, weight: .semibold))
            .foregroundStyle(theme.secondary)
            .frame(width: side, alignment: .trailing)
        }
    }
}

private struct NookSketch: View {
    let cardRadius: CGFloat
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.notchTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let widgets = settings.homeWidgets
            HStack(spacing: 5.5) {
                PlayerSketch(tint: settings.artworkTint ? Color(red: 1, green: 0.45, blue: 0.55) : theme.accent,
                             artworkRadius: cardRadius)
                    .frame(width: widgets.isEmpty ? proxy.size.width : (proxy.size.width * 0.5).rounded())
                ForEach(Array(widgets.enumerated()), id: \.offset) { _, widget in
                    VStack(spacing: 4) {
                        Image(systemName: widget.symbol)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                        Text(widget.title)
                            .font(.system(size: 6.5, weight: .semibold))
                            .foregroundStyle(theme.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .glass(.pane, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
                    .transition(reduceMotion ? AnyTransition.opacity : .opacity.combined(with: .scale(scale: 0.9)))
                }
            }
        }
    }
}

/// The player in miniature: glass-rimmed art, the bold title, a groove of light in the music's tint
/// and a pearl to play.
private struct PlayerSketch: View {
    let tint: Color
    let artworkRadius: CGFloat
    @Environment(\.notchTheme) private var theme

    private static let pearl: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 6) {
                let art = RoundedRectangle(cornerRadius: artworkRadius, style: .continuous)
                art.fill(Palette.sunset)
                    .overlay(art.strokeBorder(LinearGradient(colors: [.white.opacity(0.4), .white.opacity(0.05)],
                                                             startPoint: .top, endPoint: .bottom)))
                    .frame(width: 34, height: 34)
                    .shadow(color: Palette.magenta.opacity(0.4), radius: 4)
                VStack(alignment: .leading, spacing: 1.5) {
                    Text("Midnight City")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(theme.primary)
                    Text("M83")
                        .font(.system(size: 6.5, weight: .medium))
                        .foregroundStyle(theme.secondary)
                    AudioBars(isPlaying: false, color: tint)
                        .frame(width: 11, height: 6)
                        .padding(.top, 4)
                }
                .lineLimit(1)
            }
            Capsule()
                .fill(theme.track)
                .frame(height: 2)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(LinearGradient(colors: [tint.opacity(0.55), tint], startPoint: .leading, endPoint: .trailing))
                            .frame(width: proxy.size.width * 0.35)
                    }
                }
            HStack {
                ForEach(["shuffle", "backward.fill", "pause.fill", "forward.fill", "repeat"], id: \.self) { symbol in
                    if symbol == "pause.fill" {
                        pearl(symbol)
                    } else {
                        Image(systemName: symbol)
                            .foregroundStyle(.white.opacity(symbol == "shuffle" || symbol == "repeat" ? 0.5 : 0.85))
                    }
                    if symbol != "repeat" { Spacer(minLength: 0) }
                }
            }
            .font(.system(size: 6.5, weight: .bold))
            .frame(height: Self.pearl)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// The play button's pearl of white glass, with the glyph in black. No shadow: the miniature
    /// redraws all the while a size slider is dragged.
    private func pearl(_ symbol: String) -> some View {
        let side = Self.pearl
        return Image(systemName: symbol)
            .font(.system(size: side * 0.4, weight: .bold))
            .foregroundStyle(.black.opacity(0.86))
            .frame(width: side, height: side)
            .background(Circle().fill(LinearGradient(colors: [.white, .white.opacity(0.8)], startPoint: .top, endPoint: .bottom)))
            .overlay(Circle().strokeBorder(LinearGradient(colors: [.white, .white.opacity(0.2)], startPoint: .top, endPoint: .bottom)))
    }
}

private struct TraySketch: View {
    let cardRadius: CGFloat
    @ObservedObject private var tray = TrayStore.shared
    @Environment(\.notchTheme) private var theme

    var body: some View {
        HStack(spacing: 5.5) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 3) {
                    Text("Tray").font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
                    Text(tray.items.count == 1 ? "1 item" : "\(tray.items.count) items")
                        .font(.system(size: 6.5, weight: .medium))
                        .foregroundStyle(theme.tertiary)
                }
                if tray.items.isEmpty {
                    Text("Drop files here")
                        .font(.system(size: 6.5, weight: .medium))
                        .foregroundStyle(theme.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack(alignment: .top, spacing: 4) {
                        ForEach(tray.items.prefix(5)) { item in
                            VStack(spacing: 2) {
                                Image(nsImage: IconCache.icon(forFile: item.url.path, side: 20))
                                    .resizable()
                                    .frame(width: 18, height: 18)
                                Text(item.url.lastPathComponent)
                                    .font(.system(size: 5, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .frame(width: 30)
                        }
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .glass(.pane, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
            VStack(spacing: 3) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 9, weight: .medium))
                Text("AirDrop").font(.system(size: 6, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.8))
            .frame(width: 50)
            .frame(maxHeight: .infinity)
            .glass(.pane, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        }
    }
}

// MARK: Model notch elsewhere

/// The header's lit glass, for windows other than Settings.
struct StageSky: View {
    var body: some View {
        StageBackdrop()
    }
}

/// The header's model notch on its own, for the welcome tour: closed with a live activity, under
/// the pointer, or open on a tab.
struct ModelNotch: View {
    enum Pose: Equatable {
        case closed(ClosedActivity, secondary: CompactActivity? = nil)
        case hovering
        case open(NotchTab)
    }

    let pose: Pose
    @ObservedObject private var settings = AppSettings.shared

    // As in StagePreview: the closed notch larger than life, the open one smaller.
    private static let closedScale: CGFloat = 1.4
    private static let openScale: CGFloat = 0.46
    private static let hardwareNotch = CGSize(width: 185, height: 32)

    var body: some View {
        notch
            .environment(\.notchTheme, settings.theme)
    }

    @ViewBuilder
    private var notch: some View {
        switch pose {
        case .open(let tab):
            let scale = Self.openScale
            let theme = settings.theme
            PreviewNotch(size: CGSize(width: settings.openWidth * scale, height: settings.openHeight * scale),
                         topRadius: theme.topRadius * scale, bottomRadius: theme.bottomRadius * scale,
                         isGlass: theme.isGlass, bandHeight: 32 * scale, shadow: settings.showOpenShadow) {
                OpenPreview(tab: tab, scale: scale)
            }
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
