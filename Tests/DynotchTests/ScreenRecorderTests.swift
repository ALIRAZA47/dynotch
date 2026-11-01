import AppKit
import AVFoundation
import ImageIO
import ScreenCaptureKit
import Testing
@testable import Dynotch

/// A recorder with everything it reaches for swapped out: frames made up, a Tray and a save folder in
/// a scratch folder, and the notices collected. Nothing here reads the screen or touches the real Tray.
@MainActor
private final class Rig {
    let folder: URL
    let saves: URL
    let tray: TrayStore
    let source = SyntheticRecordingSource()
    var notices: [LiveNotice] = []
    private(set) var recorder: ScreenRecorder!

    init(saves saveFolder: URL? = nil) throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-tests-\(UUID().uuidString)", isDirectory: true)
        saves = saveFolder ?? folder.appendingPathComponent("Saves", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Saves", isDirectory: true), withIntermediateDirectories: true)
        tray = TrayStore(support: folder)
        let source = source
        recorder = ScreenRecorder(makeSource: { source }, tray: tray, saveFolder: saves) { [weak self] notice, _ in
            self?.notices.append(notice)
        }
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    static let display: CGDirectDisplayID = 77

    func request(_ format: RecordFormat = .mp4, region: CGRect = CGRect(x: 10, y: 10, width: 64, height: 48)) -> RecordingRequest {
        RecordingRequest(display: Self.display, region: region, scale: 1, place: CGRect(x: 100, y: 100, width: 64, height: 48), format: format)
    }

    /// Started, with `frames` frames written.
    func record(_ format: RecordFormat = .mp4, frames: Int = 30) async {
        recorder.start(request(format))
        await recorder.starting?.value
        source.send(frames)
    }

    /// As a stream sends them, one at a time. A burst would be more than the writer has room for.
    func pace(frames: Int) async throws {
        for _ in 0..<frames {
            source.send(1)
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Waits for the file to land.
    func landed() async {
        await recorder.saving?.value
    }

    func saved() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: saves.path)) ?? []).map(saves.appendingPathComponent)
    }

    func trayFiles() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: tray.folder.path)) ?? []
    }
}

private func plan(_ width: Int, _ height: Int, frameRate: Int = 60) -> RecordingPlan {
    RecordingPlan(region: CGRect(x: 0, y: 0, width: width, height: height), scale: 1, frameRate: frameRate)!
}

private func scratchFile(_ name: String = "movie.mp4") throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appendingPathComponent(name)
}

/// Frames through a real writer, a little apart so it never has to drop one.
private func write(_ count: Int, to writer: RecordingWriter, plan: RecordingPlan, from start: Int = 0) async throws {
    for index in start..<(start + count) {
        let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(plan.frameRate))
        writer.append(try #require(SyntheticRecordingSource.frame(width: plan.width, height: plan.height, index: index, at: time)))
        try await Task.sleep(for: .milliseconds(1))
    }
}

struct RecordingPlanTests {
    @Test func aRegionIsItsPixelsAtTheDisplaysScale() throws {
        let plan = try #require(RecordingPlan(region: CGRect(x: 10, y: 20, width: 640, height: 400), scale: 2, frameRate: 60))
        #expect((plan.width, plan.height) == (1280, 800))
        #expect(plan.sourceRect == CGRect(x: 10, y: 20, width: 640, height: 400))
    }

    @Test func sidesRoundDownToEvenAndOnePointStaysOnePixel() throws {
        let plan = try #require(RecordingPlan(region: CGRect(x: 3, y: 4, width: 641, height: 401), scale: 1, frameRate: 60))
        #expect((plan.width, plan.height) == (640, 400))
        #expect(plan.sourceRect == CGRect(x: 3, y: 4, width: 640, height: 400))
    }

    @Test func theLongSideStopsAt3840KeepingTheShape() throws {
        let plan = try #require(RecordingPlan(region: CGRect(x: 0, y: 0, width: 2560, height: 1440), scale: 2, frameRate: 60))
        #expect((plan.width, plan.height) == (3840, 2160))
        #expect(plan.sourceRect == CGRect(x: 0, y: 0, width: 2560, height: 1440))
        let tall = try #require(RecordingPlan(region: CGRect(x: 0, y: 0, width: 1000, height: 3000), scale: 2, frameRate: 60))
        #expect((tall.width, tall.height) == (1280, 3840))
    }

    @Test func tooSmallToRecordIsNoPlan() {
        #expect(RecordingPlan(region: CGRect(x: 0, y: 0, width: 1, height: 100), scale: 1, frameRate: 60) == nil)
        #expect(RecordingPlan(region: CGRect(x: 0, y: 0, width: 100, height: 1), scale: 1, frameRate: 60) == nil)
        #expect(RecordingPlan(region: CGRect(x: 0, y: 0, width: 1, height: 1), scale: 2, frameRate: 60) != nil)
    }

    @Test func theSmallestPlanIsOneTheRealWriterTakes() async throws {
        let side = RecordingPlan.smallestSide
        let plan = try #require(RecordingPlan(region: CGRect(x: 0, y: 0, width: side, height: side), scale: 1, frameRate: 60))
        let url = try scratchFile()
        let writer = try RecordingWriter(url: url, plan: plan)
        try await write(6, to: writer, plan: plan)
        #expect(await writer.finish() == .finished)
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: side, height: side))
    }

    @Test func theBitRateGrowsWithThePixelsAndStopsAtEachEnd() {
        #expect(plan(1920, 1080).bitRate > plan(1280, 720).bitRate)
        #expect(plan(1920, 1080, frameRate: 60).bitRate > plan(1920, 1080, frameRate: 15).bitRate)
        #expect(plan(16, 16).bitRate == 2_000_000)
        #expect(plan(3840, 3840).bitRate == 80_000_000)
    }
}

struct RecordingFramesTests {
    @Test func onlyACompleteFrameCounts() {
        #expect(RecordingFrames.isComplete([.status: SCFrameStatus.complete.rawValue]))
        for status in [SCFrameStatus.idle, .blank, .suspended, .started, .stopped] {
            #expect(!RecordingFrames.isComplete([.status: status.rawValue]))
        }
    }

