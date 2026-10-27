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

/// A scroll view without indicators; in snapshots, just its clipped content.
struct Scroller<Content: View>: View {
    let axis: Axis.Set
    @ViewBuilder let content: Content
    @Environment(\.isSnapshot) private var isSnapshot

    init(_ axis: Axis.Set, @ViewBuilder content: () -> Content) {
        self.axis = axis
        self.content = content()
    }

    var body: some View {
        if isSnapshot {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        } else {
            ScrollView(axis) { content }
                .scrollIndicators(.never)
        }
    }
}

// MARK: Building blocks

/// The rounded card every widget sits in.
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
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                HStack(spacing: 5) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 9.5, weight: .bold))
                    }
                    Text(title.uppercased())
                        .font(.system(size: 9.5, weight: .bold))
                        .tracking(0.6)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    accessory
                }
                .foregroundStyle(Color.notchTertiary)
                .frame(height: 14)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.notchCard))
    }
}

/// Shrinks a little while pressed.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
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
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(isActive ? activeColor : Color.white.opacity(hovering ? 1 : 0.82))
                .frame(width: size + 16, height: size + 14)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { hovering = $0 }
        .help(help ?? "")
    }
}

/// A small capsule button with a label.
struct PillButton: View {
    let title: String
    var symbol: String?
    var tint: Color = .white
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                }
                Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(tint.opacity(hovering ? 0.24 : 0.14)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { hovering = $0 }
    }
}

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

/// The bouncing equalizer next to the notch. The motion is decorative: macOS
/// doesn't let apps tap another app's audio without screen-recording permission.
struct AudioBars: View {
    var isPlaying: Bool
    var color: Color
    var barCount = 4

    var body: some View {
        if isPlaying {
            TimelineView(.periodic(from: .now, by: 0.15)) { context in
                let tick = Int(context.date.timeIntervalSinceReferenceDate / 0.15)
                bars(tick: tick)
                    .animation(.spring(response: 0.2, dampingFraction: 0.7), value: tick)
            }
        } else {
            bars(tick: nil)
        }
    }

    private func bars(tick: Int?) -> some View {
        GeometryReader { proxy in
            HStack(alignment: .center, spacing: proxy.size.width * 0.12) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(color)
                        .frame(height: max(3, proxy.size.height * level(index: index, tick: tick)))
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

/// Shown inside a widget until the user grants the permission it needs.
struct PermissionPrompt: View {
    let symbol: String
    let message: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.notchSecondary)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Color.notchSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            PillButton(title: buttonTitle, action: action)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
