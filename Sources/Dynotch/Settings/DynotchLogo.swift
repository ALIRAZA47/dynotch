import SwiftUI

/// The app icon drawn in SwiftUI, so it looks the same in a bare debug build as in the app.
/// Measurements follow scripts/make-icon.swift, on its 824-point icon body: graphite glass lit from
/// above, its top edge catching the light, a lavender bloom under the notch, and the notch with
/// its art and bars.
struct DynotchLogo: View {
    var size: CGFloat

    /// The body's graphite, top to bottom.
    private static let top = Color(red: 0.17, green: 0.17, blue: 0.19)
    private static let bottom = Color(red: 0.055, green: 0.055, blue: 0.065)

    var body: some View {
        let unit = size / 824
        let shape = RoundedRectangle(cornerRadius: 185 * unit, style: .continuous)
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Self.top, Self.bottom], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Palette.lavender.opacity(0.4), Palette.lavender.opacity(0)],
                           center: UnitPoint(x: 0.5, y: 224 / 824.0), startRadius: 0, endRadius: 430 * unit)
            // The rim: 6 wide just inside the edge, bright along the top and gone by 45% of the way down.
            shape.strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(0.28), location: 0),
                                                      .init(color: .white.opacity(0), location: 0.45)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 6 * unit)
            NotchShape(topRadius: 34 * unit, bottomRadius: 92 * unit)
                .fill(.black)
                .frame(width: 648 * unit, height: 230 * unit)
                .offset(x: 88 * unit)
            let art = RoundedRectangle(cornerRadius: 30 * unit, style: .continuous)
            art.fill(Palette.sunset)
                .overlay(art.strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.05)],
                                                         startPoint: .top, endPoint: .bottom), lineWidth: 4 * unit))
                .frame(width: 126 * unit, height: 126 * unit)
                .offset(x: 186 * unit, y: 52 * unit)
            HStack(alignment: .center, spacing: 16 * unit) {
                ForEach([70.0, 124, 92, 142], id: \.self) { height in
                    Capsule().fill(Palette.lilac).frame(width: 22 * unit, height: height * unit)
                }
            }
            .frame(height: 142 * unit)
            .offset(x: 502 * unit, y: 44 * unit)
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .accessibilityHidden(true)
    }
}