    @Test func aFrameThatSaysNothingDoesntCount() {
        #expect(!RecordingFrames.isComplete(nil))
        #expect(!RecordingFrames.isComplete([:]))
        #expect(!RecordingFrames.isComplete([.status: "complete"]))
    }

    @Test func aRunOnScratchDefaultsNeverReachesTheRealStream() {
        #expect(!ScreenStreamSource.mayRun(on: UserDefaults(suiteName: "app.dynotch.not-the-real-one")!))
        #expect(ScreenStreamSource.mayRun(on: .standard))
    }
}

struct RecordingWriterTests {
    @Test func itMakesAPlayableMP4OfTheRightSizeAndLengthWithNoSound() async throws {
        let plan = plan(320, 200)
        let url = try scratchFile()
        let writer = try RecordingWriter(url: url, plan: plan)
        try await write(120, to: writer, plan: plan)
        #expect(await writer.finish(at: CMTime(value: 120, timescale: 60)) == .finished)

        #expect(await RecordingWriter.isPlayable(url))
        let asset = AVURLAsset(url: url)
        #expect(abs(try await asset.load(.duration).seconds - 2) < 0.05)
        let video = try await asset.loadTracks(withMediaType: .video)
        #expect(video.count == 1)
        #expect(try await video[0].load(.naturalSize) == CGSize(width: 320, height: 200))
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
    }

    /// Only idle frames come while nothing moves, so the last picture has to last until the stop.
    @Test func aStillScreenKeepsItsLength() async throws {
        let plan = plan(160, 120)
        let url = try scratchFile()
        let writer = try RecordingWriter(url: url, plan: plan)
        try await write(2, to: writer, plan: plan)
        #expect(await writer.finish(at: CMTime(seconds: 3, preferredTimescale: 600)) == .finished)
        #expect(abs(try await AVURLAsset(url: url).load(.duration).seconds - 3) < 0.05)
    }

    @Test func theEndIsTheMomentOfAskingByDefault() async throws {
        let plan = plan(160, 120)
        let url = try scratchFile()
        let now = Clock(100)
        let writer = try RecordingWriter(url: url, plan: plan, clock: { now.seconds })
        try await write(2, to: writer, plan: plan)
        now.seconds = 102.5
        #expect(await writer.finish() == .finished)
        #expect(abs(try await AVURLAsset(url: url).load(.duration).seconds - 2.5) < 0.05)
    }

    private final class Clock: @unchecked Sendable {
        var seconds: TimeInterval
        init(_ seconds: TimeInterval) { self.seconds = seconds }
    }

    @Test func framesAfterTheEndAreIgnored() async throws {
        let plan = plan(160, 120)
        let url = try scratchFile()
        let writer = try RecordingWriter(url: url, plan: plan)
        try await write(30, to: writer, plan: plan)
        #expect(await writer.finish(at: CMTime(value: 30, timescale: 60)) == .finished)
        try await write(30, to: writer, plan: plan, from: 30)
        #expect(abs(try await AVURLAsset(url: url).load(.duration).seconds - 0.5) < 0.05)
    }

    @Test func aFrameOutOfOrderDoesntFailTheFile() async throws {
        let plan = plan(160, 120)
        let url = try scratchFile()
        let writer = try RecordingWriter(url: url, plan: plan)
        try await write(30, to: writer, plan: plan, from: 30)
        try await write(10, to: writer, plan: plan)
        #expect(await writer.finish() == .finished)
    }

    @Test func noFramesLeavesNoFile() async throws {
        let url = try scratchFile()
        let writer = try RecordingWriter(url: url, plan: plan(160, 120))
        #expect(await writer.finish() == .noFrames)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aFolderThatCantBeWrittenFailsBeforeAnythingStarts() throws {
        let url = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/movie.mp4")
        #expect(throws: (any Error).self) { try RecordingWriter(url: url, plan: plan(160, 120)) }
    }

    /// As a full disk does: a fragment or two have reached the file by then, and they're kept. A real
    /// write failure on a scratch file, from a file size limit, left the same thing behind.
    @Test func aFailedWriterKeepsWhatPlays() async throws {
        let plan = plan(160, 120)
        let url = try scratchFile()
        let writer = try RecordingWriter(url: url, plan: plan)
        try await write(300, to: writer, plan: plan)
        writer.simulateFailure(CocoaError(.fileWriteOutOfSpace))
        try await write(1, to: writer, plan: plan, from: 300)
        if case .partial = await writer.finish() {} else { Issue.record("nothing was kept") }
        #expect(await RecordingWriter.isPlayable(url))
    }

    @Test func aFailureBeforeTheFirstFragmentLeavesNoFile() async throws {
        let plan = plan(160, 120)
        let url = try scratchFile()
        let writer = try RecordingWriter(url: url, plan: plan)
        writer.simulateFailure(CocoaError(.fileWriteOutOfSpace))
        try await write(1, to: writer, plan: plan)
        #expect(await writer.finish() == .failed("The file couldn't be written"))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aFullDiskIsSaidPlainly() {
        let full = NSError(domain: AVFoundationErrorDomain, code: AVError.unknown.rawValue, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)),
        ])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("movie.mp4")
        #expect(RecordingWriter.reason(for: full, at: url) == "The disk is full")
        #expect(RecordingWriter.reason(for: CocoaError(.fileWriteUnknown), at: url) == "The file couldn't be written")
    }
}

@MainActor
struct RecordingGifTests {
    @Test func framesTakeTurnsRoundingUp() {
        #expect(RecordingGif.mark(15) == 100)
        #expect(RecordingGif.mark(900) == 6000)
        let delays = (0..<15).map { RecordingGif.mark($0 + 1) - RecordingGif.mark($0) }
        #expect(delays.reduce(0, +) == 100)
        #expect(delays.allSatisfy { $0 == 6 || $0 == 7 })
    }

