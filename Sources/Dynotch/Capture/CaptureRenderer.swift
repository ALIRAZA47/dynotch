import AppKit
import CoreGraphics

/// Draws the marks with Core Graphics, in the editor and into the finished image alike, so what's
/// copied or saved is what was on screen, pixel for pixel. Every routine works in the display's
/// points with the origin at the top-left, as the editor's model has them.
enum CaptureRenderer {
    /// The display's pixels and scale, which the blur takes its blocks from.
    struct Source {
        let image: CGImage
        let scale: CGFloat
    }

    /// Composes the selected part of a frozen display and its marks into an image at the display's scale.
    static func compose(source: Source, selection: CGRect, annotations: [Annotation]) -> CGImage? {
        let scale = source.scale
        let selection = selection.standardized
        let pixels = CGRect(x: (selection.minX * scale).rounded(), y: (selection.minY * scale).rounded(),
                            width: (selection.width * scale).rounded(), height: (selection.height * scale).rounded())
            .intersection(CGRect(x: 0, y: 0, width: source.image.width, height: source.image.height))
        guard pixels.width >= 1, pixels.height >= 1, let crop = source.image.cropping(to: pixels) else { return nil }
        let width = Int(pixels.width), height = Int(pixels.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        // From here on, the display's points with a top-left origin, as the editor drew them.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -pixels.minX / scale, y: -pixels.minY / scale)
        draw(annotations, in: context, source: source)
        return context.makeImage()
    }

    /// Draws the marks into a context whose coordinates are the display's points with a top-left origin.
    static func draw(_ annotations: [Annotation], in context: CGContext, source: Source?) {
        for annotation in annotations {
            draw(annotation, in: context, source: source)
        }
    }

    static func draw(_ annotation: Annotation, in context: CGContext, source: Source?) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setShouldAntialias(true)
        let color = annotation.color
        let width = annotation.width
        switch annotation.kind {
        case .pencil(let points):
            context.setStrokeColor(color.cgColor())
            context.setLineWidth(width)
            stroke(points, in: context)
        case .marker(let points):
            context.setStrokeColor(color.cgColor(alpha: 0.42))
            context.setLineWidth(Annotation.markerWidth(for: width))
            stroke(points, in: context)
        case .line(let from, let to):
            context.setStrokeColor(color.cgColor())
            context.setLineWidth(width)
            stroke([from, to], in: context)
        case .arrow(let from, let to):
            drawArrow(from: from, to: to, color: color, width: width, in: context)
        case .rectangle(let rect):
            context.setStrokeColor(color.cgColor())
            context.setLineWidth(width)
            context.stroke(rect.standardized)
        case .ellipse(let rect):
            context.setStrokeColor(color.cgColor())
            context.setLineWidth(width)
            context.strokeEllipse(in: rect.standardized)
        case .text(let origin, let string):
            let font = NSFont.systemFont(ofSize: Annotation.fontSize(for: width), weight: .medium)
            drawText(string, at: origin, font: font, color: color.cgColor(), in: context)
        case .blur(let rect):
            guard let source, let patch = pixelated(rect, block: Annotation.blockSize(for: width), source: source) else { return }
            drawImage(patch, in: rect.standardized, in: context)
        case .counter(let center, let number):
            let radius = Annotation.badgeRadius(for: width)
            context.setFillColor(color.cgColor())
            context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            let font = NSFont.systemFont(ofSize: (radius * 1.15).rounded(), weight: .bold)
            drawText(String(number), centeredAt: center, font: font, color: color.contrastingColor, in: context)
        }
    }

    // MARK: Strokes

    /// A single point draws a dot, thanks to the round caps.
    private static func stroke(_ points: [CGPoint], in context: CGContext) {
        guard let first = points.first else { return }
        context.beginPath()
        context.move(to: first)
        if points.count == 1 {
            context.addLine(to: first)
        } else {
            for point in points.dropFirst() { context.addLine(to: point) }
        }
        context.strokePath()
    }

