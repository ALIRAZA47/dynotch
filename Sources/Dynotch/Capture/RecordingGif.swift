import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Turns a finished MP4 into a GIF that loops forever. It runs after the stop, off the main thread,
/// and takes as long as it takes, which the notch says.
enum RecordingGif {
    /// Frames this many to the second, which is what a GIF's recording is made at.
    static let frameRate = RecordFormat.gif.frameRate
    /// GIFs get heavy fast, and this keeps text readable.
    static let longestSide: CGFloat = 960
    /// Asked for at a time, so that pictures never pile up waiting their turn.
    private static let batch = 30

    enum Failure: Error {
        case noVideo, notEncoded
    }

    /// When a frame of the recording comes up, in hundredths of a second, which is all a GIF can say.
    /// A frame's share of a second doesn't come out even, so working from this they take turns
    /// rounding up, and the delays add up to the length.
    static func mark(_ index: Int) -> Int {
        Int((Double(index) * 100 / Double(frameRate)).rounded())
    }

    /// How many frames a length comes to. Always one, however short.
    static func frameCount(length: TimeInterval) -> Int {
        max(Int((length * Double(frameRate)).rounded()), 1)
    }

    /// The size to fit in, which only ever shrinks a picture.
    static func fittedSize(for size: CGSize) -> CGSize {
        let shrink = min(longestSide / max(size.width, size.height, 1), 1)
        return CGSize(width: (size.width * shrink).rounded(), height: (size.height * shrink).rounded())
    }

    /// Writes `video` as a GIF at `gif`. Cancelling stops it, and throws.
    ///
    /// A picture stays up until the next different one, so a still screen is a few frames rather than
    /// hundreds of the same one. The generator can't give a picture for a time between two of the
    /// video's frames, which is all there is on a still screen: it says it can't decode, and with any
    /// tolerance big enough to stop that it hands back the last keyframe instead. So a time with no
    /// picture of its own just leaves the last one up.
    static func make(from video: URL, to gif: URL) async throws {
        let asset = AVURLAsset(url: video)
        let length = try await asset.load(.duration).seconds
        guard length > 0, let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let size = fittedSize(for: try await track.load(.naturalSize))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = size
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let stream = try GifStream(url: gif, size: size)
        defer { stream.close() }

        var held: (image: CGImage, time: CMTime, start: Int)?
        let count = frameCount(length: length)
        for first in stride(from: 0, to: count, by: batch) {
            let indices = first..<min(first + batch, count)
            let times = indices.map { CMTime(value: CMTimeValue($0), timescale: CMTimeScale(frameRate)) }
            for await result in generator.images(for: times) {
                try Task.checkCancellation()
                guard let image = try? result.image, let time = try? result.actualTime, time != held?.time else { continue }
                let index = Int((result.requestedTime.seconds * Double(frameRate)).rounded())
                if let held { try stream.add(held.image, delay: mark(index) - mark(held.start)) }
                held = (image, time, index)
            }
        }
        guard let held else { throw Failure.noVideo }
        try stream.add(held.image, delay: max(Int((length * 100).rounded()) - mark(held.start), 1))
        try stream.finish()
    }
}

/// A GIF written a frame at a time. `CGImageDestination` keeps every picture in memory until it's
/// finalized, which took 4.6 GB for a minute of GIF and grows with the length. So each frame gets a
/// destination of its own, and what it encodes is lifted out of the little GIF that makes and added
/// to the file. A frame's block doesn't depend on anything around it, so the memory stays flat.
private final class GifStream {
    /// The longest delay a GIF can say, in hundredths of a second: nearly eleven minutes.
    private static let longestDelay = 65_535

    private let file: FileHandle

