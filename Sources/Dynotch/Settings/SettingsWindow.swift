import AppKit
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, appearance, activities, nook, tray, focus, permissions, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .activities: "Live Activities"
        case .nook: "Nook & Widgets"
        case .tray: "Tray"
        case .focus: "Focus Timer"
        case .permissions: "Permissions"
        case .about: "About"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "How the notch opens, and where it shows up."
        case .appearance: "The size and finish of the open notch."
        case .activities: "What the closed notch shows beside the camera."
        case .nook: "Tabs, widgets and music in the open notch."
        case .tray: "A shelf in the notch for the files you're using."
        case .focus: "The rhythm of the Pomodoro timer."
        case .permissions: "Each one is asked for when a feature first needs it."
        case .about: "Your MacBook's notch, put to work."
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .appearance: "paintbrush.pointed.fill"
        case .activities: "waveform"
        case .nook: "square.grid.2x2.fill"
        case .tray: "tray.full.fill"
        case .focus: "timer"
        case .permissions: "lock.shield.fill"
        case .about: "info.circle.fill"
        }
    }

    /// The page's badge in the sidebar, always in color: like System Settings', the colors tell the
    /// pages apart.
    var tint: Color {
        switch self {
        case .general: Color(red: 0.44, green: 0.53, blue: 0.7)
        case .appearance: Color(red: 1.0, green: 0.4, blue: 0.58)
        case .activities: Color(red: 1.0, green: 0.56, blue: 0.24)
        case .nook: Color(red: 0.6, green: 0.46, blue: 1.0)
        case .tray: Color(red: 0.2, green: 0.72, blue: 0.78)
        case .focus: Color(red: 1.0, green: 0.4, blue: 0.36)
        case .permissions: Color(red: 0.26, green: 0.74, blue: 0.45)
        case .about: Color(red: 0.32, green: 0.56, blue: 1.0)
        }
    }

    /// 1 to 8, for the ⌘1 to ⌘8 shortcuts.
    var number: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var page: SettingsPage = .general
    /// The live activity under the pointer on the Live Activities page. The preview holds on it.
    @Published var spotlight: LiveActivityKind?
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()
    static let contentSize = NSSize(width: 880, height: 640)
    static let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]

    private let navigation = SettingsNavigation()

    private init() {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.contentSize), styleMask: Self.styleMask,
                              backing: .buffered, defer: false)
        super.init(window: window)
        Self.configure(window, navigation: navigation)
        window.center()
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    /// Fills a window with the settings. The snapshot renderer uses this for its own windows.
    static func configure(_ window: NSWindow, navigation: SettingsNavigation, isSnapshot: Bool = false) {
        window.title = "Dynotch Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        let hosting = NSHostingController(rootView: SettingsView(navigation: navigation).environment(\.isSnapshot, isSnapshot))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(contentSize)
    }

    func show(page: SettingsPage? = nil) {
        if let page { navigation.page = page }
        // Show up in the Dock and app switcher while the window is open.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        DockPresence.windowWillClose(window)
    }
}

