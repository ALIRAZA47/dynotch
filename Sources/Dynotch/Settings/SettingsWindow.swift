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
    static func configure(_ window: NSWindow, navigation: SettingsNavigation) {
        window.title = "Dynotch Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        let hosting = NSHostingController(rootView: SettingsView(navigation: navigation))
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
        NSApp.setActivationPolicy(.accessory)
    }
}

/// A sidebar of pages beside the selected page: a header with a model notch that acts out
/// the page's settings, and the settings themselves underneath.
struct SettingsView: View {
    @ObservedObject var navigation: SettingsNavigation

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(navigation: navigation)
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
            .background(Palette.window)
        }
        .ignoresSafeArea()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                DynotchLogo(size: 34)
                    .shadow(color: Palette.lavender.opacity(0.35), radius: 7, y: 2)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Dynotch")
                        .font(.system(size: 15, weight: .bold))
                    Text("Settings")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 58)
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
        .padding(.horizontal, 12)
        .frame(width: 214)
        .frame(maxHeight: .infinity, alignment: .top)
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
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { navigation.page = page }
    }
}

private struct SidebarRow: View {
    let page: SettingsPage
    let isSelected: Bool
    let selection: Namespace.ID
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.symbol)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.7))
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? AnyShapeStyle(Palette.sunset) : AnyShapeStyle(Palette.wash)))
                Text(page.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(Color.primary.opacity(isSelected ? 1 : 0.82))
                Spacer(minLength: 0)
                if hovering, !isSelected {
                    Text("⌘\(page.number)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 36)
            .background {
                let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                if isSelected {
                    shape.fill(colorScheme == .dark ? Color.white.opacity(0.09) : Color.white)
                        .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.07), radius: 3, y: 1)
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
