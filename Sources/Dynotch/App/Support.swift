import AppKit
import SwiftUI

enum Haptics {
    @MainActor
    static func tap() {
        guard AppSettings.shared.haptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

enum Format {
    /// 3:07, 1:02:45
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600, minutes = total / 60 % 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// "in 5m", "in 1h 20m", "now"
    static func countdown(to date: Date, from now: Date = .now) -> String {
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return "now" }
        if minutes < 60 { return "in \(minutes)m" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "in \(hours)h" : "in \(hours)h \(rest)m"
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// Memory in binary units, so 24 GB of RAM reads as 24 GB.
    static func memory(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .memory)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }
}

/// WCAG's relative luminance, and how far a color has to come up to reach one.
enum Luminance {
    /// The relative luminance of sRGB values.
    static func of(_ rgb: [Double]) -> Double {
        let linear = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    /// The sRGB values of `color`.
    static func rgb(of color: NSColor) -> [Double]? {
        color.usingColorSpace(.sRGB).map { [$0.redComponent, $0.greenComponent, $0.blueComponent].map(Double.init) }
    }

    /// `rgb` lifted toward white just far enough to reach `minimum`.
    static func lifted(_ rgb: [Double], to minimum: Double) -> [Double] {
        guard of(rgb) < minimum else { return rgb }
        var low = 0.0, high = 1.0
        for _ in 0..<12 {
            let mix = (low + high) / 2
            if of(rgb.map { $0 + (1 - $0) * mix }) < minimum { low = mix } else { high = mix }
        }
        return rgb.map { $0 + (1 - $0) * high }
    }
}

extension NSImage {
    /// The luminance the player's marks need: the bars, the scrubber, a check, an active shuffle.
    /// Enough for 3:1 on a pane, on black and on glass.
    private static let markLuminance = 0.24

    /// The average color of the image, brightened so it reads well on black. HSB brightness says
    /// little about how light a color looks, so a deep blue or violet then comes up toward white.
    func vibrantAverageColor() -> NSColor? {
        guard let color = sampledPixels().flatMap({ Self.vibrantAverage(of: $0, brightest: 1) { _, _ in true } }) else { return nil }
        guard let rgb = Luminance.rgb(of: color) else { return color }
        let lifted = Luminance.lifted(rgb, to: Self.markLuminance)
        return NSColor(srgbRed: lifted[0], green: lifted[1], blue: lifted[2], alpha: 1)
    }

    /// A few of the image's colors for the light behind it, brightened like `vibrantAverageColor`
    /// but never lifted or glaring: its top-left half, its bottom-right half and the whole, so a cover that
    /// runs from one color to another lights the notch with both.
    func vibrantPalette() -> [NSColor] {
        guard let pixels = sampledPixels() else { return [] }
        let side = Self.sampleSide
        return [
            Self.vibrantAverage(of: pixels, brightest: 0.9) { x, y in x + y < side },
            Self.vibrantAverage(of: pixels, brightest: 0.9) { x, y in x + y >= side },
            Self.vibrantAverage(of: pixels, brightest: 0.9) { _, _ in true },
        ].compactMap { $0 }
    }

    private static let sampleSide = 12

    /// The image scaled down to `sampleSide` pixels square, as RGBA bytes from the top row down.
    private func sampledPixels() -> [UInt8]? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = Self.sampleSide
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? pixels : nil
    }

    /// The average of the pixels at the columns and rows `includes` picks, brightened for black,
    /// with its HSB brightness no higher than `brightest`.
    private static func vibrantAverage(of pixels: [UInt8], brightest: CGFloat,
                                       includes: (_ x: Int, _ y: Int) -> Bool) -> NSColor? {
        var red = 0.0, green = 0.0, blue = 0.0, weight = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) where includes(index / 4 % sampleSide, index / 4 / sampleSide) {
            let r = Double(pixels[index]) / 255, g = Double(pixels[index + 1]) / 255, b = Double(pixels[index + 2]) / 255
            // Favor saturated pixels so a colorful cover doesn't average out to gray.
            let saturation = max(r, g, b) - min(r, g, b)
            let w = 0.15 + saturation
            red += r * w; green += g * w; blue += b * w; weight += w
        }
        guard weight > 0 else { return nil }
        let average = NSColor(srgbRed: red / weight, green: green / weight, blue: blue / weight, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        if saturation < 0.12 { return NSColor(white: min(0.92, brightest), alpha: 1) }
        return NSColor(hue: hue, saturation: min(1, saturation * 1.15 + 0.1),
                       brightness: min(brightest, max(0.75, brightness)), alpha: 1)
    }
}

/// File and app icons as plain sRGB bitmaps. Workspace icons are IconServices images that
/// can push SwiftUI into a wider color space, which washes out every translucent fill around them.
@MainActor
enum IconCache {
    private static var icons: [String: NSImage] = [:]

    static func icon(forFile path: String, side: CGFloat) -> NSImage {
        let key = "\(path)@\(side)"
        if let icon = icons[key] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path).flattened(side: side)
        icons[key] = icon
        return icon
    }
}

extension NSImage {
    func flattened(side: CGFloat, scale: CGFloat = 2) -> NSImage {
        let pixels = Int(side * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return self }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return self }
        return NSImage(cgImage: image, size: NSSize(width: side, height: side))
    }
}

extension Animation {
    static let notchOpen = Animation.spring(response: 0.42, dampingFraction: 0.76)
    static let notchClose = Animation.spring(response: 0.36, dampingFraction: 0.95)
    static let notchHover = Animation.spring(response: 0.28, dampingFraction: 0.7)
    /// The hovered notch growing into a glance: quicker and calmer than opening.
    static let notchGlance = Animation.spring(response: 0.34, dampingFraction: 0.82)
    static let notchActivity = Animation.spring(response: 0.42, dampingFraction: 0.8)
    /// The selected tab's pill moving along the tab bar.
    static let notchTab = Animation.spring(response: 0.32, dampingFraction: 0.82)
    /// A highlight under the pointer coming and going.
    static let notchHighlight = Animation.easeOut(duration: 0.12)
    /// A tile or a lens turning on or off: plain glass and the accent's jewel cross-fade.
    static let notchToggle = Animation.easeOut(duration: 0.15)

    /// Something rising to meet the pointer or a drag, like a targeted drop zone or a switch's knob,
    /// with a little overshoot. With Reduce Motion it just eases there.
    static func notchLift(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.7)
    }
}

enum Shell {
    /// Runs a command off the main thread and returns its standard output.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: (-1, ""))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }
}