/// A sidebar of pages beside the selected page: a header with a model notch that acts out
/// the page's settings, and the settings themselves underneath.
struct SettingsView: View {
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 0) {
            // Above the stage, so its shadow falls on it.
            SettingsSidebar(navigation: navigation)
                .zIndex(1)
            VStack(spacing: 0) {
                SettingsStage(navigation: navigation)
                ScrollView {
                    page
                        .padding(.horizontal, 26)
                        .padding(.top, 22)
                        .padding(.bottom, 30)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .id(navigation.page)
                .transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Behind the sidebar too, which floats above it on macOS 26: the stage runs to the window's edge.
        .background(alignment: .top) {
            Palette.stageGradient.frame(height: SettingsStage.height)
        }
        .background(Palette.window)
        .ignoresSafeArea()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .windowAccent(WindowAccent(choice: settings.notchAccent))
    }

    @ViewBuilder
    private var page: some View {
        switch navigation.page {
        case .general: GeneralSettings()
        case .appearance: AppearanceSettings()
        case .activities: ActivitySettings(navigation: navigation)
        case .nook: NookSettings()
        case .tray: TraySettings()
        case .focus: FocusSettings()
        case .permissions: PermissionsSettings()
        case .about: AboutSettings()
        }
    }
}

// MARK: Sidebar

private struct SettingsSidebar: View {
    @ObservedObject var navigation: SettingsNavigation
    @Namespace private var selection
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// macOS 26 floats the sidebar in the window as a pane of glass, with the window's buttons inside
    /// it. Earlier versions set it flush against the window's edge.
    private static var floats: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    /// How far the floating pane sits in from the window's edges, so its corners follow the window's.
    private static let floatInset: CGFloat = 5

    var body: some View {
        let floats = Self.floats
        let inset = floats ? Self.floatInset : 0
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                DynotchLogo(size: 34)
                    .shadow(color: Palette.lavender.opacity(0.35), radius: 7, y: 2)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Dynotch")
                        .font(.system(size: 15, weight: .bold))
                    Text("Settings")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Palette.secondaryText)
                }
            }
            .padding(.horizontal, 8)
            // In the same spot in the window, floating or not.
            .padding(.top, 58 - inset)
            .padding(.bottom, 22)
            .accessibilityElement(children: .combine)

            VStack(spacing: 2) {
                ForEach(SettingsPage.allCases) { page in
                    SidebarRow(page: page, isSelected: navigation.page == page, selection: selection) {
                        select(page)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, floats ? 8 : 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background { background(floats: floats) }
        .padding(inset)
        .frame(width: 214)
        // Like a list: once clicked or tabbed into, the arrow keys move between pages.
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { direction in
            let pages = SettingsPage.allCases
            guard let index = pages.firstIndex(of: navigation.page) else { return }
            switch direction {
            case .up where index > 0: select(pages[index - 1])
            case .down where index < pages.count - 1: select(pages[index + 1])
            default: break
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings pages")
    }

    private func select(_ page: SettingsPage) {
        guard page != navigation.page else { return }
        navigation.spotlight = nil
        // The selection slides to the page, or with Reduce Motion eases there without overshooting.
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.82)) {
            navigation.page = page
        }
    }

    @ViewBuilder
    private func background(floats: Bool) -> some View {
        if floats {
            // A pane of glass, as macOS 26 draws a sidebar: tinted toward the window so it doesn't take
            // over, lit from above, and its rim catches the light.
            let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
            ZStack {
                material
                LinearGradient(colors: [Palette.cardTop.opacity(0.5), .clear], startPoint: .top, endPoint: .center)
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Palette.rimGradient))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        } else {
            material.overlay(alignment: .trailing) {
                Rectangle().fill(Palette.stroke).frame(width: 1)
            }
        }
    }

    /// The window's own translucent material, tinted with the sidebar's color. Snapshots can't draw
    /// the material, so they get the color alone.
    @ViewBuilder
    private var material: some View {
        if isSnapshot {
            Palette.sidebar
        } else {
            ZStack {
                SidebarMaterial()
                Palette.sidebar.opacity(0.55)
            }
        }
    }
}

/// The material under a Finder sidebar: the desktop shows through, blurred. Always active, so the
/// sidebar stays glass while another app is in front.
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct SidebarRow: View {
    let page: SettingsPage
    let isSelected: Bool
    let selection: Namespace.ID
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SymbolBadge(symbol: page.symbol, tint: page.tint, size: 24)
                Text(page.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(Color.primary.opacity(isSelected ? 1 : 0.82))
                Spacer(minLength: 0)
                if hovering, !isSelected {
                    Text("⌘\(page.number)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Palette.secondaryText)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 36)
            .background {
                let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                // The selected page stands on a pane of glass that slides from page to page.
                if isSelected {
                    CardBackground(cornerRadius: 10)
                        .matchedGeometryEffect(id: "selection", in: selection)
                } else if hovering {
                    shape.fill(Palette.wash)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .keyboardShortcut(KeyEquivalent(Character("\(page.number)")), modifiers: .command)
        .accessibilityLabel(page.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
