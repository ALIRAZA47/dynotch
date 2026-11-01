import SwiftUI

/// A script's symbol and name in the left ear. What it picks carries the terminal badge, so it can't
/// pass for one of Dynotch's own, and the default symbol is the terminal itself.
struct ScriptLabel: View {
    let activity: ScriptActivity
    @Environment(\.notchTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: activity.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(activity.tint ?? theme.accent)
                .overlay(alignment: .bottomTrailing) {
                    if activity.needsBadge { ScriptBadge() }
                }
            Text(activity.key)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.primary)
                .lineLimit(1)
        }
    }
}

/// How far along it is, in the right ear. With no number yet, a small arc turning.
struct ScriptPercent: View {
    let activity: ScriptActivity
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let tint = activity.tint ?? theme.accent
        if let text = activity.percentText {
            Text(text)
                .font(NotchFont.numeric(12.5))
                .foregroundStyle(tint)
                .contentTransition(.numericText())
        } else {
            SpinningArc(color: tint, lineWidth: 2.2)
                .frame(width: 13, height: 13)
        }
    }
}

/// The ring at the end of the right ear, while something else has the notch.
struct ScriptGlyph: View {
    let activity: ScriptActivity
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let tint = activity.tint ?? theme.accent
        Group {
            if let fraction = activity.fraction {
                ProgressRing(progress: fraction, color: tint, lineWidth: 2.4)
            } else {
                SpinningArc(color: tint, lineWidth: 2.4)
            }
        }
        .padding(1.5)
    }
}

/// The thin line along the foot of the closed notch. With no number yet, only its track.
struct ScriptFootLine: View {
    let activity: ScriptActivity
    var height: CGFloat = 3
    @Environment(\.notchTheme) private var theme

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.16))
                if let fraction = activity.fraction {
                    Capsule()
                        .fill(activity.tint ?? theme.accent)
                        .frame(width: max(height, proxy.size.width * fraction))
                }
            }
        }
        .frame(height: height)
        .animation(.notchActivity, value: activity.percent)
        .accessibilityElement()
        .accessibilityLabel(activity.percentText.map { "\(activity.key), \($0)" } ?? activity.key)
    }
}

/// The percentage, and what the script says it's doing. Any others running are a count on the right.
struct ScriptGlance: View {
    let activity: ScriptActivity
    let band: CGFloat
    @ObservedObject private var store = ScriptActivityStore.shared
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let tint = activity.tint ?? theme.accent
        let others = store.activities.count - 1
        GlanceLayout(band: band) {
            ZStack {
                if let fraction = activity.fraction {
                    ProgressRing(progress: fraction, color: tint, lineWidth: 4, halo: true)
                } else {
                    SpinningArc(color: tint, lineWidth: 4)
                }
                Image(systemName: activity.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .padding(2)
            .overlay(alignment: .bottomTrailing) {
                if activity.needsBadge { ScriptBadge().scaleEffect(1.6, anchor: .bottomTrailing) }
            }
        } trailing: {
            if others > 0 {
                Text("\(others) more")
                    .font(NotchFont.numeric(12))
                    .foregroundStyle(theme.secondary)
                    .lineLimit(1)
            }
        } center: {
            GlanceFigure(caption: activity.detail.map { "\(activity.key) · \($0)" } ?? activity.key,
                         figure: activity.percentText ?? "Running", tint: tint)
        }
    }
}