    /// Reads every frame's delay back, in hundredths of a second, with what the file says about looping.
    private func read(_ gif: URL) throws -> (delays: [Int], loop: Int?, first: CGImage) {
        let source = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
        let file = try #require(CGImageSourceCopyProperties(source, nil) as? [CFString: Any])
        let loop = (file[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int
        let delays = try (0..<CGImageSourceGetCount(source)).map { index -> Int in
            let frame = try #require(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
            let seconds = try #require((frame[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            return Int((seconds * 100).rounded())
        }
        return (delays, loop, try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)))
    }

    /// Only idle frames come while nothing moves, so the video has gaps, which the generator can't
    /// read. The picture stays up across them, as one frame.
    @Test func aStillScreensGifIsAFewFramesAndKeepsItsLength() async throws {
        let plan = plan(320, 200, frameRate: RecordingGif.frameRate)
        let video = try scratchFile()
        let writer = try RecordingWriter(url: video, plan: plan)
        for index in [0, 30, 60] {
            let time = CMTime(value: CMTimeValue(index), timescale: 15)
            writer.append(try #require(SyntheticRecordingSource.frame(width: 320, height: 200, index: index, at: time)))
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await writer.finish(at: CMTime(value: 90, timescale: 15)) == .finished)

        let gif = video.deletingPathExtension().appendingPathExtension("gif")
        try await RecordingGif.make(from: video, to: gif)
        let (delays, loop, _) = try read(gif)
        #expect(delays == [200, 200, 200])
        #expect(loop == 0)
    }

    @Test func oneFrameOfGifIsAWholeGif() async throws {
        let plan = plan(320, 200, frameRate: RecordingGif.frameRate)
        let video = try scratchFile()
        let writer = try RecordingWriter(url: video, plan: plan)
        try await write(1, to: writer, plan: plan)
        #expect(await writer.finish(at: CMTime(value: 15, timescale: 15)) == .finished)
        let gif = video.deletingPathExtension().appendingPathExtension("gif")
        try await RecordingGif.make(from: video, to: gif)
        #expect(try read(gif).delays == [100])
    }

    @Test func aFrameTakesItsColorsWithIt() throws {
        // A one-pixel GIF with a two-color table of its own, as a file would share it.
        let table: [UInt8] = [10, 20, 30, 40, 50, 60]
        var gif = Array("GIF89a".utf8) + [1, 0, 1, 0, 0x80, 0, 0] + table
        gif += [0x21, 0xf9, 0x04, 0x01, 0, 0, 1, 0]
        let picture: [UInt8] = [0x2c, 0, 0, 0, 0, 1, 0, 1, 0, 0x00]
        let data: [UInt8] = [0x02, 0x02, 0x44, 0x01, 0x00]
        gif += picture + data + [0x3b]

        let frame = try #require(GifBlocks.frame(in: Data(gif)))
        #expect(frame.transparentIndex == 1)
        #expect(Array(frame.image) == Array(picture.dropLast()) + [0x80] + table + data)
    }

    @Test func somethingElseIsntAFrame() {
        #expect(GifBlocks.frame(in: Data("not a gif at all, not one bit".utf8)) == nil)
        #expect(GifBlocks.frame(in: Data(Array("GIF89a".utf8) + [1, 0, 1, 0, 0, 0, 0, 0x3b])) == nil)
    }

    @Test func framesFollowTheLength() {
        #expect(RecordingGif.frameCount(length: 2) == 30)
        #expect(RecordingGif.frameCount(length: 0.01) == 1)
    }

    @Test func onlyABigPictureShrinks() {
        #expect(RecordingGif.fittedSize(for: CGSize(width: 1920, height: 1080)) == CGSize(width: 960, height: 540))
        #expect(RecordingGif.fittedSize(for: CGSize(width: 1080, height: 1920)) == CGSize(width: 540, height: 960))
        #expect(RecordingGif.fittedSize(for: CGSize(width: 320, height: 200)) == CGSize(width: 320, height: 200))
    }

    @Test func aGifHasItsFramesItsLoopAndItsLength() async throws {
        let plan = plan(1280, 720, frameRate: RecordingGif.frameRate)
        let video = try scratchFile()
        let writer = try RecordingWriter(url: video, plan: plan)
        try await write(30, to: writer, plan: plan)
        #expect(await writer.finish(at: CMTime(value: 30, timescale: 15)) == .finished)

        let gif = video.deletingPathExtension().appendingPathExtension("gif")
        try await RecordingGif.make(from: video, to: gif)

        let (delays, loop, first) = try read(gif)
        // Every frame the writer took. At this size it can drop one if it's sent them too fast.
        #expect(delays.count == 30 - writer.dropped)
        #expect(loop == 0)
        #expect(delays.reduce(0, +) == 200)
        #expect((first.width, first.height) == (960, 540))
    }

    @Test func cancellingStopsIt() async throws {
        let plan = plan(320, 200, frameRate: RecordingGif.frameRate)
        let video = try scratchFile()
        let writer = try RecordingWriter(url: video, plan: plan)
        try await write(30, to: writer, plan: plan)
        #expect(await writer.finish() == .finished)
        let gif = video.deletingPathExtension().appendingPathExtension("gif")
        let making = Task.detached { try await RecordingGif.make(from: video, to: gif) }
        making.cancel()
        await #expect(throws: (any Error).self) { try await making.value }
    }

    @Test func aFileThatIsntAVideoIsAFailure() async throws {
        let video = try scratchFile()
        try Data("not a movie".utf8).write(to: video)
        await #expect(throws: (any Error).self) {
            try await RecordingGif.make(from: video, to: video.deletingPathExtension().appendingPathExtension("gif"))
        }
    }
}

/// `.serialized`, because posting the sleep and screen notifications reaches every recorder there is.
@MainActor
@Suite(.serialized)
struct ScreenRecorderTests {
    init() {
        SnapshotRenderer.useScratchDefaults()
    }

    // MARK: A recording's life

