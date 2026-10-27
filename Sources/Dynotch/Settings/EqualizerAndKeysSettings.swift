import SwiftUI

/// Opt-in extras on the Live Activities page that each need a permission, asked for when they're
/// turned on: taking over the volume and brightness keys.
struct EqualizerAndKeysSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var keys = MediaKeyTap.shared

    private enum Tile: String, Identifiable {
        case keys

        var id: String { rawValue }
    }

    var body: some View {
        SettingsSection(title: "Equalizer and keys",
                        footer: "Each asks for its permission when you turn it on. Keys Dynotch can't handle, like an external display's brightness, still go to macOS.") {
            TileGrid(items: [Tile.keys], columns: 2) { tile in
                switch tile {
                case .keys: keysTile
                }
            }
        }
    }

    private var keysTile: some View {
        let needsLevels = !settings.liveHUD
        return SwitchTile(title: "Replace system HUD", detail: needsLevels ? "Needs Volume & brightness" : keysDetail,
                          symbol: "keyboard", tint: LiveActivityKind.levels.tint,
                          spokenTitle: "Replace the system volume and brightness HUD", isOn: $settings.replaceSystemHUD)
            .disabled(needsLevels)
    }

    private var keysDetail: String {
        guard settings.replaceSystemHUD else { return "Only Dynotch's meter shows when you press the volume and brightness keys" }
        return keys.isActive ? "Dynotch handles the volume and brightness keys"
                             : "Allow Dynotch in Privacy & Security → Accessibility"
    }
}
