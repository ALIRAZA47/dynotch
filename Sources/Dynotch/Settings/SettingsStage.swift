import SwiftUI

/// The header of every page: a strip of the app icon's night sky with a model notch hanging from
/// its top edge. The notch acts out the page's settings as they change.
struct SettingsStage: View {
    @ObservedObject var navigation: SettingsNavigation

    static let height: CGFloat = 206

    var body: some View {
        let page = navigation.page
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
                        .foregroundStyle(.white)
                        .accessibilityAddTraits(.isHeader)
                    Text(page.subtitle)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
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
        .environment(\.colorScheme, .dark)
    }
}

private struct StageBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Palette.indigo, Palette.navy], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Palette.lavender.opacity(0.5), Palette.lavender.opacity(0)],
                           center: .top, startRadius: 0, endRadius: 250)
                .scaleEffect(x: 1.6, y: 1, anchor: .top)
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
            .animation(.notchActivity, value: featured)
        }
        .animation(.notchOpen, value: page)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: settings.theme)
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
/// notch whose theme asks for it.
private struct PreviewNotch<Content: View>: View {
    let size: CGSize
    let topRadius: CGFloat
    let bottomRadius: CGFloat
    var isGlass = false
    var bandHeight: CGFloat = 0
    var shadow = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: size.width, height: size.height, alignment: .top)
            .padding(.horizontal, topRadius)
            .background(NotchSurface(isGlass: isGlass, topRadius: topRadius, bottomRadius: bottomRadius, bandHeight: bandHeight))
            .clipShape(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius))
            .shadow(color: .black.opacity(shadow ? (isGlass ? 0.35 : 0.6) : 0), radius: 12, y: 7)
    }
}

private struct CaptionText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.62))
            .contentTransition(.numericText())
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
                    .padding(.horizontal, 16 * scale)
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
                    .foregroundStyle(.white.opacity(0.85))
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
                .font(.system(size: 12.5 * scale, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(PomodoroTimer.Phase.focus.color)
        case .notice(let notice):
            switch notice.kind {
            case .meter(let level):
                LevelBar(level: level)
                    .frame(width: 62 * scale, height: 5 * scale)
            case .info:
                Text(notice.text)
                    .font(.system(size: 12.5 * scale, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(notice.tint)
                    .lineLimit(1)
            }
        case .countdown(let countdown):
            Text(Format.duration(countdown.remaining(at: .now).rounded(.up)))
                .font(.system(size: 12.5 * scale, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(TimerStore.tint)
        case .stopwatch:
            Text("12:34")
                .font(.system(size: 12.5 * scale, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(TimerStore.stopwatchTint)
        case .download:
            Text("45%")
                .font(.system(size: 12.5 * scale, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(DownloadMonitor.tint)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch activity {
        case .trackPeek:
            Text("Midnight City · M83")
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

private struct MethodChip: View {
    let symbol: String
    let text: String
    let isOn: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            Text(text).font(.system(size: 11, weight: .semibold)).monospacedDigit()
        }
        .foregroundStyle(.white.opacity(isOn ? 0.92 : 0.3))
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(.white.opacity(isOn ? 0.12 : 0.03)))
        .overlay(Capsule().strokeBorder(.white.opacity(isOn ? 0.16 : 0.07)))
    }
}

/// A dot per live activity: bright for the one on show, dim for those turned off.
private struct ActivityDots: View {
    let featured: LiveActivityKind?
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 8) {
            Text(featured.map { $0.isShown(with: settings) ? $0.title : "\($0.title) · Off" }
                 ?? "Nothing shows in the closed notch")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            HStack(spacing: 5) {
                ForEach(LiveActivityKind.allCases) { kind in
                    Capsule()
                        .fill(.white.opacity(kind == featured ? 0.95 : kind.isShown(with: settings) ? 0.35 : 0.1))
                        .frame(width: kind == featured ? 14 : 5, height: 5)
                }
            }
        }
    }
}

/// One round of the focus timer, to scale: focus sessions, short breaks and the long break.
private struct FocusRound: View {
    @ObservedObject private var settings = AppSettings.shared

    private let width: CGFloat = 320
    private let gap: CGFloat = 3

    var body: some View {
        let sessions = settings.sessionsPerRound
        let total = CGFloat(sessions * settings.focusMinutes + (sessions - 1) * settings.shortBreakMinutes
            + settings.longBreakMinutes)
        let room = width - gap * CGFloat(sessions * 2 - 1)
        VStack(spacing: 8) {
            HStack(spacing: gap) {
                ForEach(0..<sessions, id: \.self) { index in
                    let last = index == sessions - 1
                    Capsule()
                        .fill(PomodoroTimer.Phase.focus.color)
                        .frame(width: max(4, room * CGFloat(settings.focusMinutes) / total))
                    Capsule()
                        .fill(PomodoroTimer.Phase.shortBreak.color.opacity(last ? 1 : 0.55))
                        .frame(width: max(3, room * CGFloat(last ? settings.longBreakMinutes : settings.shortBreakMinutes) / total))
                }
            }
            .frame(height: 6)
            CaptionText("\(sessions) × \(settings.focusMinutes) min focus · \(FocusSettings.roundLength(settings)) a round")
        }
    }
}

// MARK: Open notch

/// The open notch in miniature: its tab bar and the Nook or the tray.
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
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.5))
                    .padding(.horizontal, selected ? 5 : 3)
                    .frame(height: 11)
                    .background(Capsule().fill(selected ? theme.selection : .clear))
                }
            }
            .frame(width: side, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Image(systemName: "battery.75percent")
                Image(systemName: "gearshape.fill")
            }
            .font(.system(size: 6.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.5))
            .frame(width: side, alignment: .trailing)
        }
    }
}