    @Test func aRecordingGoesThroughItsStates() async throws {
        let rig = try Rig()
        let recorder = rig.recorder!
        #expect(recorder.state == .idle)
        recorder.start(rig.request())
        #expect(recorder.state == .starting)
        #expect(recorder.isRunning)
        await recorder.starting?.value
        guard case .recording = recorder.state else {
            Issue.record("not recording: \(recorder.state)")
            return
        }
        #expect(recorder.plan?.sizeText == "64 × 48")
        #expect(rig.source.plan?.frameRate == 60)
        rig.source.send(10)
        recorder.stop()
        #expect(recorder.state == .saving)
        #expect(!recorder.isRunning)
        #expect(recorder.isBusy)
        await rig.landed()
        #expect(recorder.state == .idle)
        #expect(!recorder.isBusy)
        #expect(rig.source.stopCount == 1)
    }

    @Test func aFileLandsInTheSaveFolderAndTheTray() async throws {
        let rig = try Rig()
        await rig.record()
        rig.recorder.stop()
        await rig.landed()

        let file = try #require(rig.saved().first)
        #expect(rig.saved().count == 1)
        #expect(file.lastPathComponent.hasPrefix("Screen Recording "))
        #expect(file.pathExtension == "mp4")
        #expect(await RecordingWriter.isPlayable(file))
        #expect(rig.tray.urls == [file])
        // By hand as far as the Tray goes, so tidying leaves it, and whatever `screenshotsToTray` says.
        #expect(rig.tray.items.first?.isAutomatic == false)
        // The watcher would post a second notice for a tagged file.
        #expect(getxattr(file.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) <= 0)
        #expect(getxattr(file.path, "com.apple.metadata:kMDItemIsScreenRecording", nil, 0, 0, 0) <= 0)
        // Nothing stays behind under the hidden name.
        #expect(rig.trayFiles().isEmpty)
    }

    @Test func theNoticeNamesTheFileWithItsButtons() async throws {
        let rig = try Rig()
        await rig.record()
        rig.recorder.stop()
        await rig.landed()

        let file = try #require(rig.saved().first)
        let notice = try #require(rig.notices.last)
        #expect(rig.notices.count == 1)
        #expect(notice.text == "Saved")
        #expect(notice.detail == file.lastPathComponent)
        #expect(notice.actions == [NoticeAction(title: "Open", kind: .openFile(file)), NoticeAction(title: "Show", kind: .reveal(file))])
        #expect(notice.recall == .whole)
    }

    @Test func aFileIsNamedAsMacOSNamesItsOwn() {
        var parts = DateComponents()
        (parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second) = (2026, 10, 31, 18, 2, 6)
        let date = Calendar.current.date(from: parts)!
        #expect(ScreenRecorder.fileName(at: date) == "Screen Recording 2026-10-31 at 18.02.06")
    }

    @Test func aNameThatsTakenGetsANumberAndTheFileThereIsLeftAlone() async throws {
        let rig = try Rig()
        await rig.record()
        // Whatever the second it starts in, one of these is the name it wants.
        let start = Date.now
        let bytes = Data("somebody's file".utf8)
        for offset in -3...3 {
            let name = ScreenRecorder.fileName(at: start.addingTimeInterval(TimeInterval(offset))) + ".mp4"
            try bytes.write(to: rig.saves.appendingPathComponent(name))
        }
        rig.recorder.stop()
        await rig.landed()

        let landed = try #require(rig.tray.urls.first)
        #expect(landed.lastPathComponent.hasSuffix(" 2.mp4"))
        #expect(await RecordingWriter.isPlayable(landed))
        let others = rig.saved().filter { $0 != landed }
        #expect(others.count == 7)
        for file in others { #expect(try Data(contentsOf: file) == bytes) }
    }

    @Test func aSaveFolderThatCantBeWrittenLeavesItInTheTraysFolder() async throws {
        let rig = try Rig(saves: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)", isDirectory: true))
        await rig.record()
        rig.recorder.stop()
        await rig.landed()

        let landed = try #require(rig.tray.urls.first)
        #expect(landed.deletingLastPathComponent().standardizedFileURL == rig.tray.folder.standardizedFileURL)
        #expect(landed.lastPathComponent.hasPrefix("Screen Recording "))
        #expect(await RecordingWriter.isPlayable(landed))
        #expect(rig.tray.items.first?.isOwned == true)
        #expect(rig.notices.last?.detail == landed.lastPathComponent)
    }

    // MARK: Endings

    @Test func macOSsStopControlIsAnOrdinaryStop() async throws {
        let rig = try Rig()
        await rig.record()
        rig.source.stops(with: NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userStopped.rawValue))
        try await waitForSaving(rig)
        await rig.landed()
        #expect(rig.notices.last?.text == "Saved")
        #expect(rig.saved().count == 1)
    }

    /// -3821 is `systemStoppedStream`, which the deployment target can't name.
    @Test func aStreamMacOSStoppedSaysSo() async throws {
        let rig = try Rig()
        await rig.record()
        rig.source.stops(with: NSError(domain: SCStreamErrorDomain, code: -3821))
        try await waitForSaving(rig)
        await rig.landed()
        let file = try #require(rig.saved().first)
        #expect(rig.notices.last?.text == "Stopped by macOS")
        #expect(rig.notices.last?.detail == "Saved as \(file.lastPathComponent)")
        #expect(await RecordingWriter.isPlayable(file))
    }

    @Test func anyOtherStreamErrorSaysItStopped() {
        #expect(ScreenRecorder.Ending(streamError: NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.noCaptureSource.rawValue)) == .stopped)
        #expect(ScreenRecorder.Ending(streamError: CocoaError(.fileWriteUnknown)) == .stopped)
        // Not the stop control's number in another domain.
        #expect(ScreenRecorder.Ending(streamError: NSError(domain: "other", code: SCStreamError.Code.userStopped.rawValue)) == .stopped)
    }

