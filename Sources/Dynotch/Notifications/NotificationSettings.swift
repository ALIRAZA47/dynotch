import AppKit
import SwiftUI

/// Notification peek options on the Live Activities page: Full Disk Access, privacy and which apps peek.
struct NotificationSettingsSection: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var mirror = NotificationMirror.shared

    var body: some View {
        SettingsSection(title: "Notifications", trailing: mirror.hasAccess ? nil : "Needs Full Disk Access",
                        footer: "A peek comes about five seconds after its notification, when macOS saves it. macOS still shows its own banners. To see only the notch, set an app's alert style to None in System Settings → Notifications, and keep Show in Notification Center on.") {
            if !mirror.hasAccess || mirror.isUnsupported {
                AccessCard(isUnsupported: mirror.isUnsupported)
                    .transition(.opacity)
            }
            SettingsCard {
                SwitchRow(title: "Hide message text", detail: "Show only the app and who it's from", symbol: "eye.slash.fill",
                          tint: .indigo, isOn: $settings.notificationHideText)
            }
            AppPicker()
        }
        .animation(.easeOut(duration: 0.2), value: mirror.hasAccess)
        // Full Disk Access is turned on in System Settings, so look again while the page is up.
        .task {
            while !Task.isCancelled, !mirror.hasAccess {
                mirror.refreshAccess()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

/// Why peeks can't start, and the way to Full Disk Access.
private struct AccessCard: View {
    let isUnsupported: Bool

    var body: some View {
        HStack(spacing: 12) {
            SymbolBadge(symbol: isUnsupported ? "exclamationmark.triangle.fill" : "lock.fill", tint: .orange, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(isUnsupported ? "Notifications can't be read on this Mac" : "Full Disk Access is off")
                    .font(.system(size: 13, weight: .medium))
                Text(isUnsupported
                     ? "This version of macOS keeps them somewhere Dynotch doesn't know."
                     : "Notification Center's list is only open to apps with Full Disk Access. Add Dynotch there, then come back.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            if !isUnsupported {
                CapsuleButton(title: "Open System Settings", symbol: "arrow.up.forward") {
                    NotificationMirror.shared.openAccessSettings()
                }
                .accessibilityLabel("Open System Settings for Full Disk Access")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
    }
}

/// A chip per well-known app that's installed, and one for every other app.
private struct AppPicker: View {
    @ObservedObject private var settings = AppSettings.shared

    private struct InstalledApp: Identifiable {
        let source: NotificationPeek.Source
        let bundleID: String

        var id: String { source.id }
    }

    var body: some View {
        let installed = NotificationPeek.sources.compactMap { source in
            source.bundleIDs.first { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
                .map { InstalledApp(source: source, bundleID: $0) }
        }
        VStack(alignment: .leading, spacing: 10) {
            Text("Show notifications from")
                .font(.system(size: 13, weight: .semibold))
                .padding(.leading, 2)
                .accessibilityAddTraits(.isHeader)
            FlowLayout(spacing: 7) {
                ForEach(installed) { app in
                    let isOn = !settings.notificationMutedApps.contains(app.source.id)
                    AppChip(title: app.source.name, isOn: isOn) {
                        if isOn {
                            settings.notificationMutedApps.append(app.source.id)
                        } else {
                            settings.notificationMutedApps.removeAll { $0 == app.source.id }
                        }
                    } icon: {
                        AppIconView(bundleID: app.bundleID, fallback: app.source.symbol, side: 16)
                    }
                }
                AppChip(title: "Other apps", isOn: settings.notificationOtherApps) {
                    settings.notificationOtherApps.toggle()
                } icon: {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
    }
}

/// An app that's on or off, with its icon in color while it's on. On, it's a selected chip in the
/// accent; off, a chip of plain glass.
private struct AppChip<Icon: View>: View {
    let title: String
    let isOn: Bool
    let action: () -> Void
    @ViewBuilder var icon: Icon
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.windowAccent) private var accent

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                icon
                    .frame(width: 16, height: 16)
                    .saturation(isOn ? 1 : 0)
                    .opacity(isOn ? 1 : 0.6)
                Text(title)
                    .font(.system(size: 12, weight: isOn ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isOn ? accent.color : Color.primary.opacity(0.78))
            .padding(.leading, 7)
            .padding(.trailing, 11)
            .frame(height: 28)
            .background {
                let shape = Capsule()
                if isOn {
                    // As faint as a selected chip's in light mode, where the accent's text has little room above 4.5:1.
                    shape.fill(accent.color.opacity(colorScheme == .dark ? 0.12 : 0.06))
                        .overlay(shape.strokeBorder(accent.color.opacity(0.55), lineWidth: 1.2))
                } else {
                    shape.fill(Palette.wash)
                        .overlay(shape.strokeBorder(Palette.rimGradient))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(TileButtonStyle(cornerRadius: 14))
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}
