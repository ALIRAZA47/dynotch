import AppKit
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    // `nook` keeps its name for links, the command field's history and snapshots; it's the Sections page.
    case general, appearance, activities, nook, tray, focus, permissions, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .activities: "Live Activities"
        case .nook: "Sections"
        case .tray: "Tray"
        case .focus: "Focus Timer"
        case .permissions: "Permissions"
        case .about: "About"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "How the notch opens, and where it shows up."
        case .appearance: "Theme, accent, size, and where the buttons go."
        case .activities: "What the closed notch shows beside the camera."
        case .nook: "The sections under the open notch, and their widgets."
        case .tray: "A shelf in the notch for the files you're using."
        case .focus: "The rhythm of the Pomodoro timer."
        case .permissions: "Each one is asked for when a feature first needs it."
        case .about: "Your MacBook's notch, put to work."
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .appearance: "circle.lefthalf.filled"
        case .activities: "waveform.path.ecg"
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
        case .general: NotchTheme.hex(0x8E8E93)
        case .appearance: NotchTheme.hex(0xFF375F)
        case .activities: NotchTheme.hex(0xFF9F0A)
        case .nook: NotchTheme.hex(0x2E6BFF)
        case .tray: NotchTheme.hex(0x34C759)
        case .focus: NotchTheme.hex(0xFF453A)
        case .permissions: NotchTheme.hex(0x5E5CE6)
        case .about: NotchTheme.hex(0x8E8E93)
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

/// A sidebar of pages beside the selected page: a header with a model notch that acts out the
/// page's settings, and the settings themselves underneath. Flat Orbit surfaces, light or dark with
/// macOS.
struct SettingsView: View {
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(navigation: navigation)
            VStack(spacing: 0) {
                SettingsStage(navigation: navigation)
                ScrollView {
                    page
                        .padding(.horizontal, 28)
                        .padding(.top, 18)
                        .padding(.bottom, 30)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .id(navigation.page)
                .transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.window)
        .ignoresSafeArea()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .orbitWindow(settings)
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

/// The pages down a raised strip along the window's left edge, with a hairline where it meets the
/// page. The selected page is a solid face of the accent.
private struct SettingsSidebar: View {
    @ObservedObject var navigation: SettingsNavigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                DynotchLogo(size: 22)
                Text("Dynotch")
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 10)
            // Under the window's buttons.
            .padding(.top, 46)
            .padding(.bottom, 14)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Dynotch Settings")

            VStack(spacing: 2) {
                ForEach(SettingsPage.allCases) { page in
                    SidebarRow(page: page, isSelected: navigation.page == page) {
                        select(page)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity, alignment: .top)
        .frame(width: 220)
        .background(Palette.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Palette.stroke).frame(width: 1)
        }
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
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.22)) {
            navigation.page = page
        }
    }
}

private struct SidebarRow: View {
    let page: SettingsPage
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.windowAccent) private var accent
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.symbol)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    // On the accent's face the badge turns to a lighter square of it, as in the board.
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.25) : page.tint))
                Text(page.title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? accent.onFill : Color.primary)
                Spacer(minLength: 0)
                if hovering, !isSelected {
                    Text("⌘\(page.number)")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Palette.secondaryText)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 30)
            .background {
                if isSelected {
                    theme.controlShape.fill(accent.fill)
                } else if hovering {
                    theme.controlShape.fill(Palette.wash)
                }
            }
            .contentShape(theme.controlShape)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .keyboardShortcut(KeyEquivalent(Character("\(page.number)")), modifiers: .command)
        .accessibilityLabel(page.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