    init(url: URL, size: CGSize) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw RecordingGif.Failure.notEncoded }
        file = try FileHandle(forWritingTo: url)
        let (width, height) = (UInt16(size.width), UInt16(size.height))
        var head = Data("GIF89a".utf8)
        head.append(contentsOf: [UInt8(width & 0xff), UInt8(width >> 8), UInt8(height & 0xff), UInt8(height >> 8)])
        // No color table of its own: each frame has one. Then a background and an aspect ratio, unused.
        head.append(contentsOf: [0x70, 0, 0])
        // The loop: a count of zero is forever.
        head.append(contentsOf: [0x21, 0xff, 0x0b])
        head.append(contentsOf: Data("NETSCAPE2.0".utf8))
        head.append(contentsOf: [0x03, 0x01, 0x00, 0x00, 0x00])
        try file.write(contentsOf: head)
    }

    /// Adds a frame that stays up for `delay` hundredths of a second. One longer than a GIF can say
    /// is the same picture again.
    func add(_ image: CGImage, delay: Int) throws {
        let encoded = try autoreleasepool { () throws -> GifBlocks.Frame in
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 1, nil) else {
                throw RecordingGif.Failure.notEncoded
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination), let frame = GifBlocks.frame(in: data as Data) else {
                throw RecordingGif.Failure.notEncoded
            }
            return frame
        }
        var left = max(delay, 1)
        while left > 0 {
            let part = min(left, Self.longestDelay)
            try file.write(contentsOf: GifBlocks.graphicControl(delay: part, transparentIndex: encoded.transparentIndex))
            try file.write(contentsOf: encoded.image)
            left -= part
        }
    }

    func finish() throws {
        try file.write(contentsOf: Data([0x3b]))
    }

    func close() {
        try? file.close()
    }
}

/// The few parts of the GIF format `GifStream` needs.
enum GifBlocks {
    struct Frame: Equatable {
        /// The image descriptor, a color table of its own, and the picture.
        let image: Data
        let transparentIndex: UInt8?
    }

    /// The first frame of a whole GIF, made to stand alone, or nil if it isn't what's expected. A frame
    /// that shares the file's color table gets a copy of it.
    static func frame(in gif: Data) -> Frame? {
        let bytes = [UInt8](gif)
        guard bytes.count > 13, bytes.starts(with: Array("GIF8".utf8)) else { return nil }
        var position = 13
        var shared: ArraySlice<UInt8> = []
        var sharedSize: UInt8 = 0
        if bytes[10] & 0x80 != 0 {
            sharedSize = bytes[10] & 0x07
            let length = 3 << (Int(sharedSize) + 1)
            guard bytes.count > position + length else { return nil }
            shared = bytes[position..<(position + length)]
            position += length
        }
        var transparentIndex: UInt8?
        while position < bytes.count {
            switch bytes[position] {
            case 0x21:
                guard position + 2 < bytes.count else { return nil }
                if bytes[position + 1] == 0xf9, position + 6 < bytes.count, bytes[position + 3] & 1 != 0 {
                    transparentIndex = bytes[position + 6]
                }
                guard let end = endOfSubBlocks(in: bytes, from: position + 2) else { return nil }
                position = end
            case 0x2c:
                guard position + 10 < bytes.count else { return nil }
                let flags = bytes[position + 9]
                var image = Array(bytes[position..<(position + 9)])
                var start = position + 10
                if flags & 0x80 != 0 {
                    start += 3 << (Int(flags & 0x07) + 1)
                    guard start < bytes.count else { return nil }
                    image.append(flags)
                    image.append(contentsOf: bytes[(position + 10)..<start])
                } else {
                    guard !shared.isEmpty else { return nil }
                    image.append((flags & 0x78) | 0x80 | sharedSize)
                    image.append(contentsOf: shared)
                }
                // The code size, then the picture's blocks.
                guard let end = endOfSubBlocks(in: bytes, from: start + 1) else { return nil }
                image.append(contentsOf: bytes[start..<end])
                return Frame(image: Data(image), transparentIndex: transparentIndex)
            default:
                return nil
            }
        }
        return nil
    }

    /// Says how long a frame stays up. Each one is left in place for the next to go over, which is what
    /// a frame that fills the picture wants.
    static func graphicControl(delay: Int, transparentIndex: UInt8?) -> Data {
        let flags: UInt8 = (1 << 2) | (transparentIndex == nil ? 0 : 1)
        return Data([0x21, 0xf9, 0x04, flags, UInt8(delay & 0xff), UInt8(delay >> 8), transparentIndex ?? 0, 0])
    }

    /// Where a run of length-prefixed blocks ends, past the empty one that closes it.
    private static func endOfSubBlocks(in bytes: [UInt8], from start: Int) -> Int? {
        var position = start
        while position < bytes.count {
            let size = Int(bytes[position])
            position += size + 1
            if size == 0 { return position }
        }
        return nil
    }
}
