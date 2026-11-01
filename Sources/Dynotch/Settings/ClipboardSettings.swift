import SwiftUI

/// The Tray page's Clipboard section: the switch, what macOS is refusing if it is, and Clear.
struct ClipboardSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var store = ClipboardStore.shared

    var body: some View {
        SettingsSection(title: "Clipboard",
                        footer: "Keeps the last 50 things you copy as text, in memory until Dynotch quits. Only what you pin is saved, on this Mac. Left out: files, images, anything an app marks as a password or as temporary, copies made in a password manager, and what arrives from another device through Universal Clipboard. Nothing leaves your Mac.") {
            SettingsCard {
                SwitchRow(title: "Keep clipboard history", detail: "Find what you copied in the Tray, or type clip in the command field",
                          symbol: "doc.on.clipboard.fill", tint: .teal, isOn: $settings.clipboardHistory)
                if settings.clipboardHistory, let problem = store.access.problem {
                    CardDivider()
                    ClipboardProblemRow(problem: problem)
                }
                CardDivider()
                HStack(spacing: 12) {
                    SymbolBadge(symbol: "memorychip", tint: .teal, isActive: settings.clipboardHistory, size: 26)
                    Text(remembered)
                        .font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 12)
                    CapsuleButton(title: "Clear Clipboard History", symbol: "trash", kind: .destructive) { store.clear() }
                        .fixedSize()
                        .disabled(unpinned == 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
        }
    }

    private var unpinned: Int { store.clips.filter { !$0.isPinned }.count }

    private var remembered: String {
        unpinned == 0 ? "Nothing in memory" : unpinned == 1 ? "1 copy in memory" : "\(unpinned) copies in memory"
    }
}

/// What macOS is refusing, and where to change that. macOS lists Dynotch there once it has asked.
private struct ClipboardProblemRow: View {
    let problem: String

    var body: some View {
        HStack(spacing: 12) {
            SymbolBadge(symbol: "exclamationmark.triangle.fill", tint: .orange, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(problem)
                    .font(.system(size: 13, weight: .medium))
                Text("Under Paste from Other Apps, set Dynotch to Allow. If that doesn't do it, quit Dynotch and open it again.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            CapsuleButton(title: "Open Privacy & Security", symbol: "hand.raised.fill") { ClipboardStore.openPrivacySettings() }
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}
