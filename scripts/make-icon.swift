// Renders AppIcon.icns into the given directory. Usage: make-icon <output-dir>
import AppKit

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = outputDirectory.appendingPathComponent("AppIcon.iconset")

func fill(_ ctx: CGContext, _ path: CGPath, _ color: NSColor) {
    ctx.addPath(path)
    ctx.setFillColor(color.cgColor)
    ctx.fillPath()
}

func gradient(_ colors: [NSColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map(\.cgColor) as CFArray, locations: nil)!
}

func drawIcon(in ctx: CGContext) {
    // macOS icon grid: an 824pt body centered on a 1024pt canvas. CG's y axis points up.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    fill(ctx, bodyPath, .black)
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([NSColor(red: 0.20, green: 0.22, blue: 0.48, alpha: 1), NSColor(red: 0.05, green: 0.05, blue: 0.12, alpha: 1)]),
        start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])
    ctx.drawRadialGradient(
        gradient([NSColor(red: 0.55, green: 0.45, blue: 1.0, alpha: 0.55), NSColor(red: 0.55, green: 0.45, blue: 1.0, alpha: 0)]),
        startCenter: CGPoint(x: 512, y: 700), startRadius: 0, endCenter: CGPoint(x: 512, y: 700), endRadius: 430, options: [])

    // The notch hangs from the top edge, with the same flared corners as the real one.
    let width: CGFloat = 580, height: CGFloat = 230, flare: CGFloat = 34, radius: CGFloat = 92
    let top = body.maxY, left = 512 - width / 2, right = 512 + width / 2, bottom = top - height
    let notch = CGMutablePath()
    notch.move(to: CGPoint(x: left - flare, y: top))
    notch.addQuadCurve(to: CGPoint(x: left, y: top - flare), control: CGPoint(x: left, y: top))
    notch.addLine(to: CGPoint(x: left, y: bottom + radius))
    notch.addQuadCurve(to: CGPoint(x: left + radius, y: bottom), control: CGPoint(x: left, y: bottom))
    notch.addLine(to: CGPoint(x: right - radius, y: bottom))
    notch.addQuadCurve(to: CGPoint(x: right, y: bottom + radius), control: CGPoint(x: right, y: bottom))
    notch.addLine(to: CGPoint(x: right, y: top - flare))
    notch.addQuadCurve(to: CGPoint(x: right + flare, y: top), control: CGPoint(x: right, y: top))
    notch.closeSubpath()
    fill(ctx, notch, .black)

    let middle = bottom + height / 2
    let art = CGRect(x: left + 64, y: middle - 63, width: 126, height: 126)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: art, cornerWidth: 30, cornerHeight: 30, transform: nil))
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([NSColor(red: 1.0, green: 0.58, blue: 0.30, alpha: 1), NSColor(red: 0.93, green: 0.25, blue: 0.56, alpha: 1)]),
        start: CGPoint(x: art.minX, y: art.maxY), end: CGPoint(x: art.maxX, y: art.minY), options: [])
    ctx.restoreGState()

    let barWidth: CGFloat = 22, gap: CGFloat = 16
    var x = right - 64 - (barWidth * 4 + gap * 3)
    for barHeight: CGFloat in [70, 124, 92, 142] {
        let bar = CGRect(x: x, y: middle - barHeight / 2, width: barWidth, height: barHeight)
        fill(ctx, CGPath(roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil),
             NSColor(red: 0.66, green: 0.58, blue: 1.0, alpha: 1))
        x += barWidth + gap
    }
    ctx.restoreGState()
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon(in: ctx)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try png(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputDirectory.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(iconutil.terminationStatus)