    @Test func aDisplayThatGoesAwayEndsItThroughTheScreensNotification() async throws {
        let rig = try Rig()
        await rig.record()
        // The made-up display isn't among the real ones, so as far as this goes it's just gone.
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(rig.recorder.state == .saving)
        await rig.landed()
        let file = try #require(rig.saved().first)
        #expect(rig.notices.last?.text == "Display gone")
        #expect(rig.notices.last?.detail == "Saved as \(file.lastPathComponent)")
        #expect(await RecordingWriter.isPlayable(file))
    }

    @Test func displaysAreComparedByTheirIDs() {
        #expect(ScreenRecorder.isGone(5, from: [1, 2]))
        #expect(!ScreenRecorder.isGone(2, from: [1, 2]))
        #expect(ScreenRecorder.isGone(5, from: []))
    }

    @Test func sleepingEndsIt() async throws {
        let rig = try Rig()
        await rig.record()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(rig.recorder.state == .saving)
        await rig.landed()
        let file = try #require(rig.saved().first)
        #expect(rig.notices.last?.text == "Mac sleeping")
        #expect(await RecordingWriter.isPlayable(file))
    }

    @Test func quittingFinishesThenReplies() async throws {
        let rig = try Rig()
        await rig.record()
        var replied = false
        rig.recorder.finishBeforeQuitting(within: 30) { replied = true }
        #expect(!replied)
        await rig.landed()
        #expect(replied)
        #expect(rig.recorder.state == .idle)
        #expect(await RecordingWriter.isPlayable(try #require(rig.saved().first)))
    }

    @Test func quittingWithNothingGoingOnRepliesAtOnce() throws {
        let rig = try Rig()
        var replied = false
        rig.recorder.finishBeforeQuitting { replied = true }
        #expect(replied)
    }

    @Test func aGifGivesWayToQuittingAndItsMP4Lands() async throws {
        let rig = try Rig()
        rig.recorder.convert = { _, _ in
            try await Task.sleep(for: .seconds(60))
        }
        await rig.record(.gif)
        rig.recorder.stop()
        // Long enough for the conversion to have started.
        try await Task.sleep(for: .milliseconds(200))
        var replied = false
        rig.recorder.finishBeforeQuitting(within: 30) { replied = true }
        await rig.landed()
        #expect(replied)
        #expect(try #require(rig.saved().first).pathExtension == "mp4")
    }

    @Test func aStuckWriterCantHoldUpQuittingPastTheLimit() async throws {
        let rig = try Rig()
        // One that takes no notice of being cancelled, like a writer that's stuck.
        rig.recorder.convert = { _, _ in
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        }
        await rig.record(.gif)
        rig.recorder.stop()
        try await Task.sleep(for: .milliseconds(200))
        var replied = false
        rig.recorder.finishBeforeQuitting(within: 0.2) { replied = true }
        #expect(!replied)
        try await Task.sleep(for: .milliseconds(400))
        #expect(replied)
    }

    @Test func aWriterThatFailsStopsItAndKeepsWhatPlays() async throws {
        let rig = try Rig()
        rig.recorder.start(rig.request())
        await rig.recorder.starting?.value
        // Over two seconds of frames, for a fragment to reach the file.
        try await rig.pace(frames: 160)
        try #require(rig.recorder.writer).simulateFailure(CocoaError(.fileWriteOutOfSpace))
        rig.source.send(1)
        try await waitForSaving(rig)
        await rig.landed()

        let file = try #require(rig.saved().first)
        #expect(await RecordingWriter.isPlayable(file))
        #expect(rig.tray.urls == [file])
        let notice = try #require(rig.notices.last)
        #expect(notice.text == "Stopped")
        #expect(notice.detail == "The file couldn't be written. Kept \(file.lastPathComponent)")
    }

    @Test func aWriterThatFailsWithNothingPlayableSaysSoAndLeavesNoFile() async throws {
        let rig = try Rig()
        await rig.record(frames: 2)
        try #require(rig.recorder.writer).simulateFailure(CocoaError(.fileWriteOutOfSpace))
        rig.source.send(1)
        try await waitForSaving(rig)
        await rig.landed()
        #expect(rig.saved().isEmpty)
        #expect(rig.tray.urls.isEmpty)
        #expect(rig.trayFiles().isEmpty)
        #expect(rig.notices.last?.text == "Not saved")
        #expect(rig.notices.last?.detail == "The file couldn't be written. Nothing could be kept")
    }

