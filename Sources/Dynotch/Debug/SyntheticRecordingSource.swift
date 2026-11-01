import CoreMedia
import CoreVideo
import Foundation

/// A recording source that makes its frames up, for the tests and the capture self-test, so nothing
/// reads the real screen. Frames go out when it's told, one tick of the recording's frame rate apart.
final class SyntheticRecordingSource: RecordingSource {
    var onFrame: ((CMSampleBuffer) -> Void)?
    var onStop: ((Error) -> Void)?

    /// What `start` throws, for a stream that won't start.
    var startError: Error?
    /// Holds `start` until a test lets it go, for a stop while it's starting.
    var holdsStart = false
    private(set) var plan: RecordingPlan?
    private(set) var isRunning = false
    private(set) var stopCount = 0
    private var release: CheckedContinuation<Void, Never>?
    private var sent = 0

    func start(_ request: RecordingRequest, plan: RecordingPlan) async throws {
        self.plan = plan
        if holdsStart { await withCheckedContinuation { release = $0 } }
        if let startError { throw startError }
        isRunning = true
    }

    func stop() async {
        stopCount += 1
        isRunning = false
    }

    /// Lets a held `start` go on.
    func letStart() {
        release?.resume()
        release = nil
    }

    /// Sends this many frames, each a little different from the last.
    func send(_ count: Int) {
        guard let plan else { return }
        for _ in 0..<count {
            let time = CMTime(value: CMTimeValue(1_000 + sent), timescale: CMTimeScale(plan.frameRate))
            if let sample = Self.frame(width: plan.width, height: plan.height, index: sent, at: time) { onFrame?(sample) }
            sent += 1
        }
    }

    /// The stream stopping by itself.
    func stops(with error: Error) {
        isRunning = false
        onStop?(error)
    }

    /// A frame as a stream's would be: BGRA in an IOSurface, with no decode time. Gray bands that move
    /// with `index`, a row at a time: the tests make these on the main actor, in a debug build, and
    /// going pixel by pixel there starved everything else.
    static func frame(width: Int, height: Int, index: Int, at time: CMTime) -> CMSampleBuffer? {
        var pixels: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &pixels) == kCVReturnSuccess,
              let pixels else { return nil }
        CVPixelBufferLockBaseAddress(pixels, [])
        if let base = CVPixelBufferGetBaseAddress(pixels) {
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            for y in 0..<height {
                memset(base + y * stride, Int32((y + index * 4) % 256), stride)
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels, formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        return sample
    }
}
