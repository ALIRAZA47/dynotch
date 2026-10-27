import AppKit
import SwiftUI

/// The Updates card on the About page: whether this is the newest Dynotch, a button to ask, and
/// whether it asks by itself.
struct UpdateSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var checker = UpdateChecker.shared

    var body: some View {
        SettingsCard {
            UpdateRow(checker: checker)
            CardDivider()
            SwitchRow(title: "Check automatically", detail: "Once a day. A new version is announced in the notch.",
                      symbol: "arrow.triangle.2.circlepath", isOn: $settings.checksForUpdates)
        }
    }
}

/// The latest release and what to do about it: check, read its notes or download it.
private struct UpdateRow: View {
    @ObservedObject var checker: UpdateChecker

    var body: some View {
        let status = checker.status
        HStack(spacing: 12) {
            SymbolBadge(symbol: symbol, tint: tint, isActive: isActive, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if status == .checking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }
            buttons
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: status)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title). \(detail)")
    }

    @ViewBuilder
    private var buttons: some View {
        switch checker.status {
        case .idle:
            CapsuleButton(title: "Check for Updates", symbol: "arrow.clockwise", action: check)
        case .checking:
            CapsuleButton(title: "Checking…", symbol: "arrow.clockwise", action: check)
                .disabled(true)
        case .upToDate:
            CapsuleButton(title: "Check Again", symbol: "arrow.clockwise", action: check)
        case .failed:
            CapsuleButton(title: "Try Again", symbol: "arrow.clockwise", action: check)
        case .available(let release):
            CapsuleButton(title: "Release Notes", symbol: "doc.text") { NSWorkspace.shared.open(release.page) }
            CapsuleButton(title: "Download", symbol: "arrow.down.circle.fill", kind: .prominent) {
                NSWorkspace.shared.open(release.download ?? release.page)
            }
        }
    }

    private func check() {
        Task { await checker.check() }
    }

    private var symbol: String {
        switch checker.status {
        case .idle, .checking: "arrow.down.circle.fill"
        case .upToDate: "checkmark.circle.fill"
        case .available: "sparkles"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch checker.status {
        case .idle, .checking: Palette.accent
        case .upToDate: .green
        case .available: Palette.magenta
        case .failed: .orange
        }
    }

    private var isActive: Bool {
        checker.status != .idle
    }

    private var title: String {
        switch checker.status {
        case .idle: "Dynotch \(UpdateChecker.currentVersion)"
        case .checking: "Checking for updates…"
        case .upToDate: "You're up to date"
        case .available(let release): "Dynotch \(release.version) is available"
        case .failed: "Couldn't check for updates"
        }
    }

    private var detail: String {
        switch checker.status {
        case .idle:
            if let checked = checker.lastChecked {
                return "Last checked \(UpdateChecker.describe(checked))."
            }
            return "Looks up the newest release on GitHub."
        case .checking:
            return "Asking GitHub for the newest release."
        case .upToDate:
            let checked = checker.lastChecked.map { " Checked \(UpdateChecker.describe($0))." } ?? ""
            return "Dynotch \(UpdateChecker.currentVersion) is the newest version.\(checked)"
        case .available(let release):
            let released = release.publishedAt.map { " Released \($0.formatted(date: .abbreviated, time: .omitted))." } ?? ""
            return "You have \(UpdateChecker.currentVersion).\(released) Download opens the disk image; then quit Dynotch and replace it in Applications."
        case .failed(let message):
            return message
        }
    }
}
