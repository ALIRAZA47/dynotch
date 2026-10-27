import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The things you can do with files in (or dropped on) the tray.
@MainActor
enum FileActions {
    enum ImageFormat: String, CaseIterable, Identifiable {
        case png, jpeg, heic

        var id: String { rawValue }
        var title: String { rawValue.uppercased() }
        var type: UTType { self == .png ? .png : self == .jpeg ? .jpeg : .heic }
        var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func open(_ urls: [URL], with application: URL) {
        NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
    }

    static func applications(for url: URL) -> [URL] {
        NSWorkspace.shared.urlsForApplications(toOpen: url)
    }

    static func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static func copyToPasteboard(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
    }

    static func airDrop(_ urls: [URL]) {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            NSSound.beep()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: urls)
    }

    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    static func isArchive(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "zip"
    }

    /// Zips the files next to the first one, like Finder's Compress.
    static func compress(_ urls: [URL]) async -> URL? {
        guard let first = urls.first else { return nil }
        let name = urls.count == 1 ? first.deletingPathExtension().lastPathComponent : "Archive"
        let archive = uniqueURL(for: outputFolder(near: first).appendingPathComponent(name + ".zip"))
        if urls.count == 1 {
            let result = await Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, archive.path])
            return result.status == 0 ? archive : nil
        }
        // ditto archives a single item, so gather them in a folder first (APFS clones, so it's cheap).
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundle = staging.appendingPathComponent(name, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            for url in urls {
                try FileManager.default.copyItem(at: url, to: uniqueURL(for: bundle.appendingPathComponent(url.lastPathComponent)))
            }
        } catch {
            return nil
        }
        let result = await Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", bundle.path, archive.path])
        return result.status == 0 ? archive : nil
    }

    static func extract(_ archive: URL) async -> URL? {
        let destination = uniqueURL(for: outputFolder(near: archive)
            .appendingPathComponent(archive.deletingPathExtension().lastPathComponent, isDirectory: true))
        let result = await Shell.run("/usr/bin/ditto", ["-x", "-k", archive.path, destination.path])
        return result.status == 0 ? destination : nil
    }

    /// Writes a converted copy next to the original. With `maxPixelSize` the copy is scaled down too.
    static func convert(_ url: URL, to format: ImageFormat, quality: Double = 0.85, maxPixelSize: Int? = nil) async -> URL? {
        let suffix = maxPixelSize == nil ? "" : " (small)"
        let destination = uniqueURL(for: outputFolder(near: url)
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + suffix + "." + format.fileExtension))
        let typeIdentifier = format.type.identifier as CFString
        let converted = await Task.detached(priority: .userInitiated) { () -> Bool in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let output = CGImageDestinationCreateWithURL(destination as CFURL, typeIdentifier, 1, nil) else { return false }
            let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
            if let maxPixelSize {
                let thumbnailOptions = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                                        kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return false }
                CGImageDestinationAddImage(output, image, options)
            } else {
                CGImageDestinationAddImageFromSource(output, source, 0, options)
            }
            return CGImageDestinationFinalize(output)
        }.value
        return converted ? destination : nil
    }

    static func chooseFolder(prompt: String) -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Copies or moves files into a folder, renaming rather than overwriting. Returns the new locations.
    static func transfer(_ urls: [URL], to folder: URL, move: Bool) -> [URL] {
        urls.compactMap { url in
            let target = uniqueURL(for: folder.appendingPathComponent(url.lastPathComponent))
            do {
                if move {
                    try FileManager.default.moveItem(at: url, to: target)
                } else {
                    try FileManager.default.copyItem(at: url, to: target)
                }
                return target
            } catch {
                return nil
            }
        }
    }

    /// "name.ext", then "name 2.ext", "name 3.ext"...
    nonisolated static func uniqueURL(for url: URL) -> URL {
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var candidate = url
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    /// Next to the source when that folder is writable, otherwise the tray's own folder.
    private static func outputFolder(near url: URL) -> URL {
        let folder = url.deletingLastPathComponent()
        return FileManager.default.isWritableFile(atPath: folder.path) ? folder : TrayStore.shared.folder
    }
}
