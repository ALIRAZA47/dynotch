import SwiftUI
import UniformTypeIdentifiers

// MARK: Snapshots

private struct SnapshotKey: EnvironmentKey {
    static let defaultValue = false
}

private struct SnapshotDropKey: EnvironmentKey {
    static let defaultValue: SnapshotDrop? = nil
}

extension EnvironmentValues {
    /// Set while rendering `--snapshot` images. ImageRenderer can't draw AppKit-backed views
    /// (scroll views, text editors, drop targets), so a few views swap in plain stand-ins.
    var isSnapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }

    /// Set by a snapshot of files held over the notch: one drop target, whichever SwiftUI shows
    /// first, draws itself targeted.
    var snapshotDrop: SnapshotDrop? {
        get { self[SnapshotDropKey.self] }
        set { self[SnapshotDropKey.self] = newValue }
    }
}

/// A snapshot's one targeted drop, handed to the first drop target that asks for it.
@MainActor
final class SnapshotDrop {
    private var isTaken = false

    func take() -> Bool {
        defer { isTaken = true }
        return !isTaken
    }
}

extension View {
    /// `onDrop`, left out of snapshots.
    func trayDropTarget(isTargeted: Binding<Bool>, perform: @escaping ([NSItemProvider]) -> Bool) -> some View {
        modifier(DropTargetModifier(isTargeted: isTargeted, perform: perform))
    }
}

private struct DropTargetModifier: ViewModifier {
    let isTargeted: Binding<Bool>
    let perform: ([NSItemProvider]) -> Bool
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.snapshotDrop) private var snapshotDrop

    func body(content: Content) -> some View {
        if isSnapshot {
            content.onAppear {
                guard snapshotDrop?.take() == true else { return }
                // Already over it, as the image catches it, rather than on the way in.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { isTargeted.wrappedValue = true }
            }
        } else {
            content.onDrop(of: TrayDrop.types, isTargeted: isTargeted, perform: perform)
        }
    }
}

/// A scroll view without indicators; in snapshots, just its clipped content. A vertical one that
/// `fadesOverflow` fades out along the bottom edge while there's more below, so a row cut short
/// reads as more to come.
struct Scroller<Content: View>: View {
    let axis: Axis.Set
    var fadesOverflow = false
    @ViewBuilder let content: Content
    @Environment(\.isSnapshot) private var isSnapshot

    private static var fade: CGFloat { 16 }

    init(_ axis: Axis.Set, fadesOverflow: Bool = false, @ViewBuilder content: () -> Content) {
        self.axis = axis
        self.fadesOverflow = fadesOverflow
        self.content = content()
    }

    var body: some View {
        let fades = fadesOverflow && axis == .vertical
        if !isSnapshot {
            ScrollView(axis) { content }
                .scrollIndicators(.never)
                .modifier(BottomFade(isEnabled: fades, length: Self.fade))
        } else if fades {
            // Snapshots render in one pass, so a layout decides whether the content runs over.
            OverflowFade(length: Self.fade) {
                content
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
            .clipped()
        } else {
            // Like a scroll view, it takes the room it's offered and lays its content out at full
            // length along the axis, so content that runs over gets cut off rather than widening it.
            Color.clear
                .overlay(alignment: .topLeading) {
                    content.fixedSize(horizontal: axis.contains(.horizontal), vertical: axis.contains(.vertical))
                }
                .clipped()
        }
    }
}

/// Fades a scroll view's bottom edge while some of its content is out of sight below.
private struct BottomFade: ViewModifier {
    let isEnabled: Bool
    let length: CGFloat
    @ViewState private var moreBelow = false

    func body(content: Content) -> some View {
        if #available(macOS 15, *), isEnabled {
            content
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.visibleRect.maxY < geometry.contentSize.height - 1
                } action: { _, isMore in
                    moreBelow = isMore
                }
                .mask {
                    VStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: moreBelow ? length : 0)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: moreBelow)
        } else {
            content
        }
    }
}

/// Its first subview from the top, no taller than the room it's given. When that doesn't fit,
/// the second, an eraser, covers the bottom `length` points.
private struct OverflowFade: Layout {
    let length: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let content = subviews[0].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? content.width, height: min(content.height, proposal.height ?? .infinity))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let content = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: content.height))
        let fade = content.height > bounds.height + 0.5 ? min(length, bounds.height) : 0
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.maxY - fade),
                          proposal: ProposedViewSize(width: bounds.width, height: fade))
    }
}

