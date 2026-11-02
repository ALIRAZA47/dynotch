import DynotchShared
import SwiftUI

/// The usage ring, and how old its numbers are. The ring shows the fuller of the two limits, so the
/// seven days take it over when they're the nearer one.
struct UsageGlance: View {
    let band: CGFloat
    @ObservedObject private var store = UsageStore.shared
    @Environment(\.notchTheme) private var theme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let numbers = store.numbers
            let window = numbers?.main(at: now).flatMap { numbers?[$0] }
            GlanceLayout(band: band) {
                UsageRing(window: window)
            } trailing: {
                if let numbers {
                    Text(numbers.age(at: now))
                        .font(NotchFont.caption)
                        .foregroundStyle(theme.tertiary)
                        .lineLimit(1)
                }
            } center: {
                GlanceLines(title: numbers?.title(at: now) ?? "No numbers yet",
                            subtitle: numbers?.subtitle(at: now) ?? "They come from Claude Code's status line")
            }
        }
    }
}

/// The ring on the glance's left, with the number in it. With nothing running, only its track.
private struct UsageRing: View {
    let window: UsageWindow?
    @Environment(\.notchTheme) private var theme

    var body: some View {
        ZStack {
            if let window {
                ProgressRing(progress: window.fraction, color: window.tint(theme.accent), lineWidth: 4, halo: true)
                Text("\(window.percent)")
                    .font(NotchFont.numeric(15))
                    .foregroundStyle(theme.primary)
                    .contentTransition(.numericText())
            } else {
                Circle().stroke(theme.secondary.opacity(0.22), lineWidth: 4)
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.secondary)
            }
        }
        .padding(2)
    }
}

/// The way in from the day's chips: how much of the fuller limit is used. It's gone with the switch
/// off, and once everything has reset there's no number left to show.
struct UsageChip: View {
    let now: Date
    let action: () -> Void
    @ObservedObject private var store = UsageStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.notchTheme) private var theme

    var body: some View {
        if settings.liveUsage, let numbers = store.numbers, let limit = numbers.main(at: now), let window = numbers[limit] {
            GlanceChip(symbol: LiveActivityKind.usage.symbol, tint: window.tint(theme.accent),
                       text: limit.short(percent: window.percent, hasReset: false), action: action)
        }
    }
}

extension SnapshotRenderer {
    /// The ring in each state it can be in, the chip that leads to it, and the heads-up.
    static func usageScenes() -> [Scene] {
        let hour: TimeInterval = 3600
        func load(_ fiveHour: (percent: Int, resetsIn: TimeInterval)?, _ sevenDay: (percent: Int, resetsIn: TimeInterval)?,
                  age: TimeInterval = 180) -> @MainActor () -> Void {
            {
                let now = Date.now
                func window(_ numbers: (percent: Int, resetsIn: TimeInterval)?) -> UsageWindow? {
                    numbers.map { UsageWindow(percent: $0.percent, resetsAt: now.addingTimeInterval($0.resetsIn)) }
                }
                UsageStore.shared.loadSample(fiveHour: window(fiveHour), sevenDay: window(sevenDay),
                                             receivedAt: now.addingTimeInterval(-age))
            }
        }
        let normal = load((62, 74 * 60), (38, 76 * hour))
        func today(_ numbers: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
            {
                let lunch = CalendarService.shared.events.filter { $0.title == "Lunch with Sam" }
                CalendarService.shared.loadSample(events: lunch, reminders: CalendarService.shared.reminders)
                numbers()
            }
        }
        let virtualNotch = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                                         closedSize: CGSize(width: 190, height: 24), hasHardwareNotch: false)
        let warning = LiveNotice(key: "usage", symbol: LiveActivityKind.usage.symbol, tint: .orange, text: "Claude usage",
                                 detail: "84% of your 5 hours", actions: [NoticeAction(title: "Show", kind: .showUsage)])
        let both = LiveNotice(key: "usage", symbol: LiveActivityKind.usage.symbol, tint: .red, text: "Claude usage",
                              detail: "96% of your 5 hours · 82% of your 7 days",
                              actions: [NoticeAction(title: "Show", kind: .showUsage)])
        return [
            Scene(name: "usage-1-normal", phase: .glance, showingUsage: true, setUp: normal),
            Scene(name: "usage-2-near-the-limit", phase: .glance, showingUsage: true, setUp: load((86, 74 * 60), (38, 76 * hour))),
            Scene(name: "usage-3-nearly-out", phase: .glance, showingUsage: true, setUp: load((97, 22 * 60), (61, 76 * hour))),
            Scene(name: "usage-4-seven-days-fuller", phase: .glance, showingUsage: true, setUp: load((12, 4 * hour), (84, 76 * hour))),
            Scene(name: "usage-5-old-numbers", phase: .glance, showingUsage: true, setUp: load((62, 14 * 60), (38, 76 * hour), age: 4 * hour)),
            Scene(name: "usage-6-five-hours-reset", phase: .glance, showingUsage: true, setUp: load((62, -hour), (38, 76 * hour), age: 2 * hour)),
            Scene(name: "usage-7-all-reset", phase: .glance, showingUsage: true, setUp: load((62, -hour), (38, -hour), age: 3 * 24 * hour)),
            Scene(name: "usage-8-one-limit", phase: .glance, showingUsage: true, setUp: load((62, 74 * 60), nil, age: 0)),
            Scene(name: "usage-9-full-and-virtual", phase: .glance, geometry: virtualNotch, showingUsage: true,
                  setUp: load((100, 9 * 60), (100, 6 * 24 * hour + 23 * hour))),
            Scene(name: "usage-10-no-numbers", phase: .glance, showingUsage: true),
            Scene(name: "usage-11-today-chip", phase: .glance, hasTrack: false, setUp: today(normal)),
            Scene(name: "usage-12-today-chip-near-the-limit", phase: .glance, hasTrack: false,
                  setUp: today(load((86, 74 * 60), (38, 76 * hour)))),
            // Every chip at once, which the row can't hold: this one shows what gives way.
            Scene(name: "usage-13-today-chip-crowded", phase: .glance, hasTrack: false, setUp: today {
                normal()
                LiveActivityCenter.shared.loadSample(recents: [], unseen: 3)
                QuickToggles.shared.loadSample(awakeUntil: .now.addingTimeInterval(102 * 60))
            }),
            Scene(name: "usage-14-notice", phase: .closed, activity: .notice(warning)),
            Scene(name: "usage-15-notice-glance", phase: .glance, activity: .notice(warning)),
            Scene(name: "usage-16-notice-both", phase: .closed, activity: .notice(both)),
            Scene(name: "usage-17-notice-both-glance", phase: .glance, activity: .notice(both)),
            // With the switch off the chip goes. The scene after it turns the switch back on.
            Scene(name: "usage-18-today-switch-off", phase: .glance, hasTrack: false, setUp: today {
                normal()
                AppSettings.shared.liveUsage = false
            }),
            Scene(name: "usage-19-recent", phase: .glance, showingRecent: true, setUp: {
                LiveActivityCenter.shared.loadSample(recents: [
                    RecentNotice(id: UUID(), symbol: warning.symbol, tint: warning.tint, title: warning.text, detail: warning.detail,
                                 date: .now.addingTimeInterval(-9 * 60), actions: warning.actions),
                ], unseen: 1)
            }, prepare: { AppSettings.shared.liveUsage = true }),
        ]
    }
}
