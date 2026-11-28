import AppKit
import ServiceManagement
import SwiftUI

/// An on/off setting, shown as a tile.
struct SwitchOption: Identifiable {
    let title: String
    let detail: String
    let symbol: String
    /// The badge's color while it's on. Without one, the window accent.
    var tint: Color?
    var spokenTitle: String?
    let setting: ReferenceWritableKeyPath<AppSettings, Bool>

    var id: String { title }
}

/// Tiles in rows of `columns`; the tiles in a row share the tallest one's height.
struct TileGrid<Item: Identifiable, Tile: View>: View {
    let items: [Item]
    var columns = 2
    @ViewBuilder let tile: (Item) -> Tile

    var body: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            ForEach(Array(stride(from: 0, to: items.count, by: columns)), id: \.self) { start in
                GridRow {
                    ForEach(items[start..<min(start + columns, items.count)]) { item in
                        tile(item)
                    }
                }
            }
        }
    }
}

/// Switch tiles for settings on `AppSettings`.
private struct SwitchGrid: View {
    let options: [SwitchOption]
    var columns = 2
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        TileGrid(items: options, columns: columns) { option in
            SwitchTile(title: option.title, detail: option.detail, symbol: option.symbol, tint: option.tint,
                       spokenTitle: option.spokenTitle, isOn: $settings[dynamicMember: option.setting])
        }
    }
}

/// A slider with its name and value, as a row in a card. `spokenTitle` is what VoiceOver
/// reads when the visible name leans on its section, like a second "Width".
private struct SliderRow: View {
    let title: String
    var spokenTitle: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    let spoken: (Double) -> String

    var body: some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 88, alignment: .leading)
                .accessibilityHidden(true)
            TrackSlider(title: spokenTitle ?? title, value: $value, range: range, step: step, spokenValue: spoken(value))
            Text(format(value))
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Palette.secondaryText)
                .frame(width: 56, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }
}

private func points(_ value: Double) -> String { "\(Int(value)) pt" }
private func spokenPoints(_ value: Double) -> String { "\(Int(value)) points" }

/// Behind a text field on a page: Orbit's field, at the button roundness, with a hairline round it.
struct FieldWell: View {
    @Environment(\.notchTheme) private var theme

    var body: some View {
        theme.controlShape.fill(Palette.field)
            .overlay(theme.controlShape.strokeBorder(Palette.stroke))
    }
}

// MARK: General

struct GeneralSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let openers = [
        SwitchOption(title: "Hover", detail: "A glance, or the whole notch, when the pointer rests on it",
                     symbol: "cursorarrow.rays", setting: \.openOnHover),
        SwitchOption(title: "Swipe", detail: "Swipe down on the trackpad to open, up to close, sideways to skip a track or, once it's open, to change sections",
                     symbol: "rectangle.and.hand.point.up.left.fill",
                     setting: \.swipeGestures),
        SwitchOption(title: "Keyboard shortcut", detail: "Toggle the notch with ⌃⌥N", symbol: "command",
                     setting: \.globalShortcut),
        SwitchOption(title: "Haptic feedback", detail: "A tap from the trackpad when the notch responds",
                     symbol: "hand.tap.fill", setting: \.haptics),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            SettingsSection(title: "Opening the notch") {
                SwitchGrid(options: openers)
                if settings.openOnHover {
                    SettingsCard {
                        HoverShowsRow()
                        CardDivider()
                        SliderRow(title: "Hover delay", value: $settings.hoverDelay, range: 0...1, step: 0.05,
                                  format: { String(format: "%.2f s", $0) },
                                  spoken: { String(format: "%.2f seconds", $0) })
                    }
                    .transition(reduceMotion ? AnyTransition.opacity : .opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.85),
                       value: settings.openOnHover)

            SettingsSection(title: "Command field",
                            footer: "Start a timer (tea 4m), add a note or a reminder (remind Call Sam 5pm), flip a toggle, "
                                + "switch a profile, run a shortcut or work out a sum. In the open notch, click Type a command.") {
                SettingsCard {
                    SwitchRow(title: "Open it with ⌃⌥K", detail: "From anywhere, ready to type", symbol: "magnifyingglass",
                              isOn: $settings.commandShortcut)
                    CardDivider()
                    SwitchRow(title: "Suggest what you use",
                              detail: "An empty field lists your recent and frequent commands first. It counts the command, never what you type, and turning this off forgets the count.",
                              symbol: "sparkles", isOn: $settings.learnsCommands)
                }
            }

            SettingsSection(title: "Show the notch on",
                            footer: "Displays without a notch get a virtual one that hangs from the top edge.") {
                HStack(spacing: 10) {
                    ForEach(DisplayMode.allCases) { mode in
                        ChoiceTile(title: mode.title, isSelected: settings.displayMode == mode) {
                            settings.displayMode = mode
                        } art: {
                            DisplaysArt(mode: mode, isSelected: settings.displayMode == mode)
                        }
                    }
                }
            }

            ProfilesSection()

            TerminalSetupSection()

            SettingsSection(title: "App") {
                SettingsCard {
                    LaunchAtLoginRow()
                    CardDivider()
                    SwitchRow(title: "Show menu bar icon", detail: "Settings, the tray and the timer, a click away",
                              symbol: "menubar.rectangle", isOn: $settings.showMenuBarIcon)
                }
            }
        }
    }
}