// MARK: Cards

/// The rounded card every widget sits in, with an optional title row.
struct WidgetCard<Content: View, Accessory: View>: View {
    var title: String?
    var symbol: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(title: String? = nil, symbol: String? = nil,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NotchTheme.titleGap) {
            if let title {
                CardTitle(title: title, symbol: symbol) { accessory }
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(NotchTheme.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(CardSurface())
    }
}

/// A card's title row: a symbol and a name, then a count or buttons on the right.
struct CardTitle<Accessory: View>: View {
    let title: String
    var symbol: String?
    @ViewBuilder var accessory: Accessory
    @Environment(\.notchTheme) private var theme

    init(title: String, symbol: String? = nil, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.symbol = symbol
        self.accessory = accessory()
    }

    var body: some View {
        // The title takes what the accessory leaves. A Spacer would claim half of it, cutting the title short.
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
            }
            Text(title)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(title)
                .accessibilityAddTraits(.isHeader)
            accessory
        }
        .font(NotchFont.label)
        .foregroundStyle(theme.secondary)
        .frame(minHeight: 14)
    }
}

/// A card's frosted pane in the theme's corners, lit along its top edge. Brighter while highlighted.
struct CardSurface: View {
    var isHighlighted = false
    @Environment(\.notchTheme) private var theme

    var body: some View {
        GlassSurface(depth: .pane, shape: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous),
                     isLit: isHighlighted)
            .animation(.notchHighlight, value: isHighlighted)
    }
}

/// A piece of the notch's glass in `shape`, lit from above as `depth` says: its fill, light across
/// its upper part and a specular rim. Nothing in it moves, so it costs nothing once drawn.
struct GlassSurface<S: InsettableShape>: View {
    let depth: GlassDepth
    let shape: S
    var isLit = false
    /// A lens's color spills softly onto the glass around it. Only for the selected tab and a
    /// targeted drop zone; everywhere else the solid face is enough.
    var spills = false
    @Environment(\.notchTheme) private var theme

    var body: some View {
        ZStack {
            if spills, case .lens(let color) = depth {
                shape.fill(color.opacity(0.35))
                    .blur(radius: 6)
                    .allowsHitTesting(false)
            }
            if case .lens = depth {
                // A solid face can't take on more light, so it brightens under the pointer instead.
                shape.fill(theme.fill(depth)).brightness(isLit ? 0.04 : 0)
            } else {
                shape.fill(theme.fill(depth, isLit: isLit))
            }
            if theme.sheen(depth) > 0 {
                shape.fill(sheen)
            }
            shape.strokeBorder(theme.rim(depth, isLit: isLit), lineWidth: 1)
        }
    }

    /// A pane glows softly under the middle of its top edge; smaller glass catches a band of light
    /// across its top half.
    private var sheen: AnyShapeStyle {
        let light = Color.white.opacity(theme.sheen(depth))
        if depth == .pane {
            return AnyShapeStyle(EllipticalGradient(colors: [light, light.opacity(0)], center: .top, endRadiusFraction: 0.85))
        }
        return AnyShapeStyle(LinearGradient(colors: [light, light.opacity(0)], startPoint: .top, endPoint: .center))
    }
}

extension View {
    /// Puts a piece of the notch's glass behind the view. See `GlassSurface`.
    func glass<S: InsettableShape>(_ depth: GlassDepth, in shape: S, isLit: Bool = false) -> some View {
        background(GlassSurface(depth: depth, shape: shape, isLit: isLit))
    }
}

/// A line between the parts of a card, cut into its glass: a dark groove whose lower edge catches
/// the light. Each line is a whole point, so both stay crisp on a 1x display.
struct EtchedDivider: View {
    @Environment(\.notchTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            theme.divider.frame(height: 1)
            theme.dividerLight.frame(height: 1)
        }
        .accessibilityHidden(true)
    }
}

/// What a card shows when there's nothing in it yet: a symbol, a line about it and maybe a button.
struct EmptyState<Action: View>: View {
    let symbol: String
    let message: String
    @ViewBuilder var action: Action
    @Environment(\.notchTheme) private var theme

