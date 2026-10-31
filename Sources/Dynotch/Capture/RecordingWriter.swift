import AVFoundation
import CoreMedia

/// Writes a recording's frames into an MP4, on a queue of its own, and finishes the file itself
/// whatever happened to what was feeding it. It knows nothing of where the frames come from.
///
/// Not `SCRecordingOutput`, which owns its file and says nothing of what's left when the stream dies.
/// An MP4 that's never finished has no index and is lost, and here finishing is Dynotch's to do.
final class RecordingWriter: @unchecked Sendable {
    /// What became of the file.
    enum Outcome: Equatable {
        /// It's whole.
        case finished
        /// The writer failed, and what's on disk still plays. The string says what went wrong.
        case partial(String)
        /// The writer failed and nothing could be kept, so no file is left.
        case failed(String)
        /// Not one frame came, so no file is left.
        case noFrames
    }

    /// Written out this often, so that a file nobody got to finish still opens up to the last one.
    /// Tried for real: a process that `_exit`ed mid-recording left an MP4 that opened and decoded up to
    /// its last fragment, where one without them wouldn't open at all. Finishing makes it an ordinary
    /// MP4, with no fragments left in it.
    static let fragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)

    /// Told once if the writer fails, on the writer's queue.
    var onFailure: (@Sendable (Error) -> Void)?

    private let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let frameDuration: CMTime
    private let queue = DispatchQueue(label: "app.dynotch.recording.writer", qos: .userInitiated)
    /// Seconds on a clock that never jumps, for how long a recording has run.
    private let clock: @Sendable () -> TimeInterval
    /// The first frame's time, and when it came.
    private var first: (time: CMTime, arrived: TimeInterval)?
    private var last: CMTime?
    /// Takes no more frames: it's been finished, or it failed.
    private var isClosed = false
    private var failure: Error?
    /// For a test: acts on the next frame as if the disk had filled.
    private var simulatedFailure: Error?
    /// Frames the writer hadn't room for. Dropping one costs a frame; waiting would stall the stream.
    private(set) var dropped = 0

    /// Starts the file straight away, so that a folder that can't be written says so before any recording starts.
    init(url: URL, plan: RecordingPlan,
         clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws {
        self.url = url
        self.clock = clock
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(plan.frameRate))
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.movieFragmentInterval = Self.fragmentInterval
        input = AVAssetWriterInput(mediaType: .video, outputSettings: Self.settings(for: plan))
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw CocoaError(.fileWriteUnknown) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// Takes a frame, from any queue, without waiting. After the end, frames are ignored.
    func append(_ sample: CMSampleBuffer) {
        queue.async { [self] in
            guard !isClosed else { return }
            write(sample)
        }
    }

    /// Ends the file, once, at `end`: by default the moment of asking rather than the last frame's time,
    /// so a still screen keeps its length. Frames that come after that are ignored.
    func finish(at end: CMTime? = nil) async -> Outcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            queue.async { [self] in
                isClosed = true
                if let failure {
                    keepWhatPlays(after: failure, continuation)
                    return
                }
                guard let first, let last else {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: url)
                    continuation.resume(returning: .noFrames)
                    return
                }
                // It can fail between frames, with nothing yet to say so, and ending a session then raises.
                guard writer.status == .writing else {
                    keepWhatPlays(after: writer.error ?? CocoaError(.fileWriteUnknown), continuation)
                    return
                }
                let stop = end ?? CMTimeAdd(first.time, CMTime(seconds: clock() - first.arrived, preferredTimescale: 600))
                input.markAsFinished()
                // Never before the last frame has had its moment.
                writer.endSession(atSourceTime: CMTimeMaximum(stop, CMTimeAdd(last, frameDuration)))
                writer.finishWriting { [self] in
                    queue.async { [self] in
                        if writer.status == .completed {
                            continuation.resume(returning: .finished)
                        } else {
                            keepWhatPlays(after: writer.error ?? CocoaError(.fileWriteUnknown), continuation)
                        }
                    }
                }
            }
        }
    }

    /// Fails on the next frame, as a full disk would, for a test.
    func simulateFailure(_ error: Error) {
        queue.async { [self] in simulatedFailure = error }
    }

    // MARK: Private

    private func write(_ sample: CMSampleBuffer) {
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard time.isNumeric else { return }
        if let simulatedFailure {
            fail(simulatedFailure)
            return
        }
        guard writer.status == .writing else {
            fail(writer.error ?? CocoaError(.fileWriteUnknown))
            return
        }
        if first == nil {
            writer.startSession(atSourceTime: time)
            first = (time, clock())
        } else if let last, time <= last {
            // A frame out of order would fail the whole file.
            return
        }
        guard input.isReadyForMoreMediaData else {
            dropped += 1
            return
        }
        if input.append(sample) {
            last = time
        } else {
            fail(writer.error ?? CocoaError(.fileWriteUnknown))
        }
    }

    private func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        isClosed = true
        onFailure?(error)
    }

    /// After a failure there's no finishing the file, but its fragments so far may play.
    private func keepWhatPlays(after error: Error, _ continuation: CheckedContinuation<Outcome, Never>) {
        let reason = Self.reason(for: error, at: url)
        guard last != nil else {
            try? FileManager.default.removeItem(at: url)
            continuation.resume(returning: .failed(reason))
            return
        }
        let url = url
        Task {
            if await Self.isPlayable(url) {
                continuation.resume(returning: .partial(reason))
            } else {
                try? FileManager.default.removeItem(at: url)
                continuation.resume(returning: .failed(reason))
            }
        }
    }

    /// Whether a file opens, with a video track and some length to it.
    static func isPlayable(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let (playable, duration, tracks) = try? await asset.load(.isPlayable, .duration, .tracks) else { return false }
        return playable && duration.seconds > 0 && tracks.contains { $0.mediaType == .video }
    }

    /// What went wrong, as a person would say it. AVFoundation's own words are about the operation,
    /// and the real cause is underneath them.
    static func reason(for error: Error, at url: URL) -> String {
        let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        let isFull = [error as NSError, underlying].compactMap { $0 }.contains { error in
            error.domain == NSPOSIXErrorDomain && (error.code == ENOSPC || error.code == EDQUOT)
        }
        let folder = url.deletingLastPathComponent()
        let room = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity
        if isFull || room.map({ $0 < 50_000_000 }) == true { return "The disk is full" }
        return "The file couldn't be written"
    }

    private static func settings(for plan: RecordingPlan) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: plan.width,
            AVVideoHeightKey: plan.height,
            // sRGB's primaries are 709's, so what comes out matches what was on screen.
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: plan.bitRate,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoExpectedSourceFrameRateKey: plan.frameRate,
                // As often as the fragments, so a file nobody finished can be read from each one.
                AVVideoMaxKeyFrameIntervalDurationKey: fragmentInterval.seconds,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
    }
}
