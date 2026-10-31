import CoreImage
import Foundation
import ImageIO
import Vision

/// Reads what's in a picture: its text, its codes and its subject. It works on `CGImage`s and files,
/// off the main thread, and has no UI. The Tray, Capture and the tests all come through here.
enum ImageReader {
    enum Failure: Error, Equatable {
        /// `CGImageSource` can't read the file. An SVG is one: it conforms to `public.image`, so it gets this far.
        case undecodable
        case noSubject
    }

    /// What an image has to copy.
    struct Reading: Equatable {
        /// Lines of text, in the order Vision gave them.
        var lines: [String] = []
        /// What its codes hold, which could be anything. Only `link` makes more of one than text.
        var codes: [String] = []

        var isEmpty: Bool { lines.isEmpty && codes.isEmpty }

        /// The lines, then each code that isn't already in them, on a line of its own.
        var text: String {
            codes.reduce(lines.joined(separator: "\n")) { text, code in
                text.contains(code) ? text : text.isEmpty ? code : text + "\n" + code
            }
        }

        /// How many lines `text` comes to.
        var lineCount: Int {
            text.split(whereSeparator: \.isNewline).count
        }

        /// The first code that's a link. The rest stay text.
        var link: URL? {
            codes.lazy.compactMap(ImageReader.link(from:)).first
        }
    }

    // MARK: Reading

    /// Reads take turns here, on a thread that's no task's. Vision's text reader holds its thread until
    /// work of its own has run on the threads tasks share, so reads run in tasks could fill those and
    /// wait for each other for good, and everything else in a task would wait behind them.
    private static let queue = DispatchQueue(label: "app.dynotch.image-reader", qos: .userInitiated)

    private static func inTurn<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    static func read(_ image: CGImage) async -> Reading {
        await inTurn { recognize(image) }
    }

    static func read(contentsOf url: URL) async throws -> Reading {
        try await inTurn { Result { recognize(try decode(url)) } }.get()
    }

    /// The subject on a clear background, cropped to it.
    static func cutOut(_ image: CGImage) async throws -> CGImage {
        try await inTurn { Result { try subject(of: image) } }.get()
    }

    static func cutOut(contentsOf url: URL) async throws -> CGImage {
        try await inTurn { Result { try subject(of: try decode(url)) } }.get()
    }

    /// The file's picture, the right way up. `CGImageSourceCreateImageAtIndex` ignores EXIF orientation,
    /// so a phone photo would come out sideways and OCR would read nothing. A thumbnail as big as the
    /// image has the rotation baked in.
    static func decode(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: max(width, height),
              ] as CFDictionary)
        else { throw Failure.undecodable }
        return image
    }

    private static func recognize(_ image: CGImage) -> Reading {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = true
        text.automaticallyDetectsLanguage = true
        let codes = VNDetectBarcodesRequest()
        codes.symbologies = [.qr, .microQR, .aztec, .dataMatrix]
        // One at a time, as text refuses an image of a couple of pixels, and that shouldn't stop the codes.
        try? handler.perform([text])
        try? handler.perform([codes])
        let payloads = (codes.results ?? []).compactMap(\.payloadStringValue)
        return Reading(lines: (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }.filter { !$0.isEmpty },
                       codes: payloads.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }

    private static func subject(of image: CGImage) throws -> CGImage {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let mask = request.results?.first, !mask.allInstances.isEmpty else { throw Failure.noSubject }
        let pixels = try mask.generateMaskedImage(ofInstances: mask.allInstances, from: handler, croppedToInstancesExtent: true)
        // Vision hands back premultiplied sRGB whatever it was given. With no working space, Core
        // Image leaves those values as they are, so the subject keeps its colors.
        let cut = CIImage(cvPixelBuffer: pixels)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let output = CIContext(options: [.workingColorSpace: NSNull()])
                .createCGImage(cut, from: cut.extent, format: .RGBA8, colorSpace: space)
        else { throw Failure.noSubject }
        return output
    }

    // MARK: Links

    /// The link a code holds, if it's one to offer. A code is untrusted: anyone can stick one over
    /// another, and nobody can read it by eye. So only a plain web address with nothing hiding in it
    /// becomes a link, and even then it waits for a click. Everything else is only ever text.
    static func link(from payload: String) -> URL? {
        let address = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        // Told not to mend anything: a space, a stray `\` or letters from another alphabet in the host
        // are what a trick looks like, not a slip to be tidied up.
        guard let url = URL(string: address, encodingInvalidCharacters: false),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: true), !host.isEmpty,
              // `%2F` in a host would read as the start of a path, a different place to the one it goes.
              !host.contains("%"),
              // `https://paypal.com@evil.example/` shows one domain and goes to another.
              url.user(percentEncoded: true) == nil, url.password(percentEncoded: true) == nil,
              address.rangeOfCharacter(from: .controlCharacters) == nil,
              (address.removingPercentEncoding ?? address).rangeOfCharacter(from: .controlCharacters) == nil
        else { return nil }
        return URL(string: scheme + address.dropFirst(scheme.count), encodingInvalidCharacters: false)
    }

    /// Where a link goes, as wide as `room` says by `width`: the host, then as much of the path as fits.
    /// The right-hand end of a host says whose site it is, so a long host keeps its end, as in
    /// `…evil.example`, and it does that within `hostRoom`. Anything that has to give way after this
    /// (Text cuts off what won't fit its row) then falls on the path, which is why that's smaller.
    static func destination(of url: URL, hostRoom: CGFloat, room: CGFloat, width: (String) -> CGFloat) -> String {
        var host = url.host(percentEncoded: true) ?? ""
        if let port = url.port { host += ":\(port)" }
        if width(host) > hostRoom {
            let name = host
            host = "…" + name.suffix(most(of: name.count) { width("…" + name.suffix($0)) <= hostRoom })
        }
        let path = url.path(percentEncoded: true)
        guard path != "/", !path.isEmpty else { return host }
        if width(host + path) <= room { return host + path }
        let shown = host
        return shown + path.prefix(most(of: path.count) { width(shown + path.prefix($0) + "…") <= room }) + "…"
    }

    /// The most of `count` that `fits` takes, when more is always harder to fit. A code can hold
    /// thousands of letters, and measuring each would show.
    private static func most(of count: Int, fits: (Int) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let middle = (low + high + 1) / 2
            if fits(middle) { low = middle } else { high = middle - 1 }
        }
        return low
    }
}