/// What resting the pointer on the notch brings up: a glance at what's live, or the whole notch.
private struct HoverShowsRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 14) {
            Text("Hover shows")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 88, alignment: .leading)
            HStack(spacing: 8) {
                ForEach(HoverShows.allCases) { choice in
                    ChoiceChip(title: choice.title, symbol: choice.symbol, isSelected: settings.hoverShows == choice) {
                        settings.hoverShows = choice
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct LaunchAtLoginRow: View {
    @ViewState private var isEnabled = SMAppService.mainApp.status == .enabled
    @ViewState private var message: String?

    var body: some View {
        SwitchRow(title: "Launch at login", detail: message ?? "Start Dynotch when you log in", symbol: "power",
                  isOn: Binding(get: { isEnabled }, set: { enable in
            do {
                if enable {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                message = SMAppService.mainApp.status == .requiresApproval
                    ? "Allow Dynotch in System Settings → General → Login Items." : nil
            } catch {
                message = error.localizedDescription
            }
            isEnabled = SMAppService.mainApp.status == .enabled
        }))
    }
}

/// A laptop and a monitor, with a notch on each display the mode covers.
private struct DisplaysArt: View {
    let mode: DisplayMode
    let isSelected: Bool
    @Environment(\.windowAccent) private var accent

    var body: some View {
        HStack(alignment: .bottom, spacing: 7) {
            Screen(width: 34, height: 22, hasNotch: mode != .main, isLaptop: true)
            Screen(width: 30, height: 20, hasNotch: mode != .notched, isLaptop: false)
        }
        .foregroundStyle(isSelected ? accent.color : Color.secondary)
    }

    private struct Screen: View {
        let width: CGFloat
        let height: CGFloat
        let hasNotch: Bool
        let isLaptop: Bool

        var body: some View {
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(lineWidth: 1.6)
                    .frame(width: width, height: height)
                    .overlay(alignment: .top) {
                        if hasNotch {
                            NotchShape(topRadius: 1.5, bottomRadius: 2)
                                .frame(width: width * 0.36, height: 4.5)
                        }
                    }
                if isLaptop {
                    Capsule().frame(width: width + 8, height: 2.5)
                } else {
                    Rectangle().frame(width: 2, height: 4)
                    Capsule().frame(width: 13, height: 2)
                }
            }
            .opacity(hasNotch ? 1 : 0.4)
        }
    }
}

// MARK: Appearance

/// Orbit's look: theme and accent, button roundness, where the section buttons and row buttons go,
/// how it moves, what the closed notch shows, the open size, and the virtual notch.
struct AppearanceSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard {
                SettingRow(title: "Theme", detail: "Light, dark, or whatever macOS is using.") {
                    SettingSegments(title: "Theme", selection: $settings.notchAppearance,
                                    options: NotchAppearance.allCases.map { ($0, $0.title) })
                }
                CardDivider()
                SettingRow(title: "Accent", detail: "Means “needs you” and marks what’s selected.") {
                    AccentPicker(selection: $settings.notchAccent)
                }
            }

            SettingsCard {
                SettingRow(title: "Button roundness", detail: "Buttons, switches, rows and fields. 0 is square.") {
                    HStack(spacing: 12) {
                        TrackSlider(title: "Button roundness", value: $settings.buttonRadius,
                                    range: Double(NotchTheme.radiusRange.lowerBound)...Double(NotchTheme.radiusRange.upperBound),
                                    step: 1, spokenValue: spokenPoints(settings.buttonRadius))
                            .frame(width: 180)
                        Text(points(settings.buttonRadius))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(Palette.secondaryText)
                            .frame(width: 40, alignment: .leading)
                            .accessibilityHidden(true)
                    }
                }
                CardDivider()
                RoundnessPreview()
            }

            SettingsCard {
                PlacementPicker(title: "Section buttons",
                                detail: "Where Live, Music, Tray and the other sections sit around the open notch.",
                                selection: $settings.sectionPlacement, columns: 7) { placement, isSelected in
                    SectionPlacementThumb(placement: placement, isSelected: isSelected)
                }
                CardDivider()
                PlacementPicker(title: "Row actions",
                                detail: "Where Allow, Pause, Join and the other buttons on a row appear.",
                                selection: $settings.rowActionMode, columns: 6) { mode, isSelected in
                    RowActionThumb(mode: mode, isSelected: isSelected)
                }
                CardDivider()
                SettingRow(title: "Motion", detail: "How the panel opens and the strips slide out.") {
                    SettingSegments(title: "Motion", selection: $settings.notchMotion,
                                    options: NotchMotion.allCases.map { ($0, $0.title) })
                }
                CardDivider()
                SettingRow(title: "Closed notch shows", detail: "What sits beside the camera when nothing is open.") {
                    SettingSegments(title: "Closed notch shows", selection: $settings.closedNotchShows,
                                    options: ClosedNotchShows.allCases.map { ($0, $0.title) })
                }
            }

            SettingsSection(title: "Open notch",
                            footer: "The closed notch stays black whatever the theme, so it blends with the camera housing.") {
                SettingsCard {
                    SliderRow(title: "Width", spokenTitle: "Open notch width", value: $settings.openWidth,
                              range: AppSettings.openWidthRange, step: 10,
                              format: points, spoken: spokenPoints)
                    CardDivider()
                    SliderRow(title: "Height", spokenTitle: "Open notch height", value: $settings.openHeight,
                              range: AppSettings.openHeightRange, step: 10,
                              format: points, spoken: spokenPoints)
                    CardDivider()
                    SwitchRow(title: "Shadow", detail: "A soft shadow under the open notch",
                              symbol: "square.2.layers.3d.bottom.filled", tint: Palette.indigo, isOn: $settings.showOpenShadow)
                    CardDivider()
                    SwitchRow(title: "Artwork tint", detail: "Color the player with the album art instead of the accent",
                              symbol: "paintpalette.fill", tint: Palette.magenta, isOn: $settings.artworkTint)
                }
            }

            SettingsSection(title: "Virtual notch", footer: virtualNotchFooter) {
                HStack(spacing: 10) {
                    ForEach(VirtualNotchStyle.allCases) { style in
                        ChoiceTile(title: style.title, detail: style.detail, isSelected: settings.virtualNotchStyle == style) {
                            settings.virtualNotchStyle = style
                        } art: {
                            VirtualNotchArt(style: style, isSelected: settings.virtualNotchStyle == style)
                        }
                    }
                }
                SettingsCard {
                    VirtualNotchSketch(width: settings.virtualNotchWidth, style: settings.virtualNotchStyle)
                    CardDivider()
                    SliderRow(title: "Width", spokenTitle: "Virtual notch width", value: $settings.virtualNotchWidth,
                              range: 140...280, step: 5,
                              format: points, spoken: spokenPoints)
                }
            }
        }
    }

    private var virtualNotchFooter: String {
        switch settings.virtualNotchStyle {
        case .notch:
            "Used on displays without a camera notch."
        case .line:
            "Used on displays without a camera notch. The line covers nothing: it grows into the notch while "
                + "something's showing, when you hover, and when it opens."
        }
    }
}

/// The roundness at work: a plain button, a focus button and a symbol button, as the notch draws them.
private struct RoundnessPreview: View {
    @Environment(\.notchTheme) private var theme

    var body: some View {
        HStack(spacing: 16) {
            Text("Preview")
                .font(.system(size: 13))
                .foregroundStyle(Palette.secondaryText)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                OrbitButton(title: "Deny", height: 28) {}
                PillButton(title: "Allow once", tint: theme.alert, height: 28) {}
                OrbitButton(symbol: "pause.fill", height: 28, help: "Pause") {}
            }
            // A picture of the buttons, not buttons to press.
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 48)
    }
}

/// A virtual notch's monitor, with the notch, or just the line, along its top edge.
private struct VirtualNotchArt: View {
    let style: VirtualNotchStyle
    let isSelected: Bool
    @Environment(\.windowAccent) private var accent

    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(lineWidth: 1.6)
                .frame(width: 40, height: 26)
                .overlay(alignment: .top) {
                    switch style {
                    case .notch:
                        NotchShape(topRadius: 1.5, bottomRadius: 2.5)
                            .frame(width: 16, height: 5.5)
                    case .line:
                        RoundedRectangle(cornerRadius: 1)
                            .frame(width: 14, height: 2)
                            .padding(.top, 2.6)
                    }
                }
            Rectangle().frame(width: 2, height: 4)
            RoundedRectangle(cornerRadius: 1).frame(width: 15, height: 2)
        }
        .foregroundStyle(isSelected ? accent.color : Palette.secondaryText)
    }
}

/// The accents as a row of swatches at the button roundness, and the name of the one picked.
private struct AccentPicker: View {
    @Binding var selection: NotchAccent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(NotchAccent.allCases) { accent in
                    AccentSwatch(accent: accent, isSelected: selection == accent) {
                        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.2)) {
                            selection = accent
                        }
                    }
                }
            }
            Text(selection.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.secondaryText)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Accent color")
    }
}

private struct AccentSwatch: View {
    let accent: NotchAccent
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.notchTheme) private var theme
    @Environment(\.windowAccent) private var windowAccent
    @ViewState private var hovering = false

    var body: some View {
        let radius = theme.radius
        Button(action: action) {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(accent.color)
                .frame(width: 18, height: 18)
                .padding(3)
                .overlay(RoundedRectangle(cornerRadius: radius + 2, style: .continuous)
                    .strokeBorder(isSelected ? windowAccent.color : Palette.track.opacity(hovering ? 1 : 0), lineWidth: 2))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.9))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(accent.title)
        .accessibilityLabel(accent.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// The top of an external display with the virtual notch hanging from it, or the line it rests as, at half size.
private struct VirtualNotchSketch: View {
    let width: Double
    var style: VirtualNotchStyle = .notch
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isLine = style == .line
        ZStack(alignment: .top) {
            Palette.wall
            Palette.menuBar.frame(height: 12)
            NotchShape(topRadius: isLine ? 0 : 3, bottomRadius: isLine ? 1 : 6)
                .fill(.black.opacity(isLine ? 0.45 : 1))
                .frame(width: width / 2 + (isLine ? 0 : 6), height: isLine ? 2 : 14)
                .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.8), value: width)
                .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.85), value: style)
        }
        .frame(height: 44)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 9, topTrailingRadius: 9, style: .continuous))
        .padding([.horizontal, .top], 1)
        .accessibilityHidden(true)
    }
}

