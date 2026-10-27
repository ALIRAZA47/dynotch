import SwiftUI

/// Opt-in extras on the Live Activities page that each need a permission, asked for when they're
/// turned on: equalizer bars that follow the music, and taking over the volume and brightness keys.
struct EqualizerAndKeysSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var keys = MediaKeyTap.shared
    /// Only the permission: the levels themselves change thirty times a second.
    @ViewState private var audioPermission = AudioLevels.shared.permission

    private enum Tile: String, CaseIterable, Identifiable {
        case equalizer, keys

        var id: String { rawValue }
    }

    var body: some View {
        SettingsSection(title: "Equalizer and keys",
                        footer: "Each asks for its permission when you turn it on. Keys Dynotch can't handle, like an external display's brightness, still go to macOS.") {
            TileGrid(items: Tile.allCases, columns: 2) { tile in
                switch tile {
                case .equalizer: equalizerTile
                case .keys: keysTile
                }
            }
        }
        .onReceive(AudioLevels.shared.$permission) { audioPermission = $0 }
    }

    private var equalizerTile: some View {
        SwitchTile(title: "Live equalizer", detail: equalizerDetail, symbol: "waveform", tint: LiveActivityKind.music.tint,
                   spokenTitle: "Live equalizer", isOn: $settings.liveEqualizer)
            .disabled(!AudioLevels.isSupported)
    }

    private var equalizerDetail: String {
        guard AudioLevels.isSupported else { return "Needs macOS 14.2 or later" }
        guard settings.liveEqualizer else { return "Bars that follow the music, from what Music or Spotify plays" }
        switch audioPermission {
        case .denied: return "Allow Dynotch in Privacy & Security → Screen & System Audio Recording"
        case .notDetermined: return "Allow System audio recording on the Permissions page"
        case .granted, .unknown: return "The bars follow the music while Music or Spotify plays"
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
