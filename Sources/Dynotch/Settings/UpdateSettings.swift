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

/// The latest release and what to do about it: check, read its notes, install it, or download it
/// where this copy can't replace itself.
private struct UpdateRow: View {
    @ObservedObject var checker: UpdateChecker
    @ObservedObject private var installer = UpdateInstaller.shared

    var body: some View {
        let status = checker.status
        HStack(spacing: 12) {
            // The card's lead row gets the larger badge, centered on the column of the switch row's
            // below it, so the two titles still line up.
            SymbolBadge(symbol: symbol, tint: tint, size: 30)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if case .available = status, case .downloading(let fraction) = installer.state {
                    // The accent's groove once the size is known; until then, the system's small bar.
                    Group {
                        if let fraction {
                            MeterBar(value: fraction)
                        } else {
                            ProgressView()
                                .progressViewStyle(.linear)
                                .controlSize(.small)
                        }
                    }
                    .padding(.top, 5)
                    .accessibilityLabel("Download progress")
                }
            }
            Spacer(minLength: 12)
            if status == .checking || installer.state == .verifying || installer.state == .installing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }
            buttons
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: status)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: installer.state)
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
            if installer.isBusy {
                EmptyView()
            } else if case .failed = installer.state {
                CapsuleButton(title: "Download", symbol: "safari") { NSWorkspace.shared.open(release.download ?? release.page) }
                CapsuleButton(title: "Try Again", symbol: "arrow.clockwise", kind: .prominent) { installer.install(release) }
            } else if canInstall(release) {
                CapsuleButton(title: "Release Notes", symbol: "doc.text") { NSWorkspace.shared.open(release.page) }
                CapsuleButton(title: "Install and Relaunch", symbol: "arrow.down.circle.fill", kind: .prominent) {
                    installer.install(release)
                }
            } else {
                CapsuleButton(title: "Release Notes", symbol: "doc.text") { NSWorkspace.shared.open(release.page) }
                CapsuleButton(title: "Download", symbol: "arrow.down.circle.fill", kind: .prominent) {
                    NSWorkspace.shared.open(release.download ?? release.page)
                }
            }
        }
    }

    private func check() {
        Task { await checker.check() }
    }

    private func canInstall(_ release: UpdateChecker.Release) -> Bool {
        release.archive != nil && installer.canInstall
    }

    private var installFailed: Bool {
        if case .available = checker.status, case .failed = installer.state { return true }
        return false
    }

    private var symbol: String {
        switch checker.status {
        case .idle, .checking: "arrow.down.circle.fill"
        case .upToDate: "checkmark.circle.fill"
        case .available: installFailed ? "exclamationmark.triangle.fill" : "sparkles"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    /// Nil is the window accent, with its own glyph color: white would wash out on the pale accents
    /// of dark mode.
    private var tint: Color? {
        switch checker.status {
        case .idle, .checking: nil
        case .upToDate: .green
        case .available: installFailed ? .orange : nil
        case .failed: .orange
        }
    }

    private var title: String {
        switch checker.status {
        case .idle: "Dynotch \(UpdateChecker.currentVersion)"
        case .checking: "Checking for updates…"
        case .upToDate: "You're up to date"
        case .available(let release):
            switch installer.state {
            case .idle: "Dynotch \(release.version) is available"
            case .downloading: "Downloading Dynotch \(release.version)…"
            case .verifying: "Checking the download…"
            case .installing: "Installing Dynotch \(release.version)…"
            case .failed: "Couldn't install Dynotch \(release.version)"
            }
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
            switch installer.state {
            case .downloading(let fraction):
                return fraction.map { "\(Int(($0 * 100).rounded()))% downloaded." } ?? "Starting the download."
            case .verifying:
                return "Making sure it's Dynotch, signed with the same certificate as this copy."
            case .installing:
                return "Dynotch reopens in a moment. Settings, notes, the Tray and permissions stay."
            case .failed(let message):
                return message
            case .idle:
                let released = release.publishedAt.map { " Released \($0.formatted(date: .abbreviated, time: .omitted))." } ?? ""
                if canInstall(release) {
                    return "You have \(UpdateChecker.currentVersion).\(released) Install and Relaunch downloads it, checks it's signed like this copy, puts it in place and reopens Dynotch."
                }
                return "You have \(UpdateChecker.currentVersion).\(released) Download opens the disk image; then quit Dynotch and replace it in Applications."
            }
        case .failed(let message):
            return message
        }
    }
}
