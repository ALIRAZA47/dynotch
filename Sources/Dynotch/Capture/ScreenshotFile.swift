import AppKit
import UniformTypeIdentifiers

/// Where a capture is saved and what it's called: the Screenshot app's folder and its naming,
/// so a Dynotch screenshot sits beside macOS's own ones and the Tray's watcher picks it up.
enum ScreenshotFile {
    /// The Screenshot app's save folder (`defaults read com.apple.screencapture location`), or the Desktop.
    @MainActor static func folder() -> URL {
        ScreenshotWatcher.saveFolder()
    }

    /// "Screenshot 2026-10-27 at 16.52.01.png", numbered when that name is taken.
    static func url(in folder: URL, at date: Date = .now) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return FileActions.uniqueURL(for: folder.appendingPathComponent("Screenshot \(formatter.string(from: date)).png"))
    }

    /// Writes the image as a PNG at the display's scale into `folder`, tagged as a screen capture the way
    /// macOS tags its own. The file is written under a hidden name and renamed once it's whole and tagged,
    /// so a watcher never sees it half done.
    @MainActor @discardableResult
    static func save(_ image: CGImage, scale: CGFloat, in folder: URL? = nil) -> URL? {
        let folder = folder ?? self.folder()
        let target = url(in: folder)
        guard let data = pngData(image, scale: scale) else { return nil }
        let staging = folder.appendingPathComponent("." + target.lastPathComponent)
        do {
            try data.write(to: staging, options: .atomic)
            tagAsScreenCapture(staging)
            try FileManager.default.moveItem(at: staging, to: target)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            NSLog("Dynotch: couldn't save the capture: %@", error.localizedDescription)
            return nil
        }
        return target
    }

    /// PNG data with the display's scale in its DPI, so the file opens at its point size, as macOS's screenshots do.
    static func pngData(_ image: CGImage, scale: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        let dpi = 72 * scale
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func tiffData(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).tiffRepresentation
    }

    /// macOS marks its screenshots with this attribute, a property list holding `true`, and the Tray's watcher looks for it.
    private static func tagAsScreenCapture(_ url: URL) {
        guard let plist = try? PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0) else { return }
        plist.withUnsafeBytes { bytes in
            _ = setxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", bytes.baseAddress, bytes.count, 0, 0)
        }
    }
}