// MARK: Placement pickers

/// A setting whose choices are drawn as small pictures of the open notch, in a row under its name.
private struct PlacementPicker<Choice: Hashable & Identifiable, Thumb: View>: View where Choice: CaseIterable,
    Choice.AllCases: RandomAccessCollection {
    let title: String
    let detail: String
    @Binding var selection: Choice
    let columns: Int
    @ViewBuilder let thumb: (Choice, Bool) -> Thumb
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Palette.secondaryText)
            }
            .accessibilityElement(children: .combine)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: columns), spacing: 8) {
                ForEach(Array(Choice.allCases)) { choice in
                    PlacementChoice(title: name(of: choice), isSelected: choice == selection) {
                        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.2)) { selection = choice }
                    } thumb: {
                        thumb(choice, choice == selection)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func name(of choice: Choice) -> String {
        switch choice {
        case let placement as SectionPlacement: placement.title
        case let mode as RowActionMode: mode.title
        default: "\(choice)"
        }
    }
}

private struct PlacementChoice<Thumb: View>: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let thumb: Thumb

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                thumb
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.97))
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// A picture 84 by 46 points, as the design draws them, scaled to the width it's given: a strip of
/// desk, ringed in the accent when it's the one picked.
private struct Thumbnail<Content: View>: View {
    let isSelected: Bool
    @ViewBuilder var content: Content
    @Environment(\.windowAccent) private var accent

    static var size: CGSize { CGSize(width: 84, height: 46) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Palette.wall
                content
            }
            .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
            .clipped()
            .scaleEffect(proxy.size.width / Self.size.width, anchor: .topLeading)
        }
        .aspectRatio(Self.size.width / Self.size.height, contentMode: .fit)
        .clipShape(shape)
        .overlay(shape.strokeBorder(isSelected ? accent.color : Palette.stroke, lineWidth: isSelected ? 2 : 1))
        .accessibilityHidden(true)
    }
}

/// A shape placed in a thumbnail's 84 by 46 points.
private struct Mark: View {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    var fill: Color
    var radius: CGFloat = 1
    var line = false

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(fill)
            .overlay {
                if line { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.stroke) }
            }
            .frame(width: width, height: height)
            .offset(x: x, y: y)
    }
}

/// Where the section buttons go, drawn round a little open panel.
private struct SectionPlacementThumb: View {
    let placement: SectionPlacement
    let isSelected: Bool
    @Environment(\.windowAccent) private var accent

    var body: some View {
        Thumbnail(isSelected: isSelected) {
            UnevenRoundedRectangle(bottomLeadingRadius: 5, bottomTrailingRadius: 5, style: .continuous)
                .fill(Palette.window)
                .overlay(UnevenRoundedRectangle(bottomLeadingRadius: 5, bottomTrailingRadius: 5, style: .continuous)
                    .strokeBorder(Palette.stroke))
                .frame(width: 48, height: 28)
                .offset(x: 18)
            marks
        }
    }

    @ViewBuilder
    private var marks: some View {
        let a = accent.fill
        switch placement {
        case .under:
            Mark(x: 22, y: 30, width: 40, height: 6, fill: a)
        case .sides:
            Mark(x: 10, y: 12, width: 5, height: 16, fill: a)
            Mark(x: 69, y: 12, width: 5, height: 16, fill: a)
        case .left:
            Mark(x: 10, y: 8, width: 5, height: 26, fill: a)
        case .right:
            Mark(x: 69, y: 8, width: 5, height: 26, fill: a)
        case .band:
            Mark(x: 18, y: 4, width: 14, height: 4, fill: a)
            Mark(x: 52, y: 4, width: 14, height: 4, fill: a)
            UnevenRoundedRectangle(bottomLeadingRadius: 2, bottomTrailingRadius: 2).fill(.black)
                .frame(width: 16, height: 6).offset(x: 34)
        case .arc:
            ForEach([(10.0, 30.0), (22, 35), (38, 37), (54, 35), (66, 30)], id: \.0) { point in
                Circle().fill(a).frame(width: 6, height: 6).offset(x: point.0, y: point.1)
            }
        case .hidden:
            Mark(x: 26, y: 21, width: 32, height: 3, fill: Palette.secondaryText.opacity(0.6))
        }
    }
}

/// Where a row's buttons show, drawn as three rows and their buttons.
private struct RowActionThumb: View {
    let mode: RowActionMode
    let isSelected: Bool
    @Environment(\.windowAccent) private var accent

    var body: some View {
        Thumbnail(isSelected: isSelected) {
            switch mode {
            case .hover:
                row(8)
                row(19, raised: true, action: .full)
                row(30)
            case .always:
                row(8, action: .full)
                row(19, action: .full)
                row(30, action: .full)
            case .primary:
                row(8, action: .short)
                row(19, action: .short)
                row(30, action: .short)
            case .bar:
                row(6)
                row(15, raised: true)
                row(24)
                row(35, raised: true, action: .full)
            case .band:
                UnevenRoundedRectangle(bottomLeadingRadius: 2, bottomTrailingRadius: 2).fill(.black)
                    .frame(width: 16, height: 6).offset(x: 34)
                Mark(x: 58, y: 1, width: 16, height: 5, fill: accent.fill)
                row(14, raised: true)
                row(25)
                row(36)
            case .menu:
                row(8)
                row(19, raised: true)
                Mark(x: 65, y: 21, width: 6, height: 3, fill: Palette.secondaryText)
                Mark(x: 54, y: 25, width: 22, height: 16, fill: Palette.sidebar, radius: 2, line: true)
            }
        }
    }

    private enum Action {
        case none, full, short
    }

    @ViewBuilder
    private func row(_ y: CGFloat, raised: Bool = false, action: Action = .none) -> some View {
        Mark(x: 8, y: y, width: 68, height: 7, fill: raised ? Palette.sidebar : Palette.window, line: true)
        switch action {
        case .none: EmptyView()
        case .full: Mark(x: 56, y: y + 1, width: 16, height: 5, fill: accent.fill)
        case .short: Mark(x: 64, y: y + 1, width: 8, height: 5, fill: accent.fill)
        }
    }
}

// MARK: Live activities

/// The live activities that can be turned off, and a sample of each for the preview.
enum LiveActivityKind: String, CaseIterable, Identifiable {
    case music, trackPeek, timer, levels, charging, lowBattery, events, devices
    case micMuted, countdowns, downloads, focusMode
    case notifications, keepAwake
    case scripts, agents, usage, ci

    var id: String { rawValue }

    var title: String {
        switch self {
        case .music: "Now playing"
        case .trackPeek: "Track changes"
        case .timer: "Focus timer"
        case .levels: "Volume & brightness"
        case .charging: "Charging"
        case .lowBattery: "Low battery"
        case .events: "Upcoming events"
        case .devices: "Bluetooth devices"
        case .micMuted: "Muted microphone"
        case .countdowns: "Timers"
        case .downloads: "Downloads"
        case .focusMode: "Focus"
        case .notifications: "Notifications"
        case .keepAwake: "Keep Awake"
        case .scripts: "Script progress"
        case .agents: "Claude Code"
        case .usage: "Claude usage"
        case .ci: "CI runs"
        }
    }

