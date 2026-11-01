import AppKit
import SwiftUI

extension CIRun {
    /// The color of how it's going. Grey until something's running.
    var tint: Color { phase == .running ? CIMonitor.tint : .gray }

    var symbol: String {
        switch phase {
        case .queued: "clock.fill"
        case .waiting: "hourglass"
        case .running: "arrow.triangle.branch"
        }
    }

    /// With several runs, how many of them are over. With one there's no telling how far along it is.
    fileprivate var fraction: Double? {
        total > 1 && finished > 0 ? Double(finished) / Double(total) : nil
    }
}

/// The workflow's name in the left ear.
struct CILabel: View {
    let run: CIRun
    @Environment(\.notchTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: run.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(run.tint)
            Text(run.workflow)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.primary)
                .lineLimit(1)
        }
    }
}

/// How the run is going, in the right ear. It changes at each look, so nothing ticks.
struct CIStatus: View {
    let run: CIRun

    var body: some View {
        Text(run.statusText)
            .font(NotchFont.numeric(12.5))
            .foregroundStyle(run.tint)
            .lineLimit(1)
            .fixedSize()
            .contentTransition(.numericText())
    }
}

/// The ring at the end of the right ear.
struct CIGlyph: View {
    let run: CIRun

    var body: some View {
        CIRing(run: run, lineWidth: 2.4)
            .padding(1.5)
            .accessibilityLabel("\(run.workflow), \(run.statusText)")
    }
}

/// How many of a push's runs are over, or a turning arc while there's no telling.
private struct CIRing: View {
    let run: CIRun
    let lineWidth: CGFloat
    var halo = false

    var body: some View {
        if let fraction = run.fraction {
            ProgressRing(progress: fraction, color: run.tint, lineWidth: lineWidth, halo: halo)
        } else {
            SpinningArc(color: run.tint, lineWidth: lineWidth)
        }
    }
}

/// The run, in the glance, with its button.
struct CIGlance: View {
    let run: CIRun
    @ObservedObject var viewModel: NotchViewModel
    let band: CGFloat
    @ObservedObject private var monitor = CIMonitor.shared

    var body: some View {
        GlanceLayout(band: band) {
            ZStack {
                CIRing(run: run, lineWidth: 4, halo: true)
                Image(systemName: run.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(run.tint)
            }
            .padding(2)
        } trailing: {
            CIStatus(run: run)
        } center: {
            // The chip gives up its word before the line about the run gets cut off.
            ViewThatFits(in: .horizontal) {
                row(isChipShort: false)
                row(isChipShort: true)
            }
        }
    }

    private func row(isChipShort: Bool) -> some View {
        HStack(spacing: 0) {
            GlanceLines(title: monitor.others > 0 ? "\(run.workflow) and \(monitor.others) more" : run.workflow,
                        subtitle: run.summary)
            Spacer(minLength: 0)
            if monitor.reviewCount > 0 {
                CIReviewsChip(count: monitor.reviewCount, viewModel: viewModel, isShort: isChipShort)
                    .padding(.leading, 8)
            }
            if let action = run.openAction {
                NoticeButton(action: action) {
                    // No notice to dismiss here: any on the notch is someone else's.
                    if viewModel.acceptsNoticeButtons { action.perform(in: viewModel, fromRecent: true) }
                }
                .padding(.leading, 8)
            }
        }
    }
}

/// Pull requests waiting for your review. A tap opens them on GitHub.
struct CIReviewsChip: View {
    let count: Int
    @ObservedObject var viewModel: NotchViewModel
    /// The number alone, where the words won't fit.
    var isShort = false