    init(symbol: String, message: String, @ViewBuilder action: () -> Action = { EmptyView() }) {
        self.symbol = symbol
        self.message = message
        self.action = action()
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(theme.tertiary)
                .frame(height: 22)
            Text(message)
                .font(NotchFont.footnote)
                .foregroundStyle(theme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if Action.self != EmptyView.self {
                action.padding(.top, 2)
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shown inside a widget until the user grants the permission it needs.
struct PermissionPrompt: View {
    let symbol: String
    let message: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        EmptyState(symbol: symbol, message: message) {
            PillButton(title: buttonTitle, action: action)
        }
    }
}

/// A small switch between a card's views, in its title row: Reminders | Notes. The picked one is
/// a raised piece of glass sliding along a track pressed into the card, plain glass as on macOS:
/// the accent is for what's on.
struct CardSegments<Value: Hashable>: View {
    struct Segment {
        var value: Value
        var title: String
        var count: Int?
    }

    @Binding var selection: Value
    let segments: [Segment]
    @Environment(\.notchTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments.indices, id: \.self) { index in
                segment(segments[index])
            }
        }
        .padding(2)
        .glass(.well, in: Capsule())
    }

    private func segment(_ segment: Segment) -> some View {
        let isSelected = segment.value == selection
        return Button {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .notchTab) { selection = segment.value }
        } label: {
            HStack(spacing: 5) {
                Text(segment.title)
                    .font(isSelected ? NotchFont.bodyStrong : NotchFont.body)
                if let count = segment.count {
                    // A step up on the thumb, whose lighter glass would take tertiary under 4.5:1.
                    Text("\(count)")
                        .font(NotchFont.numeric(10.5))
                        .foregroundStyle(isSelected ? theme.secondary : theme.tertiary)
                }
            }
            .foregroundStyle(isSelected ? theme.primary : theme.secondary)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background {
                if isSelected {
                    GlassSurface(depth: .control, shape: Capsule())
                        .matchedGeometryEffect(id: "segment", in: highlight)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.95))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A one-line field in a card, with a plus in front: a new timer, a new reminder. It's pressed into
/// the card like a well, and the accent's light rings it while it has the keyboard.
struct CardField: View {
    let placeholder: String
    @Binding var text: String
    var isInvalid = false
    let onSubmit: () -> Void
    @Environment(\.notchTheme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @FocusState private var isFocused: Bool
    @ViewState private var hovering = false

    var body: some View {
        let shape = Capsule()
        HStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(isFocused ? theme.accent : theme.tertiary)
            if isSnapshot {
                Text(placeholder)
                    .font(NotchFont.body)
                    .foregroundStyle(theme.tertiary)
                    .lineLimit(1)
            } else {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(NotchFont.body)
                    .focused($isFocused)
                    .onSubmit(onSubmit)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .glass(.well, in: shape, isLit: hovering || isFocused)
        .overlay(shape.strokeBorder(isInvalid ? Color.red.opacity(0.75) : theme.accent.opacity(isFocused ? 0.6 : 0)))
        .contentShape(shape)
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .animation(.notchHighlight, value: isFocused)
    }
}

// MARK: Buttons

/// Shrinks a little while pressed. Large targets, like tiles, should shrink less.
struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.88

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// A borderless symbol button. Under the pointer a disc of glass rises behind it.
struct IconButton: View {
    let symbol: String
    var size: CGFloat = 14
    var isActive = false
    var activeColor: Color = .white
    /// How strong the symbol is while it's neither active nor under the pointer. Secondary
    /// controls, like shuffle beside the play button, sit back further.
    var idleOpacity: Double = 0.82
    var help: String?
    let action: () -> Void
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(isActive ? activeColor : theme.primary.opacity(hovering ? 1 : idleOpacity))
                .frame(width: size + 16, height: size + 14)
                .background {
                    if hovering { GlassSurface(depth: .control, shape: Circle()) }
                }
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .help(help ?? "")
    }
}

/// A small symbol button for a card's title row.
struct CardButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            CardButtonLabel(symbol: symbol, hovering: hovering)
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// How a title-row button looks, so a button that opens a menu can match.
struct CardButtonLabel: View {
    var symbol: String?
    var text: String?
    let hovering: Bool
    @Environment(\.notchTheme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            if let text {
                Text(text)
                    .font(NotchFont.numeric(9.5, .bold))
                    .fixedSize()
            }
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
            }
        }
        .foregroundStyle(hovering ? theme.primary : theme.secondary)
        .padding(.horizontal, 3)
        // As tall as the title row; the highlight and the target reach a little past it.
        .frame(minWidth: 20, minHeight: 14)
        .background {
            if hovering { GlassSurface(depth: .control, shape: Capsule()).padding(.vertical, -2) }
        }
        .contentShape(Rectangle().inset(by: -3))
        .animation(.notchHighlight, value: hovering)
    }
}

/// A small capsule of glass with the accent's light in it, or a tint's, and a label in that color.
struct PillButton: View {
    let title: String
    var symbol: String?
    var tint: Color?
    let action: () -> Void
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        let tint = tint ?? theme.accent
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 9.5, weight: .bold))
                }
                Text(title).font(NotchFont.bodyStrong).lineLimit(1)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 11)
            .frame(height: 24)
            .glass(.tint(tint), in: Capsule(), isLit: hovering)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.94))
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
    }
}

