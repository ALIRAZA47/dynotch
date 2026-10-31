import AppKit
import SwiftUI

/// Copy Text and Cut Out: what becomes of what `ImageReader` finds, and the notices that say how it went.
@MainActor
enum ImageActions {
    /// Shows a notice for so many seconds. The tests collect them instead.
    typealias Notify = @MainActor (LiveNotice, TimeInterval) -> Void

    /// Room for where a link goes in the notice and in Recent, in points of `NotchFont.body`. The
    /// narrowest glance is 340 wide, and with its button that leaves 190 beside the notice's picture
    /// and about 100 in Recent, between the name, the time and the button.
    private static let linkRoom: CGFloat = 185
    private static let linkHostRoom: CGFloat = 96
    private static let linkFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)

    /// Long enough to get the pointer to the notch for the button, which also waits in Recent after this.
    private static let linkSeconds: TimeInterval = 8

    static func show(_ notice: LiveNotice, for seconds: TimeInterval) {
        LiveActivityCenter.shared.post(notice, for: seconds)
    }

    // MARK: Copy Text

    /// Copies the text in the images among `urls`, which are read in turn as one.
    static func copyText(from urls: [URL], to pasteboard: NSPasteboard = .general, notify: Notify = show) async {
        let images = urls.filter(FileActions.isImage)
        var reading = ImageReader.Reading()
        var unreadable: [URL] = []
        for url in images {
            do {
                let found = try await ImageReader.read(contentsOf: url)
                reading.lines += found.lines
                reading.codes += found.codes
            } catch {
                unreadable.append(url)
            }
        }
        if unreadable.count == images.count {
            notify(cantRead(unreadable), 3)
        } else {
            deliver(reading, to: pasteboard, skipped: unreadable.count, notify: notify)
        }
    }

    /// Puts what was read on the clipboard and says so. With nothing found, the clipboard stays as it was.
    static func deliver(_ reading: ImageReader.Reading, to pasteboard: NSPasteboard, skipped: Int = 0, notify: Notify = show) {
        guard !reading.isEmpty else {
            notify(LiveNotice(key: "capture", symbol: "text.viewfinder", tint: .orange, text: "No text found"), 3)
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(reading.text, forType: .string)
        // A QR code and nothing else has only the link to tell of.
        if !reading.lines.isEmpty || reading.link == nil {
            let lines = reading.lineCount == 1 ? "1 line" : "\(reading.lineCount) lines"
            notify(LiveNotice(key: "capture", symbol: "doc.on.clipboard.fill", tint: skipped == 0 ? .white : .orange, text: "Copied",
                              detail: skipped == 0 ? lines : "\(lines), but \(skipped == 1 ? "one image" : "\(skipped) images") couldn't be read"), 3)
        }
        if let link = reading.link {
            notify(LiveNotice(key: "qr", symbol: "qrcode", tint: .white, text: "QR code", detail: destination(of: link),
                              actions: [NoticeAction(title: "Open", kind: .openURL(link))], recall: .whole), linkSeconds)
        }
    }

    private static func destination(of link: URL) -> String {
        ImageReader.destination(of: link, hostRoom: linkHostRoom, room: linkRoom) {
            ($0 as NSString).size(withAttributes: [.font: linkFont]).width
        }
    }

    // MARK: Cut Out

    /// Cuts the subject out of each image among `urls`, as a PNG beside it, and puts those in the Tray.
    /// The originals are never touched.
    static func cutOut(_ urls: [URL], tray: TrayStore? = nil, notify: Notify = show) async {
        let tray = tray ?? .shared
        let images = urls.filter(FileActions.isImage)
        var made: [URL] = []
        var unreadable: [URL] = []
        var unwritable: URL?
        for url in images {
            let name = url.deletingPathExtension().lastPathComponent + " (cut out).png"
            let target = FileActions.outputFolder(near: url, tray: tray).appendingPathComponent(name)
            do {
                let subject = try await ImageReader.cutOut(contentsOf: url)
                do {
                    made.append(try await save(subject, as: target))
                } catch {
                    unwritable = target.deletingLastPathComponent()
                }
            } catch ImageReader.Failure.undecodable {
                unreadable.append(url)
            } catch {
                // Nothing stands out in this one, which the notice says if none of the others had better luck.
                continue
            }
        }
        if !made.isEmpty { tray.add(made) }
        notify(cutOutNotice(made: made, of: images.count, unreadable: unreadable, unwritable: unwritable), 4)
    }

    private static func cutOutNotice(made: [URL], of total: Int, unreadable: [URL], unwritable: URL?) -> LiveNotice {
        guard let last = made.last else {
            if let unwritable {
                return LiveNotice(key: "cutout", symbol: "exclamationmark.triangle.fill", tint: .orange, text: "Not saved",
                                  detail: "Couldn't write to \(unwritable.lastPathComponent)")
            }
            guard unreadable.isEmpty else { return cantRead(unreadable) }
            return LiveNotice(key: "cutout", symbol: "scissors", tint: .orange, text: "No subject found")
        }
        return LiveNotice(key: "cutout", symbol: "scissors", tint: made.count == total ? .white : .orange, text: "Cut out",
                          detail: total == 1 ? last.lastPathComponent : "\(made.count) of \(total) images, in the Tray",
                          actions: [NoticeAction(title: "Open", kind: .openFile(last)), NoticeAction(title: "Show", kind: .reveal(last))],
                          recall: .whole)
    }

    /// Writes the picture as a PNG, under `url`'s name or the next one free.
    nonisolated private static func save(_ image: CGImage, as url: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            guard let png = ScreenshotFile.pngData(image, scale: 1) else { throw CocoaError(.fileWriteUnknown) }
            return try write(png, to: url)
        }.value
    }

    /// Never overwrites. `uniqueURL` takes a name, and `.withoutOverwriting` holds to that if something
    /// else takes it first, so then it's on to the next. `name` is there for a test to lose that race.
    nonisolated static func write(_ data: Data, to url: URL, name: (URL) -> URL = FileActions.uniqueURL) throws -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        for attempt in 1...100 {
            // Numbered here too: a name that's a dangling link looks free, and is taken all the same.
            let wanted = attempt == 1 ? url : url.deletingLastPathComponent()
                .appendingPathComponent("\(base) \(attempt).\(url.pathExtension)")
            let target = name(wanted)
            do {
                try data.write(to: target, options: .withoutOverwriting)
                return target
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    // MARK: Notices

    /// A plain word about a file that turned out not to be readable, like an SVG, or a drop with no
    /// image in it after all.
    private static func cantRead(_ urls: [URL]) -> LiveNotice {
        let detail = urls.count == 1 ? "Couldn't open \(urls[0].lastPathComponent)" : urls.isEmpty ? "There's no image in that" : "Couldn't open those images"
        return LiveNotice(key: "capture", symbol: "exclamationmark.triangle.fill", tint: .orange, text: "Can't read", detail: detail)
    }
}
