import SwiftUI
import UniformTypeIdentifiers

// MARK: Snapshots

private struct SnapshotKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set while rendering `--snapshot` images. ImageRenderer can't draw AppKit-backed views
    /// (scroll views, text editors, drop targets), so a few views swap in plain stand-ins.
    var isSnapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
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

    func body(content: Content) -> some View {
        if isSnapshot {
            content
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
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

/// A card's title row: a symbol and a name in small capitals, then a count or buttons on the right.
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
            Text(title.uppercased())
                .tracking(0.6)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(title)
                .accessibilityAddTraits(.isHeader)
            accessory
        }
        .font(NotchFont.label)
        .foregroundStyle(theme.tertiary)
        .frame(minHeight: 14)
    }
}

/// A card's fill and the hairline around it, in the theme's corners. Lighter while highlighted.
struct CardSurface: View {
    var isHighlighted = false
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
        shape.fill(isHighlighted ? theme.cardHover : theme.card)
            .overlay(shape.strokeBorder(theme.cardStroke))
            .animation(.notchHighlight, value: isHighlighted)
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

/// A one-line field in a card, with a plus in front: a new timer, a new reminder.
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
        let shape = RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
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
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(shape.fill(hovering || isFocused ? theme.controlHover : theme.control))
        .overlay(shape.strokeBorder(isInvalid ? Color.red.opacity(0.75) : theme.accent.opacity(isFocused ? 0.55 : 0)))
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

/// A borderless symbol button with a hover highlight.
struct IconButton: View {
    let symbol: String
    var size: CGFloat = 14
    var isActive = false
    var activeColor: Color = .white
    var help: String?
    let action: () -> Void
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(isActive ? activeColor : theme.primary.opacity(hovering ? 1 : 0.82))
                .frame(width: size + 16, height: size + 14)
                .background(Circle().fill(hovering ? theme.controlHover : .clear))
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
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(hovering ? theme.control : .clear).padding(.vertical, -2))
        .contentShape(Rectangle().inset(by: -3))
        .animation(.notchHighlight, value: hovering)
    }
}

/// A small capsule button with a label, in the accent color unless it's given a tint.
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
            .background(Capsule().fill(tint.opacity(hovering ? 0.26 : 0.16)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.94))
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
    }
}

// MARK: Media

/// Album art, or a placeholder note.
struct ArtworkView: View {
    var image: NSImage?
    var size: CGFloat
    var cornerRadius: CGFloat
    var glow: Color?

    var body: some View {
        ZStack {
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
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: (glow ?? .clear).opacity(0.5), radius: size * 0.16)
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

struct ProgressRing: View {
    var progress: Double
    var color: Color
    var lineWidth: CGFloat = 4

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.22), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// A thin horizontal meter, used for the volume and brightness HUD.
struct LevelBar: View {
    var level: Double
    var color: Color = .white

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2))
                Capsule()
                    .fill(color)
                    .frame(width: proxy.size.width * max(0, min(1, level)))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: level)
    }
}