/// A key as the keyboard prints it: ⌃ ⌥ K beside the command pill, esc, ↩. Hidden from VoiceOver,
/// as the control or row it sits in already says what the keys do.
struct Keycap: View {
    enum Style {
        /// A small piece of glass on the notch.
        case notch
        /// Pressed into an accent's solid face, in ink, like esc on the open command pill.
        case onLens
        /// In Settings and the welcome tour, following light and dark.
        case window
    }

    let label: String
    var style: Style = .notch
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let side: CGFloat = style == .window ? 24 : 18
        let shape = RoundedRectangle(cornerRadius: style == .window ? 6 : 5, style: .continuous)
        Text(label)
            .font(style == .window ? .system(size: 12, weight: .semibold, design: .rounded) : NotchFont.keycap)
            .foregroundStyle(foreground)
            .padding(.horizontal, style == .window ? 7 : label.count > 1 ? 4 : 0)
            .frame(minWidth: side)
            .frame(height: side)
            .background { face(shape) }
            .accessibilityHidden(true)
    }

    private var foreground: Color {
        switch style {
        case .notch: theme.primary.opacity(0.72)
        case .onLens: theme.onAccent
        case .window: .primary
        }
    }

    @ViewBuilder
    private func face(_ shape: RoundedRectangle) -> some View {
        switch style {
        case .notch:
            GlassSurface(depth: .control, shape: shape)
        case .onLens:
            shape.fill(theme.onAccent.opacity(0.12))
                .overlay(shape.strokeBorder(theme.onAccent.opacity(0.18)))
        case .window:
            shape.fill(Palette.wash)
                .overlay(shape.strokeBorder(Palette.rimGradient))
        }
    }
}

// MARK: Media

/// Album art, or a placeholder note, under a sheet of glass whose top edge catches the light.
/// With a `glow`, the art's color falls on the notch below it, as light through stained glass.
/// Art under 40 points, beside the camera, gets a finer rim and never a glow.
struct ArtworkView: View {
    var image: NSImage?
    var size: CGFloat
    var cornerRadius: CGFloat
    var glow: Color?

    var body: some View {
        if let glow, size >= 40 {
            art.shadow(color: glow.opacity(0.55), radius: size * 0.2, y: size * 0.1)
        } else {
            art
        }
    }

    private var art: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color(white: 0.24), Color(white: 0.14)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        // Finer on the tiny art beside the camera, where a full point would read as a frame.
        .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.4), .white.opacity(0.05)],
                                                   startPoint: .top, endPoint: .bottom),
                                    lineWidth: size >= 40 ? 1 : 0.5))
    }
}