    var detail: String {
        switch self {
        case .music: "Artwork and an equalizer while music plays"
        case .trackPeek: "The song's name when the track changes"
        case .timer: "A countdown while the timer runs"
        case .levels: "A meter as you change them"
        case .charging: "The battery level when you plug in"
        case .lowBattery: "For the Mac and Bluetooth devices"
        case .events: "Five minutes before they start"
        case .devices: "When one connects, with its battery"
        case .micMuted: "A red badge while the mic is muted"
        case .countdowns: "Named timers and the stopwatch from the Focus section"
        case .downloads: "Progress as a file downloads, and a notice when it's done"
        case .focusMode: "Your Focus's symbol while one is on, and a notice when it changes"
        case .notifications: "Messages, Mail, Slack and more as they arrive"
        case .keepAwake: "A cup while the Mac is being kept awake"
        case .scripts: "A line under the notch while a script reports its progress"
        case .agents: "Your sessions, and tool calls waiting for an answer"
        case .usage: "A ring in the glance, and a heads-up at 80%"
        case .ci: "GitHub Actions on your branch, through to pass or fail"
        }
    }

    var symbol: String {
        switch self {
        case .music: "music.note"
        case .trackPeek: "music.note.list"
        case .timer: "timer"
        case .levels: "speaker.wave.2.fill"
        case .charging: "bolt.fill"
        case .lowBattery: "battery.25percent"
        case .events: "calendar"
        case .devices: "airpodspro"
        case .micMuted: "mic.slash.fill"
        case .countdowns: "hourglass"
        case .downloads: "arrow.down.circle.fill"
        case .focusMode: "moon.fill"
        case .notifications: "bell.badge.fill"
        case .keepAwake: "cup.and.saucer.fill"
        case .scripts: "terminal.fill"
        case .agents: "sparkles"
        case .usage: "gauge.with.dots.needle.67percent"
        case .ci: "checkmark.seal.fill"
        }
    }

    var tint: Color {
        switch self {
        case .music: Palette.magenta
        case .trackPeek: Palette.lavender
        case .timer: PomodoroTimer.Phase.focus.color
        case .levels: Color(red: 0.36, green: 0.56, blue: 1.0)
        case .charging: .green
        case .lowBattery: .red
        case .events: .orange
        case .devices: .teal
        case .micMuted: .red
        case .countdowns: TimerStore.tint
        case .downloads: DownloadMonitor.tint
        case .focusMode: .indigo
        case .notifications: .indigo
        case .keepAwake: .orange
        case .scripts: .mint
        case .agents: Palette.lavender
        case .usage: Palette.lavender
        case .ci: .green
        }
    }

    @MainActor
    var setting: ReferenceWritableKeyPath<AppSettings, Bool> {
        switch self {
        case .music: \.liveMusic
        case .trackPeek: \.trackPeek
        case .timer: \.liveTimer
        case .levels: \.liveHUD
        case .charging: \.liveCharging
        case .lowBattery: \.lowBatteryAlerts
        case .events: \.liveEvents
        case .devices: \.liveDevices
        case .micMuted: \.liveMicMuted
        case .countdowns: \.liveCountdowns
        case .downloads: \.liveDownloads
        case .focusMode: \.liveFocus
        case .notifications: \.liveNotifications
        case .keepAwake: \.liveKeepAwake
        case .scripts: \.liveScripts
        case .agents: \.liveAgents
        case .usage: \.liveUsage
        case .ci: \.liveCI
        }
    }

    /// The song's name only shows while Now playing is on.
    @MainActor
    func isShown(with settings: AppSettings) -> Bool {
        settings[keyPath: setting] && (self != .trackPeek || settings.liveMusic)
    }

    var sample: ClosedActivity {
        switch self {
        case .music: .music
        case .trackPeek: .trackPeek
        case .timer: .timer
        case .levels: .notice(LiveNotice(key: "volume", symbol: "speaker.wave.2.fill", tint: .white, kind: .meter(0.62)))
        case .charging: .notice(LiveNotice(key: "power", symbol: "bolt.fill", tint: .green, text: "82%"))
        case .lowBattery:
            .notice(LiveNotice(key: "power", symbol: "battery.25percent", tint: .red, text: "10%",
                               detail: "Low battery. Plug in soon."))
        case .events: .notice(LiveNotice(key: "event", symbol: "calendar", tint: .orange, text: "in 5m", detail: "Design review"))
        case .devices:
            .notice(LiveNotice(key: "device", symbol: "airpodspro", tint: .white, text: "80%", detail: "AirPods Pro connected"))
        case .notifications: .notice(NotificationPeek.sample())
        case .usage:
            .notice(LiveNotice(key: "usage", symbol: Self.usage.symbol, tint: .orange, text: "Claude usage",
                               detail: "84% of your 5 hours"))
        case .micMuted, .keepAwake, .agents: .idle
        case .countdowns: .countdown(Self.sampleCountdown)
        case .downloads: .download
        case .focusMode: .idle
        case .scripts: .script(ScriptActivity(key: "deploy", percent: 62))
        case .ci: .ci(Self.sampleRun)
        }
    }

    private static let sampleRun = CIRun(id: 1, repository: "acme/app", branch: "main", workflow: "Build",
                                         url: URL(string: "https://github.com")!)
    private static let sampleCountdown = Countdown(id: UUID(), name: "Tea", duration: 240, pausedRemaining: 221)

    /// A glyph at the end of the right ear, for the activities that only ever show as one.
    var sampleSecondary: CompactActivity? {
        switch self {
        case .micMuted: .micMuted
        case .focusMode: .focus(FocusMode(id: "sample", name: "Do Not Disturb", symbol: "moon.fill", tint: .indigo))
        case .keepAwake: .keepAwake
        case .agents: .agentsWaiting(2)
        default: nil
        }
    }
}

struct ActivitySettings: View {
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var focus = FocusMonitor.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let options = [
        SwitchOption(title: "Two at once", detail: "A second activity as a small glyph at the end of the right ear",
                     symbol: "circle.grid.2x1.right.filled", tint: Palette.lavender, setting: \.liveSecondary),
        SwitchOption(title: "On-air ring", detail: "A thin outline around the notch while a camera or the mic is in use",
                     symbol: "record.circle", tint: .green, setting: \.onAirRing),
        SwitchOption(title: "Mute shortcut", detail: "⌃⌥M mutes and unmutes the mic in every app",
                     symbol: "mic.fill", tint: .orange, setting: \.micShortcut),
        SwitchOption(title: "Downloads to the Tray", detail: "Put each finished download in the Tray",
                     symbol: "tray.and.arrow.down.fill", tint: .teal, setting: \.downloadsToTray),
        SwitchOption(title: "Quiet on calls", detail: "Notices wait while the mic or a camera is in use",
                     symbol: "phone.fill", tint: .green, setting: \.quietOnCalls),
        SwitchOption(title: "Quiet in full screen", detail: "Notices wait while a slideshow or a film fills the screen",
                     symbol: "arrow.up.left.and.arrow.down.right", tint: .indigo, setting: \.quietInFullScreen),
    ]

    /// The activities, then a tile that shows a sample in the real notch.
    private enum Tile: Identifiable {
        case activity(LiveActivityKind)
        case preview

        var id: String {
            switch self {
            case .activity(let kind): kind.rawValue
            case .preview: "preview"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            activities
            if settings.liveNotifications {
                NotificationSettingsSection()
                    .transition(reduceMotion ? AnyTransition.opacity : .opacity.combined(with: .move(edge: .top)))
            }
            EqualizerAndKeysSettings()
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.85),
                   value: settings.liveNotifications)
    }