private struct NookSketch: View {
    let cardRadius: CGFloat
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.notchTheme) private var theme

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
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: cardRadius, style: .continuous).fill(theme.card))
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
        }
    }
}

private struct PlayerSketch: View {
    let tint: Color
    let artworkRadius: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 6) {
                RoundedRectangle(cornerRadius: artworkRadius, style: .continuous)
                    .fill(Palette.sunset)
                    .frame(width: 34, height: 34)
                    .shadow(color: Palette.magenta.opacity(0.4), radius: 4)
                VStack(alignment: .leading, spacing: 1.5) {
                    Text("Midnight City")
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("M83")
                        .font(.system(size: 6.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                    AudioBars(isPlaying: false, color: tint)
                        .frame(width: 11, height: 6)
                        .padding(.top, 4)
                }
                .lineLimit(1)
            }
            Capsule()
                .fill(.white.opacity(0.2))
                .frame(height: 2)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule().fill(.white).frame(width: proxy.size.width * 0.35)
                    }
                }
            HStack {
                ForEach(["shuffle", "backward.fill", "pause.fill", "forward.fill", "repeat"], id: \.self) { symbol in
                    Image(systemName: symbol)
                    if symbol != "repeat" { Spacer(minLength: 0) }
                }
            }
            .font(.system(size: 6.5, weight: .bold))
            .foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxHeight: .infinity, alignment: .top)
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
                        .foregroundStyle(.white.opacity(0.45))
                }
                if tray.items.isEmpty {
                    Text("Drop files here")
                        .font(.system(size: 6.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
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
            .background(RoundedRectangle(cornerRadius: cardRadius, style: .continuous).fill(theme.card))
            VStack(spacing: 3) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 9, weight: .medium))
                Text("AirDrop").font(.system(size: 6, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.8))
            .frame(width: 50)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: cardRadius, style: .continuous).fill(theme.card))
        }
    }
}

// MARK: Model notch elsewhere

/// The header's night sky, for windows other than Settings.
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
