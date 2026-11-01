import AppKit
import CoreMedia
import ScreenCaptureKit

/// What to record, from the capture editor.
struct RecordingRequest: Equatable {
    let display: CGDirectDisplayID
    /// The selection in the display's points, from its top-left corner.
    let region: CGRect
    let scale: CGFloat
    /// Where the region is on the desktop, in AppKit's coordinates, for the outline.
    let place: CGRect
    let format: RecordFormat
}

/// What a selection comes to in pixels.
struct RecordingPlan: Equatable {
    /// H.264 won't take more on all hardware.
    static let longestSide = 3840
    /// Each side, in pixels. The real writer took every even size down to this and every frame decoded
    /// again, so what's refused is only what comes to nothing. A test keeps it to that.
    static let smallestSide = 2

    let width: Int
    let height: Int
    /// The part of the display to read, in its points from the top-left.
    let sourceRect: CGRect
    let frameRate: Int

    /// Nil when the selection is too small to record. The sides are rounded down to even, as H.264
    /// needs, and the long one kept to `longestSide`, keeping the shape.
    init?(region: CGRect, scale: CGFloat, frameRate: Int) {
        let (fullWidth, fullHeight) = (region.width * scale, region.height * scale)
        let shrink = min(CGFloat(Self.longestSide) / max(fullWidth, fullHeight, 1), 1)
        let width = Int(fullWidth * shrink) & ~1, height = Int(fullHeight * shrink) & ~1
        guard width >= Self.smallestSide, height >= Self.smallestSide else { return nil }
        self.width = width
        self.height = height
        self.frameRate = frameRate
        // Rounding down drops a pixel at most. Reading that much less keeps one point on one pixel:
        // squeezed to fit instead, every line of text in the recording would go soft.
        sourceRect = shrink < 1 ? region
            : CGRect(x: region.minX, y: region.minY, width: CGFloat(width) / scale, height: CGFloat(height) / scale)
    }

    /// Enough to keep small text sharp: an eighth of a bit or so for each pixel of each frame.
    var bitRate: Int {
        min(max(Int(Double(width * height * frameRate) * 0.12), 2_000_000), 80_000_000)
    }

    var sizeText: String { "\(width) × \(height)" }
}

/// Where a recording's frames come from. The real one is a screen stream, and the tests and the
/// self-test use one that makes frames up.
protocol RecordingSource: AnyObject {
    /// Each frame, on a queue of the source's own.
    var onFrame: ((CMSampleBuffer) -> Void)? { get set }
    /// It stopped by itself, and why, on a queue of the source's own.
    var onStop: ((Error) -> Void)? { get set }

    func start(_ request: RecordingRequest, plan: RecordingPlan) async throws
    func stop() async
}

enum RecordingFrames {
    /// Whether a frame has a new picture. Idle ones have no image, only the time passing.
    static func isComplete(_ attachments: [SCStreamFrameInfo: Any]?) -> Bool {
        guard let raw = attachments?[.status] as? Int else { return false }
        return SCFrameStatus(rawValue: raw) == .complete
    }

    static func attachments(of sample: CMSampleBuffer) -> [SCStreamFrameInfo: Any]? {
        (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first
    }
}

/// The real thing: a stream of one display, less everything of Dynotch's.
final class ScreenStreamSource: NSObject, RecordingSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum Failure: Error {
        case scratchRun, noDisplay, noOwnApplication
    }

    var onFrame: ((CMSampleBuffer) -> Void)?
    var onStop: ((Error) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "app.dynotch.recording.stream", qos: .userInitiated)

    /// A run on scratch defaults, like a test or a snapshot, never reads the real screen, whatever it
    /// clicks. Built in rather than left to care.
    static func mayRun(on defaults: UserDefaults) -> Bool {
        defaults === UserDefaults.standard
    }

    func start(_ request: RecordingRequest, plan: RecordingPlan) async throws {
        guard Self.mayRun(on: UserDefaults.dynotch) else { throw Failure.scratchRun }
        // Fresh, not the freeze's: displays and windows may have changed since.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == request.display }) else { throw Failure.noDisplay }
        let pid = ProcessInfo.processInfo.processIdentifier
        let own = content.applications.filter { $0.processID == pid }
        // Without this the notch would be in the recording, which it's never to be.
        guard !own.isEmpty else { throw Failure.noOwnApplication }
        // The application rather than a list of windows, so windows Dynotch opens later stay out too.
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = plan.sourceRect
        configuration.width = plan.width
        configuration.height = plan.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(plan.frameRate))
        configuration.queueDepth = 6
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.captureResolution = .best
        configuration.showsCursor = true
        configuration.capturesAudio = false
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, RecordingFrames.isComplete(RecordingFrames.attachments(of: sampleBuffer)) else { return }
        onFrame?(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }
}