    @ViewBuilder
    private var activities: some View {
        let onCount = LiveActivityKind.allCases.filter { settings[keyPath: $0.setting] }.count
        VStack(alignment: .leading, spacing: 26) {
            SettingsSection(title: "Show in the closed notch", trailing: "\(onCount) of \(LiveActivityKind.allCases.count) on",
                            footer: "Live activities appear beside the camera without opening the notch. Point at one to see it above.") {
                TileGrid(items: LiveActivityKind.allCases.map(Tile.activity) + [.preview], columns: 3) { tile in
                    switch tile {
                    case .activity(let kind):
                        activityTile(kind)
                    case .preview:
                        ActionTile(title: "Preview", detail: "Show a sample in the notch", symbol: "sparkles") {
                            LiveActivityCenter.shared.post(LiveNotice(key: "preview", symbol: "sparkles", tint: .yellow, text: "Hi!",
                                                                      detail: "This is a live activity"), for: 3)
                        }
                    }
                }
            }
            SettingsSection(title: "Options",
                            footer: "With two at once, the mute badge, a timer, a download, your Focus or the music you're playing keeps a small glyph while something else takes the notch. The ring is green for a camera and orange for the mic.") {
                SwitchGrid(options: options)
            }
        }
    }

    private func activityTile(_ kind: LiveActivityKind) -> some View {
        let needsMusic = kind == .trackPeek && !settings.liveMusic
        let needsDiskAccess = kind == .focusMode && settings.liveFocus && focus.access == .denied
        let detail = needsMusic ? "Needs Now playing" : needsDiskAccess ? "Needs Full Disk Access, under Permissions" : kind.detail
        return SwitchTile(title: kind.title, detail: detail,
                          symbol: kind.symbol, tint: kind.tint, isOn: $settings[dynamicMember: kind.setting])
            .disabled(needsMusic)
            .onHover { inside in
                if inside {
                    navigation.spotlight = kind
                } else if navigation.spotlight == kind {
                    navigation.spotlight = nil
                }
            }
    }
}

// MARK: Sections

/// The Sections page: a switch for each section under the open notch, in the order of their
/// buttons, the widgets in the Widgets section, and the settings of the things sections show.
struct NookSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection(title: "Sections",
                            footer: "Live is always there. Agents shows while Claude Code or another agent is working. The player follows Apple Music and Spotify; macOS keeps other players' Now Playing info private to Apple's own apps.") {
                SettingsCard {
                    SectionRow(tab: .live, detail: "What's going on now, most urgent first")
                    CardDivider()
                    SectionRow(tab: .music, detail: "The player, and lyrics when they're on", isOn: $settings.showMusicTab)
                    CardDivider()
                    SectionRow(tab: .tray, detail: "Files you're working with", isOn: $settings.showTrayTab)
                    CardDivider()
                    SectionRow(tab: .focus, detail: "The focus timer, your timers and reminders", isOn: $settings.showFocusTab)
                    CardDivider()
                    SectionRow(tab: .agents, detail: "Claude Code and your scripts, while they run", isOn: $settings.liveAgents)
                    CardDivider()
                    SectionRow(tab: .stats, detail: "Toggles, sliders and batteries", isOn: $settings.showStatsTab)
                    CardDivider()
                    SectionRow(tab: .clipboard, detail: "What you've copied", isOn: $settings.showClipboardTab)
                    CardDivider()
                    SectionRow(tab: .notes, detail: "Notes in Markdown files", isOn: $settings.showNotesTab)
                    CardDivider()
                    SectionRow(tab: .calendar, detail: "Today's events and reminders", isOn: $settings.showCalendarTab)
                    CardDivider()
                    SectionRow(tab: .home, detail: "A stack of the widgets you pick", isOn: $settings.showWidgetsTab)
                    if settings.showWidgetsTab {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top, spacing: 10) {
                                WidgetSlotPicker(title: "First widget", selection: $settings.homeWidgetA)
                                WidgetSlotPicker(title: "Second widget", selection: $settings.homeWidgetB)
                            }
                            Text("They sit side by side in Widgets. Pick None for one of them to give the other the whole width.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Palette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                        .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.25), value: settings.showWidgetsTab)
            }
            SettingsSection(title: "Lyrics",
                            footer: "Lyrics come from LRCLIB, a free online service. With this on, the title, artist, album and length of each song you play go to lrclib.net a moment after it starts. Nothing is sent while this is off.") {
                SettingsCard {
                    SwitchRow(title: "Show synced lyrics", detail: "The line being sung, under the song's title",
                              symbol: "quote.bubble.fill", tint: .pink, isOn: $settings.showsLyrics)
                    if settings.showsLyrics {
                        CardDivider()
                        SwitchRow(title: "In the closed notch",
                                  detail: settings.closedNotchShows == .activities ? "On a second row under the camera"
                                      : "Only while Closed notch shows is set to Icon and figure",
                                  symbol: "rectangle.topthird.inset.filled", tint: .pink, isOn: $settings.lyricsInClosedNotch)
                    }
                }
            }
            SettingsSection(title: "Calendar") {
                SettingsCard {
                    SwitchRow(title: "Show all-day events", detail: "List them in the Calendar widget",
                              symbol: "sun.max.fill", tint: .orange, isOn: $settings.showAllDayEvents)
                }
                .onChange(of: settings.showAllDayEvents) { CalendarService.shared.reload() }
            }
            SettingsSection(title: "Notes",
                            footer: "Each note is a Markdown file named after its first line. Keep them in iCloud Drive to have them on all your Macs. Leaving Dynotch's own folder takes your notes along; notes in any other folder stay until you bring them.") {
                NotesFolderCard()
            }
            SettingsSection(title: "Weather",
                            footer: "Forecasts come from Open-Meteo. Rain alerts use its 15-minute forecast where there is one, and the hourly forecast elsewhere.") {
                WeatherSettings()
            }
            SettingsSection(title: "World clock", trailing: "\(settings.worldClockCities.count) of \(WorldClockCities.limit)",
                            footer: "Up to four cities in the World clock widget. Click one to take it off.") {
                WorldClockCities()
            }
            SettingsSection(title: "Pinned shortcuts", trailing: "\(settings.pinnedShortcuts.count) of 4",
                            footer: "Pin up to four. They show in the Shortcuts widget.") {
                ShortcutPins()
            }
        }
    }
}

/// A section's switch, with its button's symbol in a badge. Without a binding it's always on.
private struct SectionRow: View {
    let tab: NotchTab
    let detail: String
    var isOn: Binding<Bool>?

    var body: some View {
        if let isOn {
            SwitchRow(title: tab.title, detail: detail, symbol: tab.symbol, tint: Self.tint(tab), isOn: isOn)
        } else {
            HStack(spacing: 12) {
                SymbolBadge(symbol: tab.symbol, tint: Self.tint(tab), size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.title).font(.system(size: 13))
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(Palette.secondaryText)
                }
                Spacer(minLength: 12)
                Text("Always on")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.secondaryText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 48)
            .accessibilityElement(children: .combine)
        }
    }

    /// Each section's badge color, as the sidebar's tell its pages apart.
    static func tint(_ tab: NotchTab) -> Color {
        switch tab {
        case .live: NotchTheme.hex(0x30B158)
        case .music: NotchTheme.hex(0xFF375F)
        case .tray: NotchTheme.hex(0x0FA5B5)
        case .focus: NotchTheme.hex(0xFF453A)
        case .agents: NotchTheme.hex(0xD97757)
        case .stats: NotchTheme.hex(0x2E6BFF)
        case .clipboard: NotchTheme.hex(0x8E8E93)
        case .notes: NotchTheme.hex(0xE0A100)
        case .calendar: NotchTheme.hex(0xFF9F0A)
        case .home: NotchTheme.hex(0x5E5CE6)
        }
    }
}

