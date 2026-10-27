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

extension NSImage {
    /// The average color of the image, brightened so it reads well on black.
    func vibrantAverageColor() -> NSColor? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 12
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        var red = 0.0, green = 0.0, blue = 0.0, weight = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
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
        if saturation < 0.12 { return NSColor(white: 0.92, alpha: 1) }
        return NSColor(hue: hue, saturation: min(1, saturation * 1.15 + 0.1), brightness: max(0.75, brightness), alpha: 1)
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

extension Color {
    static let notchSecondary = Color.white.opacity(0.58)
    static let notchTertiary = Color.white.opacity(0.36)
    static let notchCard = Color.white.opacity(0.07)
    static let notchCardHover = Color.white.opacity(0.12)
}

extension Animation {
    static let notchOpen = Animation.spring(response: 0.42, dampingFraction: 0.76)
    static let notchClose = Animation.spring(response: 0.36, dampingFraction: 0.95)
    static let notchHover = Animation.spring(response: 0.28, dampingFraction: 0.7)
    static let notchActivity = Animation.spring(response: 0.42, dampingFraction: 0.8)
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
