import SwiftUI

/// Runs the user's Shortcuts through the `shortcuts` command-line tool.
@MainActor
final class ShortcutsService: ObservableObject {
    static let shared = ShortcutsService()

    @Published private(set) var all: [String] = []
    @Published private(set) var running: Set<String> = []
    /// What `runInTurn` has yet to finish, the one running first.
    private var queued: [String] = []
    /// Runs a Shortcut and says whether it finished. A test stands in for it.
    var runner: @MainActor (String) async -> Bool = { await Shell.run("/usr/bin/shortcuts", ["run", $0]).status == 0 }

    private init() {}

    func loadSample(_ names: [String]) { all = names }

    func reload() async {
        let result = await Shell.run("/usr/bin/shortcuts", ["list"])
        all = result.output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func run(_ name: String) {
        guard running.insert(name).inserted else { return }
        Task {
            let succeeded = await runner(name)
            running.remove(name)
            announce(name, succeeded: succeeded)
        }
    }

    /// For what runs by itself: one after another, in the order they were asked for, and none dropped,
    /// so a quick skip can't leave a Focus on, or set two running against each other. It says nothing
    /// unless one fails.
    func runInTurn(_ name: String) {
        // Never a long line of them: past a few, the ones still waiting give way to the newest, which
        // is the one that says how things should end up. The one running is left to finish.
        if queued.count >= 4 { queued.removeSubrange(1...) }
        queued.append(name)
        guard queued.count == 1 else { return }
        Task {
            while let next = queued.first {
                let succeeded = await runner(next)
                queued.removeFirst()
                if !succeeded { announce(next, succeeded: false) }
            }
        }
    }

    private func announce(_ name: String, succeeded: Bool) {
        LiveActivityCenter.shared.post(LiveNotice(key: "shortcut",
                                                  symbol: succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                                  tint: succeeded ? .green : .orange,
                                                  detail: succeeded ? "\(name) finished" : "\(name) didn't finish",
                                                  recall: .whole), for: 2.5)
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
                    VStack(spacing: 2) {
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
            HStack(spacing: 10) {
                // A glyph square, as on Orbit's rows: the accent's wash while it runs.
                ZStack {
                    if isRunning {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(hovering ? theme.primary : theme.secondary)
                    }
                }
                .frame(width: 22, height: 22)
                .background(theme.controlShape.fill(isRunning ? theme.accentSoft : hovering ? theme.controlHover : theme.hover))
                Text(name)
                    .font(NotchFont.bodyStrong)
                    .foregroundStyle(theme.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 5)
            .frame(height: 32)
            .background {
                if hovering {
                    theme.controlShape.fill(theme.hover)
                }
            }
            .contentShape(theme.controlShape)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.96))
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .disabled(isRunning)
        .help(name)
    }
}