/// Where notes are kept, and ways to move them.
private struct NotesFolderCard: View {
    @ObservedObject private var store = NotesStore.shared

    var body: some View {
        SettingsCard {
            HStack(spacing: 12) {
                SymbolBadge(symbol: store.isInICloud ? "icloud.fill" : "folder.fill", tint: store.isInICloud ? .blue : .yellow,
                            size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.isUsingDefaultFolder ? "Dynotch's folder" : FileManager.default.displayName(atPath: store.folder.path))
                        .font(.system(size: 13, weight: .medium))
                    Text(Self.describe(store.folder))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 12)
                Text(store.notes.filter(\.isOnDisk).count == 1 ? "1 note" : "\(store.notes.filter(\.isOnDisk).count) notes")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.secondaryText)
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            CardDivider()
            // On two lines when a custom folder brings all four buttons.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    folderButtons
                    Spacer(minLength: 0)
                    showInFinder
                }
                FlowLayout(spacing: 8) {
                    folderButtons
                    showInFinder
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            if let left = store.leftBehind {
                CardDivider()
                leftBehind(left)
            }
        }
    }

    /// Where the notes could go instead.
    @ViewBuilder
    private var folderButtons: some View {
        CapsuleButton(title: "Choose Folder…", symbol: "folder") {
            if let folder = FileActions.chooseFolder(prompt: "Keep Notes Here") { store.useFolder(folder) }
        }
        if let iCloud = store.iCloudFolder, !store.isInICloud {
            CapsuleButton(title: "Use iCloud Drive", symbol: "icloud") { store.useFolder(iCloud) }
        }
        if !store.isUsingDefaultFolder {
            CapsuleButton(title: "Use Dynotch's Folder", symbol: "arrow.uturn.backward") { store.useFolder(nil) }
        }
    }

    private var showInFinder: some View {
        CapsuleButton(title: "Show in Finder", symbol: "arrow.up.forward") { NSWorkspace.shared.open(store.folder) }
    }

    /// Where the notes went, right after leaving the folder that kept them: the one in use starts
    /// out without them, which looks as if they've gone.
    private func leftBehind(_ left: NotesStore.LeftBehind) -> some View {
        HStack(spacing: 12) {
            SymbolBadge(symbol: "note.text", tint: .orange, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(left.count == 1 ? "1 note stayed behind" : "\(left.count) notes stayed behind")
                    .font(.system(size: 13, weight: .medium))
                Text("In \(Self.describe(left.folder))."
                    + (NotesStore.isInICloud(left.folder) ? " Bringing notes here takes them off your other Macs." : ""))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            CapsuleButton(title: "Switch Back", symbol: "arrow.uturn.backward") { store.useFolder(left.folder) }
            CapsuleButton(title: left.count == 1 ? "Bring It Here" : "Bring Them Here", kind: .prominent) {
                store.bringLeftBehind()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    /// "iCloud Drive › Dynotch Notes", or the path with ~ for the home folder.
    private static func describe(_ folder: URL) -> String {
        let drive = "/Library/Mobile Documents/com~apple~CloudDocs"
        if let range = folder.path.range(of: drive) {
            let rest = folder.path[range.upperBound...].split(separator: "/").joined(separator: " › ")
            return rest.isEmpty ? "iCloud Drive" : "iCloud Drive › " + rest
        }
        return (folder.path as NSString).abbreviatingWithTildeInPath
    }
}

/// Where the Weather widget looks, which units it uses, and rain alerts.
private struct WeatherSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var weather = WeatherService.shared
    @ViewState private var query = ""
    @ViewState private var results: [WeatherService.Place] = []
    @ViewState private var isSearching = false
    @ViewState private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsCard {
                SwitchRow(title: "Use my location", detail: locationDetail, symbol: "location.fill", tint: .blue,
                          isOn: Binding(get: { settings.weatherUsesLocation }, set: { isOn in
                    settings.weatherUsesLocation = isOn
                    if isOn { weather.requestLocationAccess() }
                }))
                if !settings.weatherUsesLocation {
                    CardDivider()
                    cityRow
                    ForEach(results) { place in
                        CardDivider()
                        PlaceRow(place: place) {
                            weather.choose(place)
                            searchTask?.cancel()
                            query = ""
                            results = []
                        }
                    }
                    if !isSearching, results.isEmpty, query.trimmingCharacters(in: .whitespaces).count >= 2 {
                        CardDivider()
                        Text("No places found")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.secondaryText)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                }
            }
            unitsCard
            SettingsCard {
                SwitchRow(title: "Rain alerts", detail: "A heads-up in the closed notch when rain is about to start",
                          symbol: "cloud.rain.fill", tint: .cyan, isOn: $settings.rainAlerts)
            }
        }
        .onChange(of: query) { search() }
    }

    private var locationDetail: String {
        guard settings.weatherUsesLocation else { return "Instead of a city, use where this Mac is" }
        switch weather.locationAccess {
        case .notDetermined: return "Waiting for Location Services"
        case .denied, .restricted: return "Location Services is off for Dynotch. Allow it in System Settings."
        default: return weather.placeName.isEmpty ? "Finding where you are…" : "Now in \(weather.placeName)"
        }
    }

    private var cityRow: some View {
        HStack(spacing: 12) {
            SymbolBadge(symbol: "building.2.fill", tint: .indigo, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("City")
                    .font(.system(size: 13, weight: .medium))
                Text(settings.weatherPlace.isEmpty ? "None yet" : settings.weatherPlace)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search for a city", text: $query, prompt: Text(""))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .fieldPlaceholder("Search for a city", isEmpty: query.isEmpty, font: .system(size: 12.5),
                                      color: Palette.secondaryText)
                if isSearching {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 11)
            .frame(width: 240, height: 28)
            .background(FieldWell())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var unitsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Temperature")
                .font(.system(size: 13, weight: .semibold))
                .padding(.leading, 2)
                .accessibilityHidden(true)
            HStack(spacing: 6) {
                ForEach(TemperatureUnits.allCases) { units in
                    ChoiceChip(title: title(for: units), symbol: symbol(for: units), isSelected: settings.weatherUnits == units) {
                        settings.weatherUnits = units
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Temperature")
    }

    private func title(for units: TemperatureUnits) -> String {
        switch units {
        case .system: WeatherService.systemUsesFahrenheit ? "Like the system (°F)" : "Like the system (°C)"
        case .celsius: "Celsius"
        case .fahrenheit: "Fahrenheit"
        }
    }

    private func symbol(for units: TemperatureUnits) -> String {
        switch units {
        case .system: "gearshape"
        case .celsius: "degreesign.celsius"
        case .fahrenheit: "degreesign.fahrenheit"
        }
    }

    /// Searches as you type, once you pause.
    private func search() {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let found = await WeatherService.search(text)
            guard !Task.isCancelled else { return }
            results = found
            isSearching = false
        }
    }
}

/// A city found by the weather search.
private struct PlaceRow: View {
    let place: WeatherService.Place
    let action: () -> Void
    @ViewState private var hovering = false
    @Environment(\.windowAccent) private var accent

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(accent.color)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(place.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    if !place.region.isEmpty {
                        Text(place.region)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.secondaryText)
                    }
                }
                Spacer(minLength: 12)
                Text("Use")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent.color)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            // Rounded and inset, so on the last result it stays inside the card's corner.
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.wash.opacity(hovering ? 1 : 0))
                .padding(.horizontal, 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(place.region.isEmpty ? place.name : "\(place.name), \(place.region)")
        .accessibilityHint("Shows the weather for this place")
    }
}