/// The bouncing equalizer next to the notch. With Live equalizer on, the bars follow the music
/// through `AudioLevels`; otherwise, and until sound arrives, the motion is decorative.
struct AudioBars: View {
    var isPlaying: Bool
    var color: Color
    var barCount = 4
    @ObservedObject private var levels = AudioLevels.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        content
            // The tap only runs while some bars are on screen.
            .onAppear { levels.addViewer() }
            .onDisappear { levels.removeViewer() }
    }

    @ViewBuilder
    private var content: some View {
        if isPlaying, let bands = levels.bands {
            barStack { index in
                let band = bands.isEmpty ? 0 : bands[min(bands.count - 1, index * bands.count / barCount)]
                return 0.18 + 0.82 * CGFloat(band)
            }
            .animation(.easeOut(duration: 0.12), value: bands)
        } else if isPlaying && !isSnapshot {
            // Animated from SwiftUI, the bars woke the app on every frame of the display, about
            // 120 times a second. Core Animation runs the same bounce in the window server.
            BouncingBars(color: color, heights: (0..<barCount).map { index in
                (0..<16).map { level(index: index, tick: $0) }
            }, step: reduceMotion ? 0.45 : 0.15)
        } else {
            // Snapshots catch the bars mid-bounce.
            bars(tick: isPlaying ? 1 : nil)
        }
    }

    private func bars(tick: Int?) -> some View {
        barStack { index in level(index: index, tick: tick) }
    }

    /// The bars, each as tall as `height` says, from 0 to 1.
    private func barStack(_ height: @escaping (Int) -> CGFloat) -> some View {
        GeometryReader { proxy in
            HStack(alignment: .center, spacing: proxy.size.width * 0.12) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(color)
                        .frame(height: max(3, proxy.size.height * height(index)))
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func level(index: Int, tick: Int?) -> CGFloat {
        guard let tick else { return 0.22 }
        // A cheap, deterministic hash so every bar moves differently.
        var value = UInt64(truncatingIfNeeded: tick &* 2_654_435_761 &+ index &* 40_503)
        value ^= value >> 13
        value = value &* 0x5bd1e995
        value ^= value >> 15
        let base: [CGFloat] = [0.55, 0.85, 0.7, 0.95, 0.6]
        return 0.25 + CGFloat(value % 1000) / 1000 * base[index % base.count] * 0.75
    }
}

/// `AudioBars`' decorative bounce as Core Animation layers. The window server runs a layer's
/// animation by itself, so the app doesn't wake for each frame.
private struct BouncingBars: NSViewRepresentable {
    let color: Color
    /// Each bar's heights in turn, from 0 to 1. The bounce loops through them.
    let heights: [[CGFloat]]
    /// Seconds from one height to the next.
    let step: TimeInterval

    func makeNSView(context: Context) -> BarsView { BarsView() }

    func updateNSView(_ view: BarsView, context: Context) {
        view.update(color: NSColor(color).cgColor, heights: heights, step: step)
    }

    final class BarsView: NSView {
        private var bars: [CALayer] = []
        private var heights: [[CGFloat]] = []
        private var step: TimeInterval = 0
        /// The size the running animations were made for.
        private var animatedSize = CGSize.zero

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }

        required init?(coder: NSCoder) { nil }

        func update(color: CGColor, heights: [[CGFloat]], step: TimeInterval) {
            if heights.count != bars.count {
                bars.forEach { $0.removeFromSuperlayer() }
                bars = heights.map { _ in CALayer() }
                bars.forEach { layer?.addSublayer($0) }
            }
            // Implicitly animated, so a new artwork color fades in.
            bars.forEach { $0.backgroundColor = color }
            if heights != self.heights || step != self.step {
                self.heights = heights
                self.step = step
                restart()
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { restart() }
        }

        override func layout() {
            super.layout()
            guard bounds.size != animatedSize, !bars.isEmpty, bounds.height > 0 else { return }
            animatedSize = bounds.size
            let count = CGFloat(bars.count)
            let spacing = bounds.width * 0.12
            let width = (bounds.width - spacing * (count - 1)) / count
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (index, bar) in bars.enumerated() {
                let levels = heights[index]
                bar.bounds = CGRect(x: 0, y: 0, width: width, height: max(3, bounds.height * (levels.first ?? 0.22)))
                bar.position = CGPoint(x: CGFloat(index) * (width + spacing) + width / 2, y: bounds.midY)
                bar.cornerRadius = width / 2
                bar.add(bounce(through: levels), forKey: "bounce")
            }
            CATransaction.commit()
        }

        private func restart() {
            animatedSize = .zero
            needsLayout = true
        }

        private func bounce(through levels: [CGFloat]) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: "bounds.size.height")
            // Back to the first height at the end, so the loop doesn't jump.
            animation.values = (levels + levels.prefix(1)).map { max(3, bounds.height * $0) }
            animation.duration = step * Double(levels.count)
            animation.calculationMode = .cubic
            animation.repeatCount = .infinity
            return animation
        }
    }
}

// MARK: Meters