    private func waitForSaving(_ rig: Rig) async throws {
        for _ in 0..<500 where rig.recorder.state != .saving && rig.recorder.state != .idle {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(rig.recorder.state == .saving || rig.recorder.state == .idle)
    }

    // MARK: Endings at once, and odd timings

    @Test func twoEndingsAtOnceLandOneFileAndPostOneNotice() async throws {
        let rig = try Rig()
        await rig.record()
        rig.recorder.stop()
        rig.recorder.end(.displayGone)
        rig.source.stops(with: NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.noCaptureSource.rawValue))
        rig.recorder.end(.sleeping)
        await rig.landed()
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.saved().count == 1)
        #expect(rig.tray.urls.count == 1)
        #expect(rig.notices.count == 1)
        // The first one is what's said.
        #expect(rig.notices.last?.text == "Saved")
    }

    @Test func aFrameAfterTheEndIsIgnored() async throws {
        let rig = try Rig()
        await rig.record()
        rig.recorder.stop()
        rig.source.send(5)
        await rig.landed()
        rig.source.send(5)
        #expect(await RecordingWriter.isPlayable(try #require(rig.saved().first)))
    }

    @Test func aStopWhileStartingEndsItOnceTheStreamIsUp() async throws {
        let rig = try Rig()
        rig.source.holdsStart = true
        rig.recorder.start(rig.request())
        try await Task.sleep(for: .milliseconds(20))
        #expect(rig.recorder.state == .starting)
        rig.recorder.stop()
        // It can't be stopped until it's up, and no time starts running meanwhile.
        #expect(rig.recorder.state == .starting)
        rig.source.letStart()
        await rig.recorder.starting?.value
        await rig.landed()
        #expect(rig.recorder.state == .idle)
        #expect(rig.source.stopCount == 1)
        #expect(rig.saved().isEmpty)
        #expect(rig.notices.count == 1)
        #expect(rig.notices.last?.text == "Not recorded")
        #expect(rig.notices.last?.detail == "It stopped before the first frame")
    }

    @Test func noFramesAtAllLeavesNoFileAndSaysSo() async throws {
        let rig = try Rig()
        await rig.record(frames: 0)
        rig.source.stops(with: NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.noCaptureSource.rawValue))
        try await waitForSaving(rig)
        await rig.landed()
        #expect(rig.saved().isEmpty)
        #expect(rig.tray.urls.isEmpty)
        #expect(rig.trayFiles().isEmpty)
        #expect(rig.notices.last?.text == "Not recorded")
        #expect(rig.notices.last?.detail == "The screen couldn't be read")
    }

    @Test func aStreamThatWontStartLeavesNoFileAndSaysSo() async throws {
        let rig = try Rig()
        rig.source.startError = CocoaError(.featureUnsupported)
        rig.recorder.start(rig.request())
        await rig.recorder.starting?.value
        await rig.landed()
        #expect(rig.recorder.state == .idle)
        #expect(rig.trayFiles().isEmpty)
        #expect(rig.notices.last?.text == "Not recorded")
    }

    @Test func aSecondRecordingWaitsForTheFirstsFile() async throws {
        let rig = try Rig()
        await rig.record()
        rig.recorder.start(rig.request())
        #expect(rig.notices.last?.text == "Still saving")
        rig.recorder.stop()
        await rig.landed()
        #expect(rig.saved().count == 1)
    }

    @Test func aSelectionTooSmallIsRefusedInPlainWords() throws {
        let rig = try Rig()
        rig.recorder.start(rig.request(region: CGRect(x: 0, y: 0, width: 1, height: 100)))
        #expect(rig.recorder.state == .idle)
        #expect(rig.notices.last?.text == "Too small")
        #expect(rig.trayFiles().isEmpty)
    }

    @Test func aFolderThatCantBeWrittenSaysSoBeforeRecording() throws {
        let rig = try Rig()
        try FileManager.default.removeItem(at: rig.tray.folder)
        rig.recorder.start(rig.request())
        #expect(rig.recorder.state == .idle)
        #expect(rig.notices.last?.text == "Not recorded")
    }

    // MARK: GIF

    @Test func aGifLandsAndItsMP4Goes() async throws {
        let rig = try Rig()
        await rig.record(.gif, frames: 0)
        try await rig.pace(frames: 15)
        #expect(rig.recorder.plan?.frameRate == 15)
        rig.recorder.stop()
        await rig.landed()

        let file = try #require(rig.saved().first)
        #expect(rig.saved().count == 1)
        #expect(file.pathExtension == "gif")
        #expect(rig.tray.urls == [file])
        #expect(rig.trayFiles().isEmpty)
        let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
        #expect(CGImageSourceGetCount(source) > 1)
        #expect(rig.notices.last?.text == "Saved")
    }

    @Test func aFailedConversionKeepsTheMP4AndSaysSo() async throws {
        let rig = try Rig()
        rig.recorder.convert = { _, _ in throw CocoaError(.fileWriteUnknown) }
        await rig.record(.gif)
        rig.recorder.stop()
        await rig.landed()

        let file = try #require(rig.saved().first)
        #expect(rig.saved().count == 1)
        #expect(file.pathExtension == "mp4")
        #expect(await RecordingWriter.isPlayable(file))
        #expect(rig.trayFiles().isEmpty)
        #expect(rig.notices.last?.text == "No GIF")
        #expect(rig.notices.last?.detail == "It couldn't be made. Saved as \(file.lastPathComponent)")
    }

    // MARK: The clock, and the outline

    @Test func theClockExistsOnlyWhileRecording() async throws {
        let rig = try Rig()
        #expect(!rig.recorder.isTicking)
        await rig.record()
        #expect(rig.recorder.isTicking)
        rig.recorder.stop()
        #expect(!rig.recorder.isTicking)
        await rig.landed()
    }

    @Test func theClockTicksOnceASecondInAllConditions() {
        #expect(Cadence.recording.every == 1)
        #expect(Cadence.recording.onBattery == 1)
        #expect(Cadence.recording.lowPower == 1)
    }

    @Test func theTimeComesFromTheStartDate() throws {
        let rig = try Rig()
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        rig.recorder.loadSample(.recording(since: start), now: start.addingTimeInterval(125))
        #expect(rig.recorder.elapsed == 125)
        rig.recorder.loadSample(.idle)
        #expect(rig.recorder.elapsed == 0)
    }

    @Test func aSampleHoldsNothingAndAStopFindsNothing() throws {
        let rig = try Rig()
        rig.recorder.loadSample(.recording(since: .now))
        #expect(rig.recorder.isActive)
        #expect(!rig.recorder.isRunning)
        #expect(!rig.recorder.isBusy)
        rig.recorder.stop()
        #expect(rig.notices.isEmpty)
    }

    @Test func theOutlineIsParkedInATestAndComesAndGoesWithTheRecording() async throws {
        let rig = try Rig()
        #expect(rig.recorder.outline == nil)
        await rig.record()
        let outline = try #require(rig.recorder.outline)
        #expect(!outline.canBecomeKey)
        #expect(!outline.canBecomeMain)
        #expect(outline.ignoresMouseEvents)
        #expect(outline.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(!NSScreen.screens.contains { $0.frame.intersects(outline.frame) })
        rig.recorder.stop()
        #expect(rig.recorder.outline == nil)
        #expect(!outline.isVisible)
        await rig.landed()
    }

    /// Made, not shown: an outline that isn't parked goes just outside the region.
    @Test func theOutlineSitsJustOutsideTheRegion() {
        let region = CGRect(x: 100, y: 200, width: 300, height: 150)
        let outline = RecordingOutline(around: region, isParked: false)
        #expect(outline.frame == region.insetBy(dx: -RecordingOutline.lineWidth, dy: -RecordingOutline.lineWidth))
        #expect(!outline.isVisible)
        outline.close()
    }
}