/// Picks the widget for one of the two places beside the player.
private struct WidgetSlotPicker: View {
    let title: String
    @Binding var selection: HomeWidget

    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.leading, 2)
                .accessibilityHidden(true)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(HomeWidget.allCases) { widget in
                    ChoiceChip(title: widget.title, symbol: widget.symbol, isSelected: selection == widget) {
                        selection = widget
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // It sits in the Widgets row's card, so it's set into it rather than raised from it.
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.window)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.stroke)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

private struct ShortcutPins: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var shortcuts = ShortcutsService.shared

    var body: some View {
        // Pinned shortcuts that no longer exist stay listed, so they can be unpinned.
        let names = shortcuts.all + settings.pinnedShortcuts.filter { !shortcuts.all.contains($0) }
        Group {
            if names.isEmpty {
                Text("No shortcuts found.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                FlowLayout(spacing: 7) {
                    ForEach(names, id: \.self) { name in
                        let isPinned = settings.pinnedShortcuts.contains(name)
                        PinChip(title: name, isPinned: isPinned) {
                            if isPinned {
                                settings.pinnedShortcuts.removeAll { $0 == name }
                            } else {
                                settings.pinnedShortcuts.append(name)
                            }
                        }
                        .disabled(!isPinned && settings.pinnedShortcuts.count >= 4)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
        .task { await shortcuts.reload() }
    }
}

/// The cities in the World clock widget, and a field to add one by name. It's all on the Mac: a city
/// is either in `WorldTime`'s table or it isn't.
private struct WorldClockCities: View {
    static let limit = 4

    @ObservedObject private var settings = AppSettings.shared
    @ViewState private var draft = ""
    @ViewState private var isUnknown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 7) {
                ForEach(settings.worldClockCities, id: \.self) { city in
                    PinChip(title: city, isPinned: true) { settings.worldClockCities.removeAll { $0 == city } }
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Add a city", text: $draft, prompt: Text(""))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .fieldPlaceholder("Add a city", isEmpty: draft.isEmpty, font: .system(size: 12.5), color: Palette.secondaryText)
                    .onSubmit(add)
                if isUnknown {
                    Text("No such city here")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.secondaryText)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(FieldWell())
            .opacity(settings.worldClockCities.count < Self.limit ? 1 : 0.4)
            .disabled(settings.worldClockCities.count >= Self.limit)
            .onChange(of: draft) { isUnknown = false }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
    }

    private func add() {
        guard let place = WorldTime.place(draft), !place.isInitials else {
            isUnknown = !draft.isEmpty
            return
        }
        draft = ""
        if !settings.worldClockCities.contains(place.name) { settings.worldClockCities.append(place.name) }
    }
}

private struct PinChip: View {
    let title: String
    let isPinned: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.windowAccent) private var accent
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let shape = theme.controlShape
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 9.5, weight: .bold))
                Text(title)
                    .font(.system(size: 12, weight: isPinned ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isPinned ? accent.onFill : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(shape.fill(isPinned ? accent.fill : Palette.wash))
            .contentShape(shape)
        }
        .buttonStyle(TileButtonStyle(cornerRadius: theme.radius))
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(title)
        .accessibilityValue(isPinned ? "Pinned" : "Not pinned")
        .accessibilityAddTraits(.isToggle)
    }
}

/// An app's icon from its bundle ID, or a symbol if the app isn't installed.
struct AppIconView: View {
    let bundleID: String
    let fallback: String
    let side: CGFloat

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: IconCache.icon(forFile: url.path, side: side))
                .resizable()
                .frame(width: side, height: side)
                .accessibilityHidden(true)
        } else {
            SymbolBadge(symbol: fallback, tint: .gray, size: side * 0.85)
        }
    }
}

// MARK: Tray

struct TraySettings: View {
    @ObservedObject private var tray = TrayStore.shared
    @ObservedObject private var settings = AppSettings.shared

    private let options = [
        SwitchOption(title: "Open on drag", detail: "Open the tray when files are dragged toward the notch",
                     symbol: "arrow.down.to.line", tint: .teal, setting: \.trayOpensOnDrag),
        SwitchOption(title: "Keep copies", detail: "The tray keeps its own copy of every dropped file",
                     symbol: "doc.on.doc.fill", tint: Color(red: 0.36, green: 0.56, blue: 1.0), setting: \.trayCopiesFiles),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            SettingsSection(title: "Dropping files",
                            footer: "With copies, the originals can be moved or deleted and the tray keeps its own. Copies go to the Trash when you remove them.") {
                SwitchGrid(options: options)
            }
            SettingsSection(title: "Screenshots",
                            footer: "Dynotch watches the folder the Screenshot app saves to: \(ScreenshotWatcher.folderNames). Its own captures are saved there too, named like macOS's. In the editor, drag out a region or click for the whole display, mark it up, then copy, save, add to the tray or pin it, or record it.") {
                SettingsCard {
                    SwitchRow(title: "Add screenshots to the tray", detail: "New screenshots and screen recordings show up here",
                              symbol: "camera.viewfinder", tint: .orange, isOn: $settings.screenshotsToTray)
                    CardDivider()
                    SwitchRow(title: "Capture with ⌃⌥S", detail: "Freeze the screen, select a region and mark it up. Also in the menu bar menu.",
                              symbol: "rectangle.dashed.badge.record", tint: .purple, isOn: $settings.captureShortcut)
                    CardDivider()
                    SwitchRow(title: "Shutter sound", detail: "The Screenshot app's click when a capture is taken",
                              symbol: "speaker.wave.2.fill", tint: .teal, isOn: $settings.shutterSound)
                    CardDivider()
                    CaptureActionRow()
                    CardDivider()
                    RecordFormatRow()
                }
            }
            SettingsSection(title: "Tidying",
                            footer: "Screenshots and downloads leave after this long. Their files stay where they are. Pin one from its right-click menu to keep it; anything you put in the Tray yourself stays until you remove it.") {
                SettingsCard { TrayKeepsRow() }
            }
            SettingsSection(title: "In the tray", footer: "Click an item and press Space to preview it, as in Finder. The arrow keys move between items.") {
                HStack(spacing: 16) {
                    FileStack(urls: Array(tray.urls.prefix(4)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tray.items.count == 1 ? "1 item" : "\(tray.items.count) items")
                            .font(.system(size: 20, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText(value: Double(tray.items.count)))
                        Text(tray.items.isEmpty ? "Drop files on the notch to park them here." : "Parked in the notch for later.")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 10)
                    CapsuleButton(title: "Show Folder", symbol: "folder") { NSWorkspace.shared.open(tray.folder) }
                    CapsuleButton(title: "Clear Tray", symbol: "trash", kind: .destructive) { tray.clear() }
                        .disabled(tray.items.isEmpty)
                }
                .padding(14)
                .background(CardBackground())
            }
            ClipboardSettings()
        }
    }
}

