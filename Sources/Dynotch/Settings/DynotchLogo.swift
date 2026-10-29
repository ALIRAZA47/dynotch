import SwiftUI

/// The app icon drawn in SwiftUI, so it looks the same in a bare debug build as in the app.
/// Measurements follow scripts/make-icon.swift, on its 824-point icon body.
struct DynotchLogo: View {
    var size: CGFloat

    var body: some View {
        let unit = size / 824
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Palette.indigo, Palette.navy], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Palette.lavender.opacity(0.55), Palette.lavender.opacity(0)],
                           center: UnitPoint(x: 0.5, y: 224 / 824.0), startRadius: 0, endRadius: 430 * unit)
            NotchShape(topRadius: 34 * unit, bottomRadius: 92 * unit)
                .fill(.black)
                .frame(width: 648 * unit, height: 230 * unit)
                .offset(x: 88 * unit)
            RoundedRectangle(cornerRadius: 30 * unit, style: .continuous)
                .fill(Palette.sunset)
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
        .clipShape(RoundedRectangle(cornerRadius: 185 * unit, style: .continuous))
        .accessibilityHidden(true)
    }
}