/// The closed notch and the glance while a recording runs.
@MainActor
@Suite(.serialized)
struct RecordingNotchTests {
    private let viewModel: NotchViewModel
    private let notch = CGSize(width: 186, height: 37)
    private let button = LiveNotice(key: "download", symbol: "arrow.down.circle.fill", tint: .blue, text: "Downloaded", detail: "File.zip",
                                    actions: [NoticeAction(title: "Show", kind: .openTab(.tray))])

    init() {
        SnapshotRenderer.useScratchDefaults()
        viewModel = NotchViewModel(geometry: NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                                           closedSize: CGSize(width: 186, height: 37), hasHardwareNotch: true))
    }

    @Test func theEarsHaveRoomForTheTime() {
        let layout = ClosedLayout(activity: .recording, notch: notch)
        #expect(layout.earWidth == 72)
        #expect(layout.rowHeight == 0)
        #expect((Format.duration(3765) as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)]).width
            < layout.earWidth - 11)
        #expect(ClosedLayout(activity: .recording, secondary: .music, notch: notch).earWidth == layout.earWidth + 24)
    }

    @Test func theDotIsShownByTheRecordingItself() {
        #expect(CompactActivity.recording.isShown(by: .recording))
        #expect(!CompactActivity.recording.isShown(by: .music))
        #expect(!CompactActivity.recording.isShown(by: .notice(button)))
    }

    @Test func theDotIsAStatus() {
        #expect(CompactActivity.recording.isStatus)
    }

    /// The real center, on a sample of the recorder, which holds nothing.
    private func withRecording(_ state: ScreenRecorder.State = .recording(since: .now), _ body: () -> Void) {
        ScreenRecorder.shared.loadSample(state)
        body()
        LiveActivityCenter.shared.dismissNotice()
        ScreenRecorder.shared.loadSample(.idle)
        LiveActivityCenter.shared.dismissNotice()
    }

    /// Whichever notice it is: other suites post to the same center, and this one may be waiting its turn.
    @Test func noticesStillTakeTheNotchAndTheDotStaysBeside() {
        withRecording {
            LiveActivityCenter.shared.post(button, for: 5)
            if case .notice = LiveActivityCenter.shared.content.activity {} else {
                Issue.record("no notice in the notch: \(LiveActivityCenter.shared.content.activity)")
            }
            #expect(LiveActivityCenter.shared.content.secondary == .recording)
        }
    }

    @Test func theDotStaysWithTwoAtOnceOff() {
        let settings = AppSettings.shared
        let saved = settings.liveSecondary
        settings.liveSecondary = false
        defer { settings.liveSecondary = saved }
        withRecording {
            LiveActivityCenter.shared.post(button, for: 5)
            #expect(LiveActivityCenter.shared.content.secondary == .recording)
        }
    }

    @Test func aRecordingIsTheMainActivityWithNoNoticeUp() {
        withRecording {
            // Clearing what other suites left waiting too.
            for _ in 0..<20 {
                LiveActivityCenter.shared.dismissNotice()
                guard case .notice = LiveActivityCenter.shared.content.activity else { break }
            }
            #expect(LiveActivityCenter.shared.content.activity == .recording)
            #expect(LiveActivityCenter.shared.content.secondary != .recording)
        }
    }

    @Test func aClickGoesToTheGlanceAndNeverStops() {
        viewModel.stage(phase: .closed, activity: .recording)
        viewModel.activate()
        #expect(viewModel.phase == .glance)
        #expect(viewModel.glanceContent == .recording)
    }

    @Test func aClickGoesToTheGlanceBesideANoticeToo() {
        viewModel.stage(phase: .closed, activity: .notice(LiveNotice(key: "volume", symbol: "speaker", tint: .white, text: "Hi")),
                        secondary: .recording)
        viewModel.activate()
        #expect(viewModel.phase == .glance)
    }

    @Test func theGlanceIsTheRecordingsWhateverTheClosedNotchShows() {
        viewModel.stage(phase: .glance, activity: .notice(button), secondary: .recording)
        #expect(viewModel.glanceContent == .recording)
        viewModel.stage(phase: .glance, activity: .music, secondary: .recording)
        #expect(viewModel.glanceContent == .recording)
        viewModel.stage(phase: .glance, activity: .recording, secondary: .music)
        #expect(viewModel.glanceContent == .recording)
    }

    @Test func theRecentListStaysItsOwn() {
        viewModel.stage(phase: .glance, activity: .recording, showingRecent: true)
        if case .recent = viewModel.glanceContent {} else { Issue.record("not the recent list") }
    }

    @Test func stopIsDeadJustAfterAClickRaisesTheGlance() async throws {
        viewModel.stage(phase: .closed, activity: .recording)
        viewModel.activate()
        #expect(!viewModel.acceptsStop)
        try await Task.sleep(for: .seconds(NotchViewModel.stopGate + 0.05))
        #expect(viewModel.acceptsStop)
    }

    /// `acceptsNoticeButtons` is no help here: no click brought this glance up.
    @Test func stopIsDeadJustAfterHoverRaisesTheGlance() async throws {
        viewModel.stage(phase: .hovering, activity: .recording)
        viewModel.glance()
        #expect(viewModel.acceptsNoticeButtons)
        #expect(!viewModel.acceptsStop)
        try await Task.sleep(for: .seconds(NotchViewModel.stopGate + 0.05))
        #expect(viewModel.acceptsStop)
    }

    @Test func theGateStartsOverEachTimeTheGlanceAppears() async throws {
        viewModel.stage(phase: .hovering, activity: .recording)
        viewModel.glance()
        try await Task.sleep(for: .seconds(NotchViewModel.stopGate + 0.05))
        viewModel.close()
        viewModel.setHovering(true)
        viewModel.glance()
        #expect(!viewModel.acceptsStop)
    }
}