/// How long screenshots and downloads stay in the Tray.
private struct TrayKeepsRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 12) {
            SymbolBadge(symbol: "clock.arrow.circlepath", tint: .teal, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("Keep screenshots and downloads")
                    .font(.system(size: 13, weight: .medium))
                Text("What arrives by itself leaves by itself")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.secondaryText)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                ForEach(TrayRetention.allCases) { choice in
                    ChoiceChip(title: choice.title, symbol: choice.symbol, isSelected: settings.trayKeeps == choice) {
                        settings.trayKeeps = choice
                    }
                    .fixedSize()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

/// What Return does in the capture editor: copy, save, or both.
private struct CaptureActionRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 12) {
            SymbolBadge(symbol: "return", size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("After capture")
                    .font(.system(size: 13, weight: .medium))
                Text("What Return does once a region is selected")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.secondaryText)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                ForEach(CaptureAction.allCases) { action in
                    ChoiceChip(title: action.title, symbol: action.symbol, isSelected: settings.captureAction == action) {
                        settings.captureAction = action
                    }
                    .fixedSize()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

/// What Record makes in the capture editor, which the editor's toolbar sets too.
private struct RecordFormatRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 12) {
            SymbolBadge(symbol: "record.circle", tint: .red, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("Record as")
                    .font(.system(size: 13, weight: .medium))
                Text("What V makes of a region: no sound, in either")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.secondaryText)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                ForEach(RecordFormat.allCases) { format in
                    ChoiceChip(title: format.title, symbol: format.symbol, isSelected: settings.recordFormat == format) {
                        settings.recordFormat = format
                    }
                    .fixedSize()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

/// A few file icons fanned out like a hand of cards.
private struct FileStack: View {
    let urls: [URL]

    var body: some View {
        ZStack {
            if urls.isEmpty {
                SymbolBadge(symbol: "tray", isActive: false, size: 44)
            }
            ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                let offset = Double(index) - Double(urls.count - 1) / 2
                Image(nsImage: IconCache.icon(forFile: url.path, side: 40))
                    .resizable()
                    .frame(width: 40, height: 40)
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                    .rotationEffect(.degrees(offset * 9))
                    .offset(x: offset * 13, y: abs(offset) * 2)
            }
        }
        .frame(width: 78, height: 50)
        .accessibilityHidden(true)
    }
}

// MARK: Focus timer

struct FocusSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    private let behavior = [
        SwitchOption(title: "Auto-start", detail: "Start the next phase automatically", symbol: "forward.fill",
                     tint: PomodoroTimer.Phase.shortBreak.color, setting: \.autoStartNextPhase),
        SwitchOption(title: "Sound", detail: "Play a sound when a phase or a named timer ends", symbol: "bell.fill",
                     tint: .orange, setting: \.timerSound),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            SettingsSection(title: "Durations", trailing: "A round takes \(Self.roundLength(settings))") {
                HStack(spacing: 10) {
                    NumberDial(title: "Focus", value: $settings.focusMinutes, range: 5...120, step: 5, unit: "min",
                               tint: PomodoroTimer.Phase.focus.color)
                    NumberDial(title: "Short break", value: $settings.shortBreakMinutes, range: 1...30, unit: "min",
                               tint: PomodoroTimer.Phase.shortBreak.color)
                    NumberDial(title: "Long break", value: $settings.longBreakMinutes, range: 5...60, step: 5, unit: "min",
                               tint: PomodoroTimer.Phase.longBreak.color)
                    NumberDial(title: "Long break after", value: $settings.sessionsPerRound, range: 2...8,
                               unit: "sessions")
                }
            }
            SettingsSection(title: "Behavior") {
                SwitchGrid(options: behavior)
            }
            SettingsSection(title: "Turn on a Focus",
                            footer: "macOS doesn't let apps turn a Focus on, so use a Shortcut with a Set Focus action in it. "
                                + "The end runs however a session ends, unless Dynotch quits first.") {
                SettingsCard {
                    SessionShortcutRow(title: "When a session starts", symbol: "play.fill", selection: $settings.focusStartShortcut)
                    CardDivider()
                    SessionShortcutRow(title: "When it ends", symbol: "stop.fill", selection: $settings.focusEndShortcut)
                }
            }
        }
    }

    /// Focus sessions, the short breaks between them and the long break at the end: "2 h 10 min".
    static func roundLength(_ settings: AppSettings) -> String {
        let sessions = settings.sessionsPerRound
        let minutes = sessions * settings.focusMinutes + (sessions - 1) * settings.shortBreakMinutes + settings.longBreakMinutes
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}

/// Picks the Shortcut for one end of a focus session.
private struct SessionShortcutRow: View {
    let title: String
    let symbol: String
    @Binding var selection: String
    @ObservedObject private var shortcuts = ShortcutsService.shared
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        HStack(spacing: 12) {
            SymbolBadge(symbol: symbol, tint: .pink, isActive: !selection.isEmpty, size: 26)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .accessibilityHidden(true)
            Spacer(minLength: 12)
            Picker(title, selection: $selection) {
                Text("None").tag("")
                // One that's since been deleted stays listed, so it can be seen and changed.
                ForEach(shortcuts.all + (selection.isEmpty || shortcuts.all.contains(selection) ? [] : [selection]), id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .task {
            if !isSnapshot { await shortcuts.reload() }
        }
    }
}

// MARK: About

struct AboutSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var focus = FocusMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(spacing: 14) {
                DynotchLogo(size: 96)
                VStack(spacing: 3) {
                    Text("Dynotch")
                        .font(.system(size: 26, weight: .bold))
                    Text("Version \(UpdateChecker.currentVersion)")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Palette.secondaryText)
                }
                Text("Music, files, your calendar, a focus timer and more, one hover away.")
                    .font(.system(size: 13))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                Text("Inspired by NotchNook and MacNotch.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.secondaryText)
                CapsuleButton(title: "Welcome Tour", symbol: "sparkles") { WelcomeWindowController.shared.show() }
                    .padding(.top, 4)
            }
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity)
            .background(CardBackground())

            SettingsSection(title: "Updates") {
                UpdateSettings()
            }

            SettingsSection(title: "Keyboard") {
                SettingsCard {
                    ShortcutRow(keys: ["⌃", "⌥", "N"], spokenKeys: "Control Option N", action: settings.globalShortcut
                        ? "Open or close the notch" : "Open or close the notch (turned off in General)")
                    CardDivider()
                    ShortcutRow(keys: ["⌃", "⌥", "M"], spokenKeys: "Control Option M", action: settings.micShortcut
                        ? "Mute or unmute the microphone" : "Mute or unmute the microphone (turned off in Live Activities)")
                    CardDivider()
                    ShortcutRow(keys: ["⌃", "⌥", "K"], spokenKeys: "Control Option K", action: settings.commandShortcut
                        ? "Open the command field" : "Open the command field (turned off in General)")
                    CardDivider()
                    ShortcutRow(keys: ["⌃", "⌥", "S"], spokenKeys: "Control Option S", action: settings.captureShortcut
                        ? "Capture part of the screen" : "Capture part of the screen (turned off in Tray)")
                    CardDivider()
                    ShortcutRow(keys: ["⌘", "1 – 8"], spokenKeys: "Command 1 to 8", action: "Jump to a page of these settings")
                    CardDivider()
                    ShortcutRow(keys: ["↑", "↓"], spokenKeys: "Up or down arrow",
                                action: "Move through the pages, once the sidebar is selected")
                }
            }

            SettingsSection(title: "Diagnostics",
                            footer: "For when the notch shows the wrong Focus. The report keeps the shape of the Focus settings, their identifiers and times; names and places are left out, so it can be shared.") {
                HStack(spacing: 12) {
                    SymbolBadge(symbol: "moon.fill", tint: .indigo, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Focus report")
                            .font(.system(size: 13, weight: .medium))
                        Text(focus.access == .denied ? "Needs Full Disk Access, under Permissions"
                             : "What the Focus settings hold, and which Focus Dynotch makes of them")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 12)
                    CapsuleButton(title: "Save…", symbol: "square.and.arrow.down") { FocusMonitor.shared.saveReport() }
                        .accessibilityLabel("Save a Focus report")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CardBackground())
            }
        }
    }
}

private struct ShortcutRow: View {
    let keys: [String]
    let spokenKeys: String
    let action: String

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    Keycap(label: key, style: .window)
                }
            }
            .frame(width: 104, alignment: .leading)
            Text(action)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.secondaryText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(spokenKeys): \(action)")
        .accessibilityAddTraits(.isStaticText)
    }
}