    var body: some View {
        GlanceChip(symbol: "arrow.triangle.pull", tint: .green, text: isShort ? "\(count)" : CIMonitor.reviewsText(count)) {
            NSWorkspace.shared.open(CIMonitor.reviewsPage)
            viewModel.close()
        }
        .accessibilityLabel(CIMonitor.reviewsText(count))
    }
}

extension SnapshotRenderer {
    static func ciScenes() -> [Scene] {
        let url = URL(string: "https://github.com/acme/app/actions/runs/1")
        let queued = CIRun(id: 1, repository: "acme/app", branch: "main", workflow: "Build", url: url, phase: .queued, seconds: 6)
        let running = CIRun(id: 2, repository: "acme/app", branch: "main", workflow: "Build", url: url, seconds: 134)
        let young = CIRun(id: 3, repository: "acme/app", branch: "main", workflow: "Build", url: url, seconds: 40)
        let several = CIRun(id: 4, repository: "acme/app", branch: "fix/login-redirect", workflow: "Integration tests",
                            url: url, seconds: 412, total: 3, finished: 1)
        let waiting = CIRun(id: 5, repository: "acme/app", branch: "main", workflow: "Deploy", url: url, phase: .waiting, seconds: 930)
        let passed = CIMonitor.notice(.passed, workflows: "Build and Docs", branch: "main", url: url)
        let failed = CIMonitor.notice(.failed, workflows: "Integration tests", branch: "fix/login-redirect", url: url)
        let cancelled = CIMonitor.notice(.cancelled, workflows: "Build", branch: "main", url: url)
        let signedOut = LiveNotice(key: "ci", symbol: "exclamationmark.triangle.fill", tint: .orange, text: "Signed out",
                                   detail: "Run gh auth login to follow CI")
        let today: @MainActor () -> Void = {
            let lunch = CalendarService.shared.events.filter { $0.title == "Lunch with Sam" }
            CalendarService.shared.loadSample(events: lunch, reminders: CalendarService.shared.reminders)
            CIMonitor.shared.loadSample(nil, reviewCount: 3)
        }
        return [
            Scene(name: "ci-1-queued", phase: .closed, activity: .ci(queued)),
            Scene(name: "ci-2-running-word", phase: .closed, activity: .ci(young)),
            Scene(name: "ci-3-running-time", phase: .closed, activity: .ci(running)),
            Scene(name: "ci-4-several-runs", phase: .closed, activity: .ci(several)),
            Scene(name: "ci-5-waiting", phase: .closed, activity: .ci(waiting)),
            Scene(name: "ci-6-with-timer", phase: .closed, activity: .ci(running), secondary: .timer),
            Scene(name: "ci-7-as-a-glyph", phase: .closed, activity: .notice(LiveNotice(
                key: "power", symbol: "bolt.fill", tint: .green, text: "82%")), secondary: .ci(running)),
            Scene(name: "ci-8-glyph-several", phase: .closed, activity: .music, secondary: .ci(several)),
            Scene(name: "ci-9-glance", phase: .glance, activity: .ci(running), setUp: { CIMonitor.shared.loadSample(running) }),
            Scene(name: "ci-10-glance-several", phase: .glance, activity: .ci(several),
                  setUp: { CIMonitor.shared.loadSample(several, others: 1) }),
            Scene(name: "ci-11-glance-reviews", phase: .glance, activity: .ci(several),
                  setUp: { CIMonitor.shared.loadSample(several, reviewCount: 3) }),
            Scene(name: "ci-12-glance-queued", phase: .glance, activity: .ci(queued), setUp: { CIMonitor.shared.loadSample(queued) }),
            Scene(name: "ci-13-passed", phase: .closed, activity: .notice(passed)),
            Scene(name: "ci-14-failed", phase: .closed, activity: .notice(failed)),
            Scene(name: "ci-15-failed-glance", phase: .glance, activity: .notice(failed)),
            Scene(name: "ci-16-cancelled", phase: .closed, activity: .notice(cancelled)),
            Scene(name: "ci-17-signed-out", phase: .closed, activity: .notice(signedOut)),
            Scene(name: "ci-18-reviews-chip", phase: .glance, hasTrack: false, setUp: today),
            // No room for it beside everything else, so the row keeps to the glance's edges without it.
            Scene(name: "ci-19-reviews-crowded", phase: .glance, hasTrack: false, setUp: {
                today()
                LiveActivityCenter.shared.loadSample(recents: [], unseen: 3)
                QuickToggles.shared.loadSample(awakeUntil: .now.addingTimeInterval(102 * 60))
            }),
        ]
    }
}