/// Starting and stopping from Capture.
@MainActor
@Suite(.serialized)
struct RecordingCaptureTests {
    /// One for the whole suite: drawing it takes a while, on the main actor every suite shares.
    private static let sharedDisplay = CaptureController.syntheticDisplay(id: 7, frame: CGRect(x: 0, y: 0, width: 480, height: 360), scale: 2)!
    private var display: CaptureDisplay { Self.sharedDisplay }
    private let selection = CGRect(x: 100, y: 100, width: 300, height: 200)

    init() {
        SnapshotRenderer.useScratchDefaults()
    }

    private func key(_ characters: String, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 9)!
    }

    private func editor() -> (CaptureEditor, Finishes) {
        let editor = CaptureEditor(displays: [display], accent: .blue)
        let finishes = Finishes()
        editor.onFinish = { finishes.seen.append($0) }
        return (editor, finishes)
    }

    private final class Finishes {
        var seen: [CaptureEditor.Finish] = []
    }

    @Test func vRecords() {
        let (editor, finishes) = editor()
        editor.stage(selection: selection, on: display.id)
        #expect(editor.handleKey(key("v")))
        #expect(finishes.seen == [.record])
    }

    @Test func theToolbarsActionRecordsToo() {
        let (editor, finishes) = editor()
        editor.stage(selection: selection, on: display.id)
        editor.finish(.record)
        #expect(finishes.seen == [.record])
    }

    @Test func vWhileTypingIsTyping() {
        let (editor, finishes) = editor()
        editor.stage(selection: selection, on: display.id)
        editor.tool = .text
        editor.mouseDown(at: CGPoint(x: 200, y: 200), on: display.id)
        #expect(editor.isEditingText)
        #expect(!editor.handleKey(key("v")))
        #expect(finishes.seen.isEmpty)
    }

    @Test func commandVIsNotRecord() {
        let (editor, finishes) = editor()
        editor.stage(selection: selection, on: display.id)
        #expect(!editor.handleKey(key("v", flags: .command)))
        #expect(finishes.seen.isEmpty)
    }

    @Test func noSelectionNoRecording() {
        let (editor, finishes) = editor()
        #expect(editor.handleKey(key("v")))
        #expect(finishes.seen.isEmpty)
    }

    @Test func theFormatIsMP4ByDefault() {
        #expect(RecordFormat.mp4.frameRate == 60)
        #expect(RecordFormat.gif.frameRate == 15)
        #expect(UserDefaults.dynotch.string(forKey: "recordFormat") == nil || AppSettings.shared.recordFormat == .mp4)
    }

    /// The editor over a made-up display, parked, with a fake recorder in place of the real one. Nothing
    /// is clicked: the selection is staged and the finish comes straight from the editor.
    @Test func recordTakesTheSelectionClosesTheOverlayAndRendersNothing() async throws {
        let rig = try Rig()
        let controller = CaptureController.shared
        let saved = (controller.recorder, controller.placesOverlaysOffScreen)
        controller.recorder = rig.recorder
        controller.placesOverlaysOffScreen = true
        defer { (controller.recorder, controller.placesOverlaysOffScreen) = saved }

        controller.beginTest(displays: [display])
        let editor = try #require(controller.editor)
        // A mark that a rendered image would have, which a recording doesn't.
        editor.stage(selection: selection, on: display.id, annotations: [
            Annotation(kind: .rectangle(CGRect(x: 110, y: 110, width: 40, height: 40)), color: .red, width: 4),
        ])
        editor.finish(.record)

        #expect(!controller.isActive)
        #expect(controller.overlays.isEmpty)
        #expect(!NotchManager.shared.isPointerSuspended)
        #expect(rig.recorder.state == .starting)
        await rig.recorder.starting?.value
        #expect(rig.source.plan?.sizeText == "600 × 400")
        #expect(rig.source.plan?.sourceRect == selection)
        rig.recorder.stop()
        await rig.landed()
        // Nothing but the recording's own: no shutter, no capture, no file from the marks.
        #expect(rig.notices.count == 1)
    }

    @Test func recordWithNoSelectionStartsNothing() throws {
        let rig = try Rig()
        let controller = CaptureController.shared
        let saved = (controller.recorder, controller.placesOverlaysOffScreen)
        controller.recorder = rig.recorder
        controller.placesOverlaysOffScreen = true
        defer { (controller.recorder, controller.placesOverlaysOffScreen) = saved }

        controller.beginTest(displays: [display])
        try #require(controller.editor).finish(.record)
        #expect(controller.isActive)
        #expect(rig.recorder.state == .idle)
        controller.cancel()
        #expect(!controller.isActive)
    }

    /// Only with a recording known to be running: `begin` would otherwise go on to ask for access.
    @Test func beginStopsARunningRecordingInsteadOfOpeningCapture() async throws {
        let rig = try Rig()
        await rig.record()
        try #require(rig.recorder.isRunning)
        let controller = CaptureController.shared
        let saved = controller.recorder
        controller.recorder = rig.recorder
        defer { controller.recorder = saved }

        controller.begin()
        #expect(rig.recorder.state == .saving)
        #expect(!controller.isActive)
        await rig.landed()
        #expect(rig.saved().count == 1)
    }

    /// Only the row itself, on the fake recorder: the whole command list reads the real stores.
    @Test func theCommandFieldOffersStopWhileRecordingAndItStops() async throws {
        let rig = try Rig()
        func rows(_ text: String) -> [CommandResult] { CommandEngine.stopRecording(matching: text, recorder: rig.recorder) }
        #expect(rows("stop").isEmpty)
        await rig.record()
        #expect(rows("stop").first?.id == "stop-recording")
        #expect(rows("stop recording").first?.id == "stop-recording")
        #expect(rows("st").first?.id == "stop-recording")
        #expect(rows("screenshot").isEmpty)

        let viewModel = NotchViewModel(geometry: NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                                               closedSize: CGSize(width: 186, height: 37), hasHardwareNotch: true))
        let stop = try #require(rows("stop").first?.action)
        _ = stop(viewModel)
        #expect(rig.recorder.state == .saving)
        #expect(rows("stop").isEmpty)
        await rig.landed()
        #expect(rig.saved().count == 1)
    }
}