    private static func drawArrow(from: CGPoint, to: CGPoint, color: AnnotationColor, width: CGFloat, in context: CGContext) {
        let dx = to.x - from.x, dy = to.y - from.y
        let length = hypot(dx, dy)
        context.setStrokeColor(color.cgColor())
        context.setFillColor(color.cgColor())
        context.setLineWidth(width)
        guard length > 0.5 else {
            stroke([from], in: context)
            return
        }
        let ux = dx / length, uy = dy / length
        let headLength = min(length, max(12, width * 4))
        let headWidth = max(10, width * 3.2)
        let base = CGPoint(x: to.x - ux * headLength, y: to.y - uy * headLength)
        // The shaft stops short of the head's base, so the round cap doesn't poke out beside it.
        let shaftEnd = CGPoint(x: base.x + ux * min(headLength / 2, width), y: base.y + uy * min(headLength / 2, width))
        stroke([from, shaftEnd], in: context)
        context.beginPath()
        context.move(to: to)
        context.addLine(to: CGPoint(x: base.x - uy * headWidth / 2, y: base.y + ux * headWidth / 2))
        context.addLine(to: CGPoint(x: base.x + uy * headWidth / 2, y: base.y - ux * headWidth / 2))
        context.closePath()
        context.fillPath()
    }

    // MARK: Text

    private static func attributed(_ string: String, font: NSFont, color: CGColor) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color) ?? .white])
    }

    /// Draws with AppKit's text system, which also lays out the editor's text field, so the two agree.
    private static func drawText(_ string: String, at origin: CGPoint, font: NSFont, color: CGColor, in context: CGContext) {
        let text = attributed(string, font: font, color: color)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        text.draw(at: origin)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawText(_ string: String, centeredAt center: CGPoint, font: NSFont, color: CGColor, in context: CGContext) {
        let size = attributed(string, font: font, color: color).size()
        drawText(string, at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), font: font, color: color, in: context)
    }

    // MARK: Images

    /// The context is flipped, which would turn an image upside down; undo that for the image's rect.
    private static func drawImage(_ image: CGImage, in rect: CGRect, in context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        context.restoreGState()
    }

    private static let patches = NSCache<NSString, CGImage>()

    /// Drops the blur patches kept from a capture, once it's over.
    static func forgetPatches() {
        patches.removeAllObjects()
    }

    /// The source pixels under `rect`, averaged in blocks `block` points wide, as a small image with one
    /// pixel per block. Drawn back over the rect without interpolation, it pixelates the source.
    static func pixelated(_ rect: CGRect, block: CGFloat, source: Source) -> CGImage? {
        let rect = rect.standardized
        let scale = source.scale
        let pixels = CGRect(x: (rect.minX * scale).rounded(.down), y: (rect.minY * scale).rounded(.down),
                            width: (rect.width * scale).rounded(.up), height: (rect.height * scale).rounded(.up))
            .intersection(CGRect(x: 0, y: 0, width: source.image.width, height: source.image.height))
        guard pixels.width >= 1, pixels.height >= 1 else { return nil }
        let key = "\(ObjectIdentifier(source.image).hashValue)|\(source.image.width)x\(source.image.height)|\(pixels)|\(block)" as NSString
        if let patch = patches.object(forKey: key) { return patch }

        guard let crop = source.image.cropping(to: pixels) else { return nil }
        let width = Int(pixels.width), height = Int(pixels.height)
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { bytes -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        let side = max(2, Int((block * scale).rounded()))
        let columns = (width + side - 1) / side, rows = (height + side - 1) / side
        var blocks = [UInt8](repeating: 255, count: columns * rows * 4)
        for row in 0..<rows {
            for column in 0..<columns {
                var red = 0, green = 0, blue = 0, count = 0
                for y in (row * side)..<min(height, (row + 1) * side) {
                    for x in (column * side)..<min(width, (column + 1) * side) {
                        let offset = (y * width + x) * 4
                        red += Int(buffer[offset]); green += Int(buffer[offset + 1]); blue += Int(buffer[offset + 2])
                        count += 1
                    }
                }
                guard count > 0 else { continue }
                let offset = (row * columns + column) * 4
                blocks[offset] = UInt8(red / count); blocks[offset + 1] = UInt8(green / count); blocks[offset + 2] = UInt8(blue / count)
            }
        }
        let patch = blocks.withUnsafeMutableBytes { bytes -> CGImage? in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: bytes.baseAddress, width: columns, height: rows, bitsPerComponent: 8,
                                          bytesPerRow: columns * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            return context.makeImage()
        }
        if let patch { patches.setObject(patch, forKey: key) }
        return patch
    }
}
