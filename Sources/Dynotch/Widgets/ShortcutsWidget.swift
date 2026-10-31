import SwiftUI

/// Runs the user's Shortcuts through the `shortcuts` command-line tool.
@MainActor
final class ShortcutsService: ObservableObject {
    static let shared = ShortcutsService()

    @Published private(set) var all: [String] = []
    @Published private(set) var running: Set<String> = []

    private init() {}

    func reload() async {
        let result = await Shell.run("/usr/bin/shortcuts", ["list"])
        all = result.output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func run(_ name: String) {
        guard running.insert(name).inserted else { return }
        Task {
            let result = await Shell.run("/usr/bin/shortcuts", ["run", name])
            running.remove(name)
            let succeeded = result.status == 0
            LiveActivityCenter.shared.post(LiveNotice(key: "shortcut",
                                                      symbol: succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                                      tint: succeeded ? .green : .orange,
                                                      detail: succeeded ? "\(name) finished" : "\(name) didn't finish",
                                                      timing: .waits), for: 2.5)
        }
    }
}

struct ShortcutsWidget: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var shortcuts = ShortcutsService.shared

    var body: some View {
        WidgetCard(title: "Shortcuts", symbol: "square.stack.3d.up.fill") {
            if settings.pinnedShortcuts.isEmpty {
                PermissionPrompt(symbol: "square.stack.3d.up", message: "Pin shortcuts to run them from here.",
                                 buttonTitle: "Choose…") { SettingsWindowController.shared.show(page: .nook) }
            } else {
                // Four rows are taller than the card in a short notch.
                Scroller(.vertical, fadesOverflow: true) {
                    VStack(spacing: 4) {
                        ForEach(settings.pinnedShortcuts.prefix(4), id: \.self) { name in
                            ShortcutButton(name: name, isRunning: shortcuts.running.contains(name)) { shortcuts.run(name) }
                        }
                    }
                }
            }
        }
    }
}

private struct ShortcutButton: View {
    let name: String
    let isRunning: Bool
    let action: () -> Void
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                // The play symbol sits at the center of the capsule's rounded end.
                if isRunning {
                    ProgressView().controlSize(.mini)
                        .frame(width: 12)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(hovering ? theme.primary : theme.secondary)
                        .frame(width: 12)
                }
                Text(name)
                    .font(NotchFont.body)
                    .foregroundStyle(theme.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 6)
            .padding(.trailing, 10)
            .frame(height: 24)
            .glass(.control, in: Capsule(), isLit: hovering)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.96))
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .disabled(isRunning)
        .help(name)
    }
}
