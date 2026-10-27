import AppKit
import SwiftUI

/// Handles `dynotch://` links, so scripts and other apps can drive the notch.
/// `scripts/dynotch` wraps them for the shell.
///
///     dynotch://notify?text=Deploy%20done&detail=…&symbol=checkmark.circle.fill&tint=green&seconds=4
///     dynotch://open?tab=tray          home, tray, focus or stats
///     dynotch://close
///     dynotch://timer/start            start, pause, toggle, reset or skip
///     dynotch://tray/add?path=/a/file&path=/another/file&show=1
///     dynotch://profile?name=Work      switches to a saved profile
@MainActor
enum URLCommands {
    static func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "dynotch",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        // dynotch://timer/start puts "timer" in the host; dynotch:timer/start puts it in the path.
        var path = components.path.split(separator: "/").map { $0.lowercased() }
        if let host = components.host, !host.isEmpty { path.insert(host.lowercased(), at: 0) }
        let items = components.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }

        switch path.first {
        case "notify":
            notify(text: value("text") ?? "", detail: value("detail"), symbol: value("symbol"),
                   tint: value("tint"), seconds: value("seconds").flatMap(Double.init))
        case "open":
            NotchManager.shared.open(tab: value("tab").flatMap(tab(named:)))
        case "close":
            NotchManager.shared.close()
        case "timer":
            timer(path.count > 1 ? path[1] : "toggle")
        case "tray":
            let urls = items.filter { $0.name == "path" }.compactMap(\.value)
                .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            TrayStore.shared.add(urls)
            if value("show") == "1" { NotchManager.shared.open(tab: .tray) }
        case "profile":
            ProfileStore.shared.switchTo(named: value("name") ?? "")
        default:
            NSLog("Dynotch: ignoring %@", url.absoluteString)
        }
    }

    private static func notify(text: String, detail: String?, symbol: String?, tint: String?, seconds: Double?) {
        var text = String(text.prefix(100))
        var detail = detail.map { String($0.prefix(140)) }.flatMap { $0.isEmpty ? nil : $0 }
        // The ear beside the camera fits a couple of words; longer text goes on the row underneath.
        if text.count > 18 {
            if detail == nil {
                detail = text
                text = ""
            } else {
                text = String(text.prefix(17)) + "…"
            }
        }
        let symbol = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil ? nil : $0 } ?? "bell.fill"
        LiveActivityCenter.shared.post(LiveNotice(key: "command", symbol: symbol, tint: color(named: tint) ?? .white,
                                                  text: text, detail: detail),
                                       for: min(max(seconds ?? 4, 1), 30))
    }

    private static func timer(_ action: String) {
        let timer = PomodoroTimer.shared
        switch action {
        case "start": timer.start()
        case "pause", "stop": timer.pause()
        case "reset": timer.reset()
        case "skip": timer.skip()
        default: timer.toggle()
        }
    }

    private static func tab(named name: String) -> NotchTab? {
        name.lowercased() == "nook" ? .home : NotchTab(rawValue: name.lowercased())
    }

    /// A color name such as `green`, or a hex value such as `#FF6B5C`.
    static func color(named name: String?) -> Color? {
        guard let name = name?.trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty else { return nil }
        let named: [String: Color] = ["white": .white, "gray": .gray, "grey": .gray, "red": .red, "orange": .orange,
                                      "yellow": .yellow, "green": .green, "mint": .mint, "teal": .teal, "cyan": .cyan,
                                      "blue": .blue, "indigo": .indigo, "purple": .purple, "pink": .pink]
        if let color = named[name] { return color }
        let hex = name.hasPrefix("#") ? String(name.dropFirst()) : name
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return Color(red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }
}
