import SwiftUI

/// The marks the capture editor draws over a screenshot. Geometry is in the display's points,
/// with the origin at its top-left corner, so a mark stays put when the selection moves.
struct Annotation: Identifiable, Equatable {
    enum Kind: Equatable {
        /// A freehand path.
        case pencil(points: [CGPoint])
        case line(from: CGPoint, to: CGPoint)
        /// A line with a filled head at `to`.
        case arrow(from: CGPoint, to: CGPoint)
        case rectangle(CGRect)
        case ellipse(CGRect)
        /// A wide, see-through highlighter stroke.
        case marker(points: [CGPoint])
        /// Text whose top-left corner sits at `origin`. The font follows the width.
        case text(origin: CGPoint, string: String)
        /// The source pixels under the rectangle, in coarse blocks.
        case blur(CGRect)
        /// A numbered badge centered on `center`.
        case counter(center: CGPoint, number: Int)
    }

    let id: UUID
    var kind: Kind
    var color: AnnotationColor
    /// The stroke width in points, 1 to 16. Text, the marker, the badge and the blur's blocks scale with it.
    var width: CGFloat

    init(id: UUID = UUID(), kind: Kind, color: AnnotationColor, width: CGFloat) {
        self.id = id
        self.kind = kind
        self.color = color
        self.width = width
    }

    /// The text's font, from the width: 12 points at the thinnest, 48 at the widest.
    static func fontSize(for width: CGFloat) -> CGFloat {
        (12 + (width - 1) * 2.4).rounded()
    }

    /// The marker's stroke, wider than a pencil's at the same setting.
    static func markerWidth(for width: CGFloat) -> CGFloat { max(8, width * 3) }

    /// The blur's block edge in points: coarser as the width goes up.
    static func blockSize(for width: CGFloat) -> CGFloat { (4 + width * 1.5).rounded() }

    /// The badge's radius.
    static func badgeRadius(for width: CGFloat) -> CGFloat { 10 + width * 1.5 }

    /// Roughly what the mark covers, for hit tests and labels.
    var bounds: CGRect {
        switch kind {
        case .pencil(let points), .marker(let points):
            return Self.bounds(of: points).insetBy(dx: -width, dy: -width)
        case .line(let from, let to), .arrow(let from, let to):
            return Self.bounds(of: [from, to]).insetBy(dx: -width, dy: -width)
        case .rectangle(let rect), .ellipse(let rect), .blur(let rect):
            return rect.standardized
        case .text(let origin, let string):
            let size = Self.fontSize(for: width)
            let lines = max(1, string.split(separator: "\n", omittingEmptySubsequences: false).count)
            return CGRect(x: origin.x, y: origin.y, width: CGFloat(max(1, string.count)) * size * 0.6, height: CGFloat(lines) * size * 1.25)
        case .counter(let center, _):
            let radius = Self.badgeRadius(for: width)
            return CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        }
    }

    private static func bounds(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// The eight swatches in the toolbar.
enum AnnotationColor: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, blue, purple, white, black

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    /// sRGB components, bright enough to stand out on a screenshot.
    var components: (red: CGFloat, green: CGFloat, blue: CGFloat) {
        switch self {
        case .red: (1.0, 0.23, 0.19)
        case .orange: (1.0, 0.58, 0.0)
        case .yellow: (1.0, 0.84, 0.04)
        case .green: (0.2, 0.78, 0.35)
        case .blue: (0.04, 0.52, 1.0)
        case .purple: (0.69, 0.32, 0.87)
        case .white: (1.0, 1.0, 1.0)
        case .black: (0.0, 0.0, 0.0)
        }
    }

    var color: Color {
        let (red, green, blue) = components
        return Color(red: red, green: green, blue: blue)
    }

    func cgColor(alpha: CGFloat = 1) -> CGColor {
        let (red, green, blue) = components
        return CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// Black on the light swatches, white on the rest: what a badge's number is drawn in.
    var contrastingColor: CGColor {
        let (red, green, blue) = components
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return luminance > 0.6 ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1)
    }
}

/// What the toolbar offers. The raw value is the key that picks it, as in Flameshot.
enum AnnotationTool: String, CaseIterable, Identifiable {
    case pencil = "p"
    case line = "l"
    case arrow = "a"
    case rectangle = "r"
    case ellipse = "c"
    case marker = "m"
    case text = "t"
    case blur = "b"
    case counter = "n"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pencil: "Pencil"
        case .line: "Line"
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .marker: "Marker"
        case .text: "Text"
        case .blur: "Blur"
        case .counter: "Counter"
        }
    }

    var symbol: String {
        switch self {
        case .pencil: "pencil"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .marker: "highlighter"
        case .text: "textformat"
        case .blur: "square.grid.3x3.fill"
        case .counter: "1.circle.fill"
        }
    }

    /// A click places these; the rest are dragged out.
    var placesOnClick: Bool { self == .text || self == .counter }
}

/// The marks on a capture, with undo and redo. Every change keeps the list it replaced, so
/// undo puts back whatever a step did, whether it added, moved or removed a mark.
@MainActor
final class AnnotationDocument: ObservableObject {
    @Published private(set) var annotations: [Annotation] = []
    private var past: [[Annotation]] = []
    private var future: [[Annotation]] = []

    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    func add(_ annotation: Annotation) {
        commit(annotations + [annotation])
    }

    func update(_ annotation: Annotation) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        var next = annotations
        next[index] = annotation
        commit(next)
    }

    func remove(_ id: Annotation.ID) {
        guard annotations.contains(where: { $0.id == id }) else { return }
        commit(annotations.filter { $0.id != id })
    }

    func undo() {
        guard let previous = past.popLast() else { return }
        future.append(annotations)
        annotations = previous
    }

    func redo() {
        guard let next = future.popLast() else { return }
        past.append(annotations)
        annotations = next
    }

    func clear() {
        annotations = []
        past = []
        future = []
    }

    /// The number the next counter badge gets: one past the highest so far, so undo counts back down.
    var nextCounter: Int {
        (annotations.compactMap { annotation -> Int? in
            if case .counter(_, let number) = annotation.kind { return number }
            return nil
        }.max() ?? 0) + 1
    }

    private func commit(_ next: [Annotation]) {
        past.append(annotations)
        future.removeAll()
        annotations = next
    }
}