/// A ring that fills clockwise from the top. A `halo` lays a wider, faint copy of the arc under it,
/// light running round a groove, with no blur to redraw as the ring ticks. For a ring that is the
/// live thing itself: the focus dial and the glance's rings.
struct ProgressRing: View {
    var progress: Double
    var color: Color
    var lineWidth: CGFloat = 4
    var halo = false

    var body: some View {
        let end = max(0.001, min(1, progress))
        ZStack {
            Circle().stroke(color.opacity(0.22), lineWidth: lineWidth)
            if halo {
                arc(to: end, color: color.opacity(0.18), lineWidth: lineWidth * 2)
                    .allowsHitTesting(false)
            }
            arc(to: end, color: color, lineWidth: lineWidth)
        }
    }

    private func arc(to end: Double, color: Color, lineWidth: CGFloat) -> some View {
        Circle()
            .trim(from: 0, to: end)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees(-90))
    }
}

/// A short arc turning round a ring, for a download whose size isn't known yet. Core Animation
/// turns it in the window server, so the app doesn't wake for each frame. Snapshots get it at rest.
struct SpinningArc: View {
    var color: Color
    var lineWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSnapshot) private var isSnapshot

    /// How much of the ring the arc covers.
    private static let length = 0.28

    var body: some View {
        if isSnapshot {
            ZStack {
                Circle().stroke(color.opacity(0.22), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: Self.length)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        } else {
            SpinningArcLayers(color: NSColor(color), lineWidth: lineWidth, length: Self.length,
                              period: reduceMotion ? 2.4 : 1.2)
        }
    }
}

/// `SpinningArc` as shape layers: the ring, and the arc on a rotation that repeats.
private struct SpinningArcLayers: NSViewRepresentable {
    let color: NSColor
    let lineWidth: CGFloat
    /// The arc's share of the ring.
    let length: Double
    /// Seconds for one turn.
    let period: TimeInterval

    func makeNSView(context: Context) -> ArcView { ArcView() }

    func updateNSView(_ view: ArcView, context: Context) {
        view.update(color: color, lineWidth: lineWidth, length: length, period: period)
    }

    final class ArcView: NSView {
        private let ring = CAShapeLayer()
        private let arc = CAShapeLayer()
        private var length = 0.0
        private var period: TimeInterval = 0

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for shape in [ring, arc] {
                shape.fillColor = nil
                shape.lineCap = .round
                layer?.addSublayer(shape)
            }
        }

        required init?(coder: NSCoder) { nil }

        /// Only something to look at: clicks go through to the notch.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func update(color: NSColor, lineWidth: CGFloat, length: Double, period: TimeInterval) {
            ring.strokeColor = color.withAlphaComponent(color.alphaComponent * 0.22).cgColor
            arc.strokeColor = color.cgColor
            ring.lineWidth = lineWidth
            arc.lineWidth = lineWidth
            if length != self.length {
                self.length = length
                needsLayout = true
            }
            if period != self.period {
                self.period = period
                turn()
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            turn()
        }

        override func layout() {
            super.layout()
            // Like SwiftUI's Circle: the circle that fits the bounds, stroked along its edge.
            let side = min(bounds.width, bounds.height)
            let radius = side / 2
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let path = CGMutablePath()
            // From the top, clockwise in the view's upward coordinates.
            path.addArc(center: center, radius: radius, startAngle: .pi / 2, endAngle: .pi / 2 - length * 2 * .pi,
                        clockwise: true)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for shape in [ring, arc] { shape.frame = bounds }
            ring.path = CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: side, height: side),
                               transform: nil)
            arc.path = path
            CATransaction.commit()
        }

        private func turn() {
            arc.removeAnimation(forKey: "turn")
            guard window != nil, period > 0 else { return }
            let animation = CABasicAnimation(keyPath: "transform.rotation.z")
            // Negative is clockwise here, as the arc runs.
            animation.fromValue = 0
            animation.toValue = -2 * Double.pi
            animation.duration = period
            animation.repeatCount = .infinity
            arc.add(animation, forKey: "turn")
        }
    }
}

/// A thin meter for the volume and brightness: a groove with no rim, filled with white lit from
/// above, or the given color.
struct LevelBar: View {
    var level: Double
    var color: Color = .white

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.16))
                Capsule()
                    .fill(LinearGradient(colors: [color, color.opacity(0.85)], startPoint: .top, endPoint: .bottom))
                    .frame(width: proxy.size.width * max(0, min(1, level)))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: level)
    }
}
