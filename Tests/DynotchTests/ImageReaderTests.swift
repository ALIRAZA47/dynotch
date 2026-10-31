import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Dynotch

/// Pictures the tests draw themselves, and what they can read back out of one.
private enum Picture {
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    static func draw(_ width: Int, _ height: Int, _ body: (CGContext) -> Void) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        body(context)
        return context.makeImage()!
    }

    /// Black text on white, a line to each string.
    static func text(_ lines: [String]) -> CGImage {
        draw(1000, 90 * lines.count + 40) { context in
            context.setFillColor(.white)
            context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            for (index, line) in lines.reversed().enumerated() {
                NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
                    .draw(at: NSPoint(x: 40, y: 30 + index * 90))
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    static func qrCode(_ message: String) -> CGImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(message.utf8)
        let code = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        return CIContext().createCGImage(code, from: code.extent)!
    }

    /// A ball on a plain background, red over blue so its way up shows.
    static let ballRed = (r: UInt8(204), g: UInt8(77), b: UInt8(51))
    static func ball() -> CGImage {
        draw(800, 600) { context in
            context.setFillColor(CGColor(srgbRed: 0.93, green: 0.93, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
            context.addEllipse(in: CGRect(x: 250, y: 150, width: 300, height: 300))
            context.clip()
            context.setFillColor(CGColor(srgbRed: 0.2, green: 0.3, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 250, y: 150, width: 300, height: 150))
            context.setFillColor(CGColor(srgbRed: 0.8, green: 0.3, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 250, y: 300, width: 300, height: 150))
        }
    }

    /// The picture turned a quarter to the left, as a phone's sensor sees it. Orientation 6 turns it back.
    static func stored(onItsSide image: CGImage) -> CGImage {
        draw(image.height, image.width) { context in
            context.translateBy(x: CGFloat(image.height), y: 0)
            context.rotate(by: .pi / 2)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
    }

    static func save(_ image: CGImage, to url: URL, type: UTType = .png, orientation: Int? = nil) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
    }

    /// The red, green, blue and alpha at a place, counted from the top-left corner, in sRGB and not
    /// premultiplied, as a file would be read.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        let alpha = Int(bytes[3])
        func straight(_ value: UInt8) -> UInt8 { alpha == 0 ? 0 : UInt8(min(255, Int(value) * 255 / alpha)) }
        return (straight(bytes[0]), straight(bytes[1]), straight(bytes[2]), bytes[3])
    }
}

/// Reading text and codes, and the rules a code has to pass to be a link.
struct ImageReaderTests {
    @Test func readsTextDrawnIntoAnImage() async {
        let reading = await ImageReader.read(Picture.text(["Hello from Dynotch", "A second line of text"]))
        #expect(reading.lines == ["Hello from Dynotch", "A second line of text"])
        #expect(reading.text == "Hello from Dynotch\nA second line of text")
        #expect(reading.lineCount == 2)
        #expect(reading.codes.isEmpty)
    }

    @Test func aPlainImageHasNothingToRead() async {
        let reading = await ImageReader.read(Picture.draw(400, 300) { context in
            context.setFillColor(CGColor(srgbRed: 0.3, green: 0.5, blue: 0.7, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        })
        #expect(reading.isEmpty)
    }

    @Test func anImageOfACoupleOfPixelsIsNoTrouble() async {
        // Vision refuses to read text this small, and that mustn't reach anyone.
        #expect(await ImageReader.read(Picture.draw(2, 2) { _ in }).isEmpty)
    }

    @Test func findsAQRCodeAndItsLink() async throws {
        let reading = await ImageReader.read(Picture.qrCode("https://example.com/hello"))
        #expect(reading.codes == ["https://example.com/hello"])
        #expect(reading.text == "https://example.com/hello")
        #expect(reading.link == URL(string: "https://example.com/hello"))
    }

    @Test func aCodeThatIsntALinkIsOnlyText() async {
        let reading = await ImageReader.read(Picture.qrCode("WIFI:S:Home;T:WPA;P:hunter2;;"))
        #expect(reading.text == "WIFI:S:Home;T:WPA;P:hunter2;;")
        #expect(reading.link == nil)
    }

    @Test func aHostileLinkInACodeStaysText() async {
        let reading = await ImageReader.read(Picture.qrCode("https://paypal.com@evil.example/"))
        #expect(reading.text == "https://paypal.com@evil.example/")
        #expect(reading.link == nil)
    }

    /// Vision's text reader holds its thread until work of its own has run on the threads tasks share.
    /// If reads filled those threads themselves, that work would have nowhere to run and nothing in a
    /// task would ever run again. CI has three of them, and froze on its first run this way.
    @Test func moreReadsAtOnceThanThreadsForTasksAllFinish() async {
        let picture = Picture.text(["Hello from Dynotch"])
        let count = ProcessInfo.processInfo.activeProcessorCount + 1
        let readings = await withTaskGroup(of: [String].self, returning: [[String]].self) { group in
            for _ in 0..<count {
                group.addTask { await ImageReader.read(picture).lines }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(readings == Array(repeating: ["Hello from Dynotch"], count: count))
    }

    @Test func aCodeAlreadyInTheLinesIsntCopiedTwice() {
        let reading = ImageReader.Reading(lines: ["Scan me", "See https://example.com/a now"],
                                          codes: ["https://example.com/a", "other", "other"])
        #expect(reading.text == "Scan me\nSee https://example.com/a now\nother")
        #expect(reading.lineCount == 3)
    }

    @Test func theFirstLinkGetsTheNoticeAndTheRestAreText() {
        let reading = ImageReader.Reading(codes: ["plain words", "tel:+15551234", "https://first.example/", "https://second.example/"])
        #expect(reading.link == URL(string: "https://first.example/"))
        #expect(reading.text == "plain words\ntel:+15551234\nhttps://first.example/\nhttps://second.example/")
    }

    // MARK: Links

    @Test(arguments: [
        ("https://example.com", "https://example.com"),
        ("http://example.com/path?q=1#top", "http://example.com/path?q=1#top"),
        ("  https://example.com/\n", "https://example.com/"),
        ("\thttp://example.com\r\n", "http://example.com"),
        ("HTTPS://Example.COM/", "https://Example.COM/"),
        ("HtTp://example.com/a", "http://example.com/a"),
        ("https://example.com:8443/x", "https://example.com:8443/x"),
        ("https://a.b.example.co.uk/c/d", "https://a.b.example.co.uk/c/d"),
        ("http://192.168.1.1/admin", "http://192.168.1.1/admin"),
        ("https://[2001:db8::1]:8080/", "https://[2001:db8::1]:8080/"),
        ("https://xn--80ak6aa92e.com/", "https://xn--80ak6aa92e.com/"),
        ("https://example.com/a%20b?x=%C3%A9", "https://example.com/a%20b?x=%C3%A9"),
    ])
    func theseAreLinks(payload: String, link: String) {
        #expect(ImageReader.link(from: payload)?.absoluteString == link)
    }

    @Test(arguments: [
        // Other schemes.
        "javascript:alert(1)", "JAVASCRIPT:alert(1)", "file:///etc/passwd", "smb://server/share", "tel:+15551234567",
        "mailto:someone@example.com", "dynotch://tray/clear", "x-apple-reminderkit://REMCDReminder/1",
        "x-apple.systempreferences:com.apple.preference.security", "ftp://example.com/file", "data:text/html;base64,PHNjcmlwdD4=",
        "vbscript:msgbox(1)", "about:blank", "ssh://example.com", "httpx://example.com", "ahttp://example.com",
        "https+evil://example.com",
        // Not URLs at all.
        "WIFI:S:Home;T:WPA;P:secret;;", "plain text", "", "   ", "\n", "BEGIN:VCARD\nFN:Sam\nEND:VCARD", "example.com",
        "www.example.com/path",
        // No host.
        "https://", "http://", "https:///path", "https:example.com", "//example.com", "https:",
        // A user or a password, which is how one domain shows while another opens.
        "https://paypal.com@evil.example/", "https://user:secret@example.com/", "https://:secret@example.com/",
        "https://@example.com/", "http://paypal.com:443@evil.example/",
        // Control characters, as they are and escaped, and what writes right to left.
        "https://exa\u{0}mple.com", "https://example.com/\u{7}", "https://example.com/a\nb", "https://exam\tple.com/",
        "https://example.com/\u{7F}", "https://example.com/\u{202E}moc.live", "https://example.com/%0d%0aSet-Cookie:x",
        "https://example.com/%00", "https://evil.example%00.paypal.com/", "https://example.com/%E2%80%AEmoc.live",
        // Hosts that aren't what they look like.
        "https://paypal.com%2F.evil.example/", "https://ev%69l.example/", "https://evil.example\\@paypal.com/",
        "https://exa mple.com/", "https://раураl.com/",
    ])
    func theseAreOnlyText(payload: String) {
        #expect(ImageReader.link(from: payload) == nil)
    }

    // MARK: Where a link goes

    /// A letter is a point wide, which makes the arithmetic easy to follow.
    private func destination(_ address: String, hostRoom: CGFloat = 20, room: CGFloat = 30) throws -> String {
        ImageReader.destination(of: try #require(URL(string: address)), hostRoom: hostRoom, room: room) { CGFloat($0.count) }
    }

    @Test func theWholeOfAShortLinkShows() throws {
        #expect(try destination("https://example.com/hello") == "example.com/hello")
    }

    @Test func noPathMeansJustTheHost() throws {
        #expect(try destination("https://example.com/") == "example.com")
        #expect(try destination("https://example.com") == "example.com")
    }

    @Test func aPortIsPartOfThePlace() throws {
        #expect(try destination("https://example.com:8443/a") == "example.com:8443/a")
    }

    @Test func aLongPathShowsWhatFits() throws {
        let shown = try destination("https://example.com/one/two/three/four/five")
        #expect(shown == "example.com/one/two/three/fou…")
        #expect(shown.count == 30)
    }

    @Test func aPathNeverPushesTheHostOut() throws {
        // The path names another site. The host stays first, whole.
        #expect(try destination("https://evil.example/paypal.com/signin/account/verify") == "evil.example/paypal.com/signi…")
    }

    @Test func aLongHostKeepsItsEnd() throws {
        #expect(try destination("https://paypal.com.accounts.verify.evil.example/") == "…verify.evil.example")
    }

    @Test func aLongHostLeavesRoomForThePath() throws {
        let shown = try destination("https://paypal.com.accounts.verify.evil.example/login/now/please")
        #expect(shown.hasPrefix("…"))
        #expect(shown.contains("evil.example/lo"))
        #expect(shown.hasSuffix("…"))
        #expect(shown.count == 30)
    }

    @Test(arguments: [8, 12, 20, 40, 400])
    func aHostsEndIsNeverCut(room: Int) throws {
        // However narrow, what shows of the host is its right-hand end.
        let host = "a.very.long.sub.domain.of.a.place.you.dont.know.evil.example"
        let shown = try destination("https://\(host)/path", hostRoom: CGFloat(room), room: CGFloat(room + 6))
        let kept = shown.prefix { $0 != "/" }.drop { $0 == "…" }
        #expect(host.hasSuffix(kept))
        #expect(!kept.isEmpty)
    }

    @Test func wideLettersAreMeasuredNotCounted() {
        // In the notch's own font, where a row of M takes up three times the room of a row of i. Counting
        // letters would let this run past the row, and the row would cut off the end that matters.
        let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let width: (String) -> CGFloat = { ($0 as NSString).size(withAttributes: [.font: font]).width }
        let shown = ImageReader.destination(of: URL(string: "https://" + String(repeating: "m", count: 60) + ".evil.example/x")!,
                                            hostRoom: 96, room: 185, width: width)
        #expect(shown.contains("evil.example"))
        #expect(width(String(shown.prefix { $0 != "/" })) <= 96)
        #expect(width(shown) <= 185)
    }

    @Test func thousandsOfLettersTakeNoTimeToMeasure() throws {
        var measured = 0
        let url = try #require(URL(string: "https://example.com/" + String(repeating: "a", count: 4000)))
        let shown = ImageReader.destination(of: url, hostRoom: 96, room: 185) {
            measured += 1
            return CGFloat($0.count)
        }
        #expect(shown.count == 185)
        #expect(measured < 40)
    }

    @Test func anEscapedPathStaysEscaped() throws {
        // Unescaped, a path could read as something it isn't.
        #expect(try destination("https://example.com/a%20b") == "example.com/a%20b")
    }
}

/// Decoding files and cutting out, in a folder of each test's own.
@MainActor
@Suite(.serialized)
final class ImageFileTests {
    private let support: URL
    private let tray: TrayStore

    init() throws {
        SnapshotRenderer.useScratchDefaults()
        AppSettings.shared.trayCopiesFiles = false
        support = FileManager.default.temporaryDirectory
            .appendingPathComponent("DynotchImageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        tray = TrayStore(support: support)
    }

    deinit {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: support.appendingPathComponent("locked").path)
        try? FileManager.default.removeItem(at: support)
    }

    private func file(_ name: String) -> URL { support.appendingPathComponent(name) }

    private func names() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: support.path))
    }

    /// Notices land here instead of in the notch.
    private final class Notices {
        var posted: [(notice: LiveNotice, seconds: TimeInterval)] = []
        var texts: [String] { posted.map(\.notice.text) }
    }

    /// Keeps what a test is after. A notice that only says work's going on comes whenever this machine
    /// reads slower than `patience`, as GitHub's runner does, so it stays out.
    private func collecting(_ notices: Notices) -> ImageActions.Notify {
        { notice, seconds in
            guard !["Reading", "Cutting out"].contains(notice.text) else { return }
            notices.posted.append((notice, seconds))
        }
    }

    // MARK: Decoding

    @Test func aPhotoOnItsSideComesOutTheRightWayUp() throws {
        let photo = file("Phone.jpg")
        let upright = Picture.ball()
        try Picture.save(Picture.stored(onItsSide: upright), to: photo, type: .jpeg, orientation: 6)
        let decoded = try ImageReader.decode(photo)
        #expect(decoded.width == upright.width)
        #expect(decoded.height == upright.height)
        // Red over blue, as it was drawn.
        let top = Picture.pixel(decoded, x: 400, y: 220), bottom = Picture.pixel(decoded, x: 400, y: 380)
        #expect(top.r > top.b)
        #expect(bottom.b > bottom.r)
    }

    @Test func thePlainFileIsReallyOnItsSide() throws {
        // Without this the test above would pass on a picture that was never turned.
        let photo = file("Phone.jpg")
        try Picture.save(Picture.stored(onItsSide: Picture.ball()), to: photo, type: .jpeg, orientation: 6)
        let source = try #require(CGImageSourceCreateWithURL(photo as CFURL, nil))
        let raw = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(raw.width == 600)
        #expect(raw.height == 800)
    }

    @Test func textInAPhotoOnItsSideReads() async throws {
        let photo = file("Note.jpg")
        try Picture.save(Picture.stored(onItsSide: Picture.text(["Hello from Dynotch"])), to: photo, type: .jpeg, orientation: 6)
        #expect(try await ImageReader.read(contentsOf: photo).lines == ["Hello from Dynotch"])
    }

    @Test(arguments: ["Drawing.svg", "Broken.png", "Empty.jpg", "Missing.png"])
    func aFileThatCantBeDecodedSaysSo(name: String) async throws {
        let url = file(name)
        if name == "Drawing.svg" {
            try Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>"#.utf8).write(to: url)
        } else if name == "Broken.png" {
            try Data("not a picture".utf8).write(to: url)
        } else if name == "Empty.jpg" {
            try Data().write(to: url)
        }
        await #expect(throws: ImageReader.Failure.undecodable) { try await ImageReader.read(contentsOf: url) }
        await #expect(throws: ImageReader.Failure.undecodable) { try await ImageReader.cutOut(contentsOf: url) }

        let notices = Notices()
        let pasteboard = NSPasteboard(name: .init("app.dynotch.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let count = pasteboard.changeCount
        await ImageActions.copyText(from: [url], to: pasteboard, notify: collecting(notices))
        await ImageActions.cutOut([url], tray: tray, notify: collecting(notices))
        #expect(notices.texts == ["Can't read", "Can't read"])
        #expect(notices.posted[0].notice.detail == "Couldn't open \(name)")
        #expect(pasteboard.changeCount == count)
        #expect(tray.items.isEmpty)
    }

    // MARK: Copy Text

    @Test func copyTextGoesOnThePasteboardWithANotice() async throws {
        let image = file("Note.png")
        try Picture.save(Picture.text(["Hello from Dynotch", "A second line of text"]), to: image)
        let notices = Notices()
        let pasteboard = NSPasteboard(name: .init("app.dynotch.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        await ImageActions.copyText(from: [image], to: pasteboard, notify: collecting(notices))
        #expect(pasteboard.string(forType: .string) == "Hello from Dynotch\nA second line of text")
        #expect(notices.posted.map(\.notice.key) == ["capture"])
        #expect(notices.posted.first?.notice.text == "Copied")
        #expect(notices.posted.first?.notice.detail == "2 lines")
        #expect(notices.posted.first?.notice.tint == .white)
    }

    @Test func onlyTheImagesAmongTheFilesAreRead() async throws {
        let image = file("Note.png"), other = file("Notes.txt")
        try Picture.save(Picture.text(["Hello from Dynotch"]), to: image)
        try Data("Not this".utf8).write(to: other)
        let notices = Notices()
        let pasteboard = NSPasteboard(name: .init("app.dynotch.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        await ImageActions.copyText(from: [other, image], to: pasteboard, notify: collecting(notices))
        #expect(pasteboard.string(forType: .string) == "Hello from Dynotch")
        #expect(notices.posted.first?.notice.detail == "1 line")
    }

    @Test func severalImagesReadAsOneAndABadOneIsMentioned() async throws {
        let first = file("One.png"), second = file("Two.png"), bad = file("Bad.png")
        try Picture.save(Picture.text(["The first image"]), to: first)
        try Picture.save(Picture.text(["The second image"]), to: second)
        try Data("not a picture".utf8).write(to: bad)
        let notices = Notices()
        let pasteboard = NSPasteboard(name: .init("app.dynotch.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        await ImageActions.copyText(from: [first, bad, second], to: pasteboard, notify: collecting(notices))
        #expect(pasteboard.string(forType: .string) == "The first image\nThe second image")
        #expect(notices.posted.first?.notice.detail == "2 lines, but one image couldn't be read")
        #expect(notices.posted.first?.notice.tint == .orange)
    }

    @Test func nothingFoundLeavesThePasteboardAlone() throws {
        let pasteboard = NSPasteboard(name: .init("app.dynotch.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("Already here", forType: .string)
        let count = pasteboard.changeCount
        let notices = Notices()
        ImageActions.deliver(ImageReader.Reading(), to: pasteboard, notify: collecting(notices))
        #expect(pasteboard.changeCount == count)
        #expect(pasteboard.string(forType: .string) == "Already here")
        let notice = try #require(notices.posted.first?.notice)
        #expect(notice.text == "No text found")
        #expect(notice.tint == .orange)
        #expect(notice.key == "capture")
    }

    @Test func aQRCodeAloneCopiesItsPayloadAndOffersTheLink() throws {
        let pasteboard = NSPasteboard(name: .init("app.dynotch.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let link = try #require(URL(string: "https://example.com/hello"))
        let notices = Notices()
        ImageActions.deliver(ImageReader.Reading(codes: [link.absoluteString]), to: pasteboard, notify: collecting(notices))
        #expect(pasteboard.string(forType: .string) == link.absoluteString)
        #expect(notices.texts == ["QR code"])
        let notice = try #require(notices.posted.first)
        #expect(notice.notice.detail == "example.com/hello")
        #expect(notice.notice.actions == [NoticeAction(title: "Open", kind: .openURL(link))])
        #expect(notice.notice.recall == .whole)
        #expect(notice.seconds >= 6)
    }

    @Test func textAndALinkEachGetANotice() {
        let pasteboard = NSPasteboard(name: .init("app.dynotch.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let notices = Notices()
        ImageActions.deliver(ImageReader.Reading(lines: ["Scan me"], codes: ["https://example.com/"]), to: pasteboard, notify: collecting(notices))
        #expect(notices.texts == ["Copied", "QR code"])
        #expect(notices.posted.first?.notice.detail == "2 lines")
    }

    @Test func aCodeThatIsntALinkGetsNoButton() {
        let pasteboard = NSPasteboard(name: .init("app.dynotch.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let notices = Notices()
        ImageActions.deliver(ImageReader.Reading(codes: ["javascript:alert(1)"]), to: pasteboard, notify: collecting(notices))
        #expect(pasteboard.string(forType: .string) == "javascript:alert(1)")
        #expect(notices.texts == ["Copied"])
        #expect(notices.posted.first?.notice.actions.isEmpty == true)
    }

    // MARK: Cut Out

    @Test func theSubjectKeepsItsColorsAndNothingElseStays() async throws {
        let cut = try await ImageReader.cutOut(Picture.ball())
        // The ball, not the picture: 300 points across, give or take its soft edge.
        #expect(abs(cut.width - 300) < 12)
        #expect(abs(cut.height - 300) < 12)
        let inside = Picture.pixel(cut, x: cut.width / 2, y: cut.height / 4)
        #expect(inside.a == 255)
        #expect(abs(Int(inside.r) - Int(Picture.ballRed.r)) <= 2)
        #expect(abs(Int(inside.g) - Int(Picture.ballRed.g)) <= 2)
        #expect(abs(Int(inside.b) - Int(Picture.ballRed.b)) <= 2)
        #expect(Picture.pixel(cut, x: 0, y: 0).a == 0)
        #expect(Picture.pixel(cut, x: cut.width - 1, y: cut.height - 1).a == 0)
    }

    @Test func aPictureWithNoSubjectSaysSoAndLeavesNoFile() async throws {
        let plain = file("Plain.png")
        try Picture.save(Picture.draw(400, 300) { context in
            context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }, to: plain)
        let before = try names()
        let notices = Notices()
        await ImageActions.cutOut([plain], tray: tray, notify: collecting(notices))
        #expect(notices.texts == ["No subject found"])
        #expect(notices.posted.first?.notice.tint == .orange)
        #expect(try names() == before)
        #expect(tray.items.isEmpty)
    }

    @Test func aCutOutOfAPhotoOnItsSideIsTheRightWayUp() async throws {
        let photo = file("Phone.jpg")
        try Picture.save(Picture.stored(onItsSide: Picture.ball()), to: photo, type: .jpeg, orientation: 6)
        let cut = try await ImageReader.cutOut(contentsOf: photo)
        // Red over blue, as drawn, rather than side by side.
        let top = Picture.pixel(cut, x: cut.width / 2, y: cut.height / 4)
        let bottom = Picture.pixel(cut, x: cut.width / 2, y: cut.height * 3 / 4)
        #expect(top.r > top.b + 60)
        #expect(bottom.b > bottom.r + 60)
    }

    @Test func aCutOutLandsBesideTheOriginalAndInTheTray() async throws {
        let photo = file("Ball.png")
        try Picture.save(Picture.ball(), to: photo)
        let original = try Data(contentsOf: photo)
        let notices = Notices()
        await ImageActions.cutOut([photo], tray: tray, notify: collecting(notices))

        let made = file("Ball (cut out).png")
        #expect(try Data(contentsOf: photo) == original)
        let cut = try ImageReader.decode(made)
        #expect(Picture.pixel(cut, x: 0, y: 0).a == 0)
        #expect(tray.urls == [made])
        let notice = try #require(notices.posted.first?.notice)
        #expect(notice.text == "Cut out")
        #expect(notice.detail == "Ball (cut out).png")
        #expect(notice.actions == [NoticeAction(title: "Open", kind: .openFile(made)), NoticeAction(title: "Show", kind: .reveal(made))])
        #expect(notice.recall == .whole)
    }

    @Test func aCutOutNeverOverwrites() async throws {
        let photo = file("Ball.png"), taken = file("Ball (cut out).png")
        try Picture.save(Picture.ball(), to: photo)
        try Data("Mine, keep it".utf8).write(to: taken)
        await ImageActions.cutOut([photo], tray: tray, notify: { _, _ in })
        #expect(try Data(contentsOf: taken) == Data("Mine, keep it".utf8))
        #expect(tray.urls == [file("Ball (cut out) 2.png")])
    }

    @Test func aCutOutFromAFolderItCantWriteToLandsInTheTraysFolder() async throws {
        let locked = file("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let photo = locked.appendingPathComponent("Ball.png")
        try Picture.save(Picture.ball(), to: photo)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        await ImageActions.cutOut([photo], tray: tray, notify: { _, _ in })
        #expect(tray.urls == [tray.folder.appendingPathComponent("Ball (cut out).png")])
        #expect(tray.items.first?.isOwned == true)
    }

    @Test func aCutOutWithNowhereToGoSaysSo() async throws {
        // Neither beside the original nor in the Tray's folder. The subject was found, so "No subject
        // found" would be untrue.
        let locked = file("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let photo = locked.appendingPathComponent("Ball.png")
        try Picture.save(Picture.ball(), to: photo)
        for folder in [locked, tray.folder] { try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path) }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tray.folder.path) }
        let notices = Notices()
        await ImageActions.cutOut([photo], tray: tray, notify: collecting(notices))
        #expect(notices.texts == ["Not saved"])
        #expect(notices.posted.first?.notice.detail == "Couldn't write to Tray")
        #expect(tray.items.isEmpty)
    }

    @Test func aDroppedImagesCutOutLandsInTheTrayAndTheDropGoes() async throws {
        let dropped = tray.folder.appendingPathComponent("Image 2026-10-31 at 12.00.00.png")
        try Picture.save(Picture.ball(), to: dropped)
        await ImageActions.cutOut([dropped], tray: tray, notify: { _, _ in })
        tray.removeLeftovers(of: [dropped])
        #expect(!FileManager.default.fileExists(atPath: dropped.path))
        let made = tray.folder.appendingPathComponent("Image 2026-10-31 at 12.00.00 (cut out).png")
        #expect(FileManager.default.fileExists(atPath: made.path))
        #expect(tray.urls == [made])
    }

    @Test func severalCutOutsAreCountedAndOneWithoutASubjectShows() async throws {
        let ball = file("Ball.png"), plain = file("Plain.png")
        try Picture.save(Picture.ball(), to: ball)
        try Picture.save(Picture.draw(400, 300) { context in
            context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }, to: plain)
        let notices = Notices()
        await ImageActions.cutOut([ball, plain], tray: tray, notify: collecting(notices))
        let notice = try #require(notices.posted.first?.notice)
        #expect(notice.detail == "1 of 2 images, in the Tray")
        #expect(notice.tint == .orange)
    }

    // MARK: Never overwriting

    @Test func aTakenNameMovesOnAndLeavesTheFileThere() throws {
        let taken = file("Ball (cut out).png")
        try Data("Mine, keep it".utf8).write(to: taken)
        let written = try ImageActions.write(Data("New".utf8), to: taken)
        #expect(written == file("Ball (cut out) 2.png"))
        #expect(try Data(contentsOf: taken) == Data("Mine, keep it".utf8))
        #expect(try Data(contentsOf: written) == Data("New".utf8))
    }

    @Test func losingTheRaceForANameTakesTheNext() throws {
        // `uniqueURL` said this was free, then something else took it before the write.
        let wanted = file("Ball (cut out).png")
        var asked: [URL] = []
        let written = try ImageActions.write(Data("New".utf8), to: wanted) { url in
            asked.append(url)
            if asked.count == 1 { try? Data("Got here first".utf8).write(to: url) }
            return url
        }
        #expect(asked.count == 2)
        #expect(written == file("Ball (cut out) 2.png"))
        #expect(try Data(contentsOf: wanted) == Data("Got here first".utf8))
        #expect(try Data(contentsOf: written) == Data("New".utf8))
    }

    @Test func aDanglingLinkCountsAsTaken() throws {
        // `fileExists` follows links, so to `uniqueURL` this looks free. A write through it would land
        // wherever it points.
        let wanted = file("Ball (cut out).png"), target = file("elsewhere.txt")
        try FileManager.default.createSymbolicLink(at: wanted, withDestinationURL: target)
        let written = try ImageActions.write(Data("New".utf8), to: wanted)
        #expect(written == file("Ball (cut out) 2.png"))
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    // MARK: Leftovers

    @Test func aDropsLeftoversGoAndEverythingElseStays() throws {
        let leftover = tray.folder.appendingPathComponent("Image.png")
        let kept = tray.folder.appendingPathComponent("Kept.png")
        let outside = file("Outside.png")
        for url in [leftover, kept, outside] { try Data("picture".utf8).write(to: url) }
        tray.add([kept])
        tray.removeLeftovers(of: [leftover, kept, outside])
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }
}

/// Telling whether a drag holds an image, on a pasteboard of each test's own.
@Suite(.serialized)
final class DragImageTests {
    private let pasteboard = NSPasteboard(name: .init("app.dynotch.tests.\(UUID().uuidString)"))
    private let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DynotchDragTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        pasteboard.clearContents()
    }

    deinit {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: folder)
    }

    private func files(_ names: String...) -> [NSURL] {
        names.map { name in
            let url = folder.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data())
            return url as NSURL
        }
    }

    @Test func anImageFileHoldsAnImage() {
        pasteboard.writeObjects(files("Photo.PNG"))
        #expect(TrayDrop.holdsImages(pasteboard))
    }

    @Test func aDocumentDoesnt() {
        pasteboard.writeObjects(files("Report.pdf", "Notes.txt"))
        #expect(!TrayDrop.holdsImages(pasteboard))
    }

    @Test func oneImageAmongOtherFilesIsEnough() {
        pasteboard.writeObjects(files("Report.pdf", "Notes.txt", "Photo.heic"))
        #expect(TrayDrop.holdsImages(pasteboard))
    }

    @Test(arguments: [NSPasteboard.PasteboardType.png, .tiff])
    func imageDataHoldsAnImage(type: NSPasteboard.PasteboardType) {
        pasteboard.setData(Data([1, 2, 3]), forType: type)
        #expect(TrayDrop.holdsImages(pasteboard))
    }

    @Test func aFilesPictureOfItsIconDoesntMakeItAnImage() throws {
        // Finder can put an icon on a file it's dragging. The drop would use the file, and so does this.
        let item = NSPasteboardItem()
        item.setString(try #require(files("Report.pdf").first?.absoluteString), forType: .fileURL)
        item.setData(Data([1, 2, 3]), forType: .tiff)
        pasteboard.writeObjects([item])
        #expect(!TrayDrop.holdsImages(pasteboard))
    }

    @Test func aFileReferenceURLIsFollowedToItsName() throws {
        // Finder's drags carry these, which have no extension of their own.
        let file = try #require(files("Photo.png").first)
        let reference = try #require(file.perform(#selector(NSURL.fileReferenceURL))?.takeUnretainedValue() as? NSURL)
        let link = try #require(reference.absoluteString)
        #expect(link.contains(".file/id="))
        let item = NSPasteboardItem()
        item.setString(link, forType: .fileURL)
        pasteboard.writeObjects([item])
        #expect(TrayDrop.holdsImages(pasteboard))
    }

    @Test func textAndLinksDont() {
        pasteboard.setString("Some words", forType: .string)
        #expect(!TrayDrop.holdsImages(pasteboard))
    }

    @Test func anEmptyPasteboardDoesnt() {
        #expect(!TrayDrop.holdsImages(pasteboard))
    }

    @Test func aDragIsLookedAtOnce() {
        pasteboard.writeObjects(files("Photo.png"))
        var check = DragImageCheck()
        var looks = 0
        let look: (NSPasteboard) -> Bool = { pasteboard in
            looks += 1
            return TrayDrop.holdsImages(pasteboard)
        }
        for _ in 0..<50 {
            let holds = check.holdsImages(on: pasteboard, look: look)
            #expect(holds)
        }
        #expect(looks == 1)
    }

    @Test func aNewDragIsLookedAtAgain() {
        pasteboard.writeObjects(files("Photo.png"))
        var check = DragImageCheck()
        let first = check.holdsImages(on: pasteboard)
        pasteboard.clearContents()
        pasteboard.writeObjects(files("Report.pdf"))
        let second = check.holdsImages(on: pasteboard)
        #expect(first)
        #expect(!second)
    }
}

/// The view model's part in a drag. Not `close()` or `stage()`: both set the command field's text, whose
/// suggestions look in the real Tray.
@MainActor
struct DraggingImagesTests {
    @Test func imagesEndWithTheDrag() {
        SnapshotRenderer.useScratchDefaults()
        let viewModel = NotchViewModel(geometry: NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                                                               closedSize: CGSize(width: 185, height: 32), hasHardwareNotch: true))
        viewModel.isDraggingImages = true
        viewModel.isDraggingFiles = true
        #expect(viewModel.isDraggingImages)
        viewModel.isDraggingFiles = false
        #expect(!viewModel.isDraggingImages)
    }

    // MARK: Saying so

    @Test func quickWorkSaysNothing() async {
        var shown: [String] = []
        let result = await ImageActions.saying(LiveNotice(key: "capture", symbol: "text.viewfinder", tint: .white, text: "Reading"),
                                               after: 5, notify: { notice, _ in shown.append(notice.text) }) { 42 }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(result == 42)
        #expect(shown.isEmpty)
    }

    /// The first read after an install can take half a minute, with the overlay already gone.
    @Test func slowWorkSaysSo() async {
        var shown: [String] = []
        await ImageActions.saying(LiveNotice(key: "capture", symbol: "text.viewfinder", tint: .white, text: "Reading"),
                                  after: 0.01, notify: { notice, _ in shown.append(notice.text) }) {
            try? await Task.sleep(for: .milliseconds(300))
        }
        #expect(shown == ["Reading"])
    }
}
