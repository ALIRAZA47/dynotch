import SwiftUI

/// A color in another notation: "#a894ff to rgb", "#a894ff in hsl", "rgb(168, 148, 255) to hex".
enum ColorText {
    private struct Value {
        var red: Double, green: Double, blue: Double, opacity: Double
    }

    static func convert(_ text: String) -> (text: String, value: String, color: Color)? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard let groups = lower.groups(of: #"(.+?)\s+(?:to|in|as)\s+(hex|rgb|rgba|hsl|hsla)"#),
              let typed = groups[0], let notation = groups[1], let color = parse(typed) else { return nil }
        let value = switch notation {
        case "hex": hex(color)
        case "rgb", "rgba": rgb(color)
        default: hsl(color)
        }
        return ("\(typed) = \(value)", value, Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.opacity))
    }

    private static func parse(_ text: String) -> Value? {
        if case .color(let red, let green, let blue, let opacity)? = ClipboardStore.Clip.hexColor(text) {
            return Value(red: red, green: green, blue: blue, opacity: opacity)
        }
        guard let parts = text.groups(of: #"rgba?\(\s*(\d{1,3})\s*[, ]\s*(\d{1,3})\s*[, ]\s*(\d{1,3})\s*\)"#)?.compactMap({ $0.flatMap { Int($0) } }),
              parts.count == 3, parts.allSatisfy({ $0 <= 255 }) else { return nil }
        return Value(red: Double(parts[0]) / 255, green: Double(parts[1]) / 255, blue: Double(parts[2]) / 255, opacity: 1)
    }

    private static func channel(_ value: Double) -> Int { Int((value * 255).rounded()) }

    private static func alpha(_ value: Double) -> String { Calculator.format((value * 100).rounded() / 100) }

    private static func hex(_ color: Value) -> String {
        let digits = [color.red, color.green, color.blue].map { String(format: "%02x", channel($0)) }.joined()
        return "#" + digits + (color.opacity < 1 ? String(format: "%02x", channel(color.opacity)) : "")
    }

    private static func rgb(_ color: Value) -> String {
        let parts = "\(channel(color.red)), \(channel(color.green)), \(channel(color.blue))"
        return color.opacity < 1 ? "rgba(\(parts), \(alpha(color.opacity)))" : "rgb(\(parts))"
    }

    private static func hsl(_ color: Value) -> String {
        let high = max(color.red, color.green, color.blue), low = min(color.red, color.green, color.blue)
        let lightness = (high + low) / 2
        let spread = high - low
        let saturation = spread == 0 ? 0 : spread / (1 - abs(2 * lightness - 1))
        var hue = 0.0
        if spread > 0 {
            switch high {
            case color.red: hue = (color.green - color.blue) / spread
            case color.green: hue = (color.blue - color.red) / spread + 2
            default: hue = (color.red - color.green) / spread + 4
            }
            hue = (hue * 60 + 360).truncatingRemainder(dividingBy: 360)
        }
        let parts = "\(Int(hue.rounded())), \(Int((saturation * 100).rounded()))%, \(Int((lightness * 100).rounded()))%"
        return color.opacity < 1 ? "hsla(\(parts), \(alpha(color.opacity)))" : "hsl(\(parts))"
    }
}
