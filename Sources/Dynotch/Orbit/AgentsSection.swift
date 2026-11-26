import AppKit
import DynotchShared
import SwiftUI

/// Agents: the Claude Code sessions, the CI run and the reviews waiting on you, with Claude's limits
/// along the foot. A session with a tool call waiting is the one card with an accent edge and its
/// buttons always showing: Review, which turns the notch to the glance, and the way back to its
/// terminal. There's no Allow here: that's only ever in the glance.
struct AgentsSectionView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var deck = AgentDeck.shared
    @ObservedObject private var ci = CIMonitor.shared
    @ObservedObject private var usage = UsageStore.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(at: context.date)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .orbitHeader("Agents", subtitle: subtitle)
    }

    @ViewBuilder
    private func content(at now: Date) -> some View {
        let sessions = deck.ordered
        let waiting = sessions.filter { deck.hasApproval(forSession: $0.id) }
        let others = sessions.filter { !deck.hasApproval(forSession: $0.id) }
        let limits = settings.liveUsage ? usage.numbers : nil
        VStack(spacing: 0) {
            if sessions.isEmpty, ci.run == nil, ci.reviewCount == 0 {
                EmptyState(symbol: "sparkles", message: "No sessions right now")
            } else {
                Scroller(.vertical, fadesOverflow: true) {
                    VStack(spacing: 0) {
                        ForEach(waiting) { session in
                            WaitingSessionCard(session: session, now: now, actions: actions(for: session, isWaiting: true))
                                .padding(.bottom, 8)
                        }
                        ForEach(Array(others.enumerated()), id: \.element.id) { index, session in
                            if index > 0 { OrbitRowDivider() }
                            sessionRow(session, at: now)
                        }
                        if let run = ci.run {
                            if !others.isEmpty { OrbitRowDivider() }
                            ciRow(run)
                        }
                        if ci.reviewCount > 0 {
                            if !others.isEmpty || ci.run != nil { OrbitRowDivider() }
                            reviewsRow(ci.reviewCount)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            if let limits, UsageLimit.allCases.contains(where: { limits[$0] != nil }) {
                UsageMeters(numbers: limits, now: now)
                    .padding(.top, 10)
            }
        }
    }

    /// "3 Claude Code sessions · 1 needs you", or the reviews when nothing does.
    private var subtitle: String {
        var parts: [String] = []
        let count = deck.sessions.count
        parts.append(count == 0 ? "No sessions" : count == 1 ? "1 session" : "\(count) sessions")
        if !deck.approvals.isEmpty {
            parts.append(deck.approvals.count == 1 ? "1 needs you" : "\(deck.approvals.count) need you")
        } else if ci.reviewCount > 0 {
            parts.append(ci.reviewCount == 1 ? "1 pull request to review" : "\(ci.reviewCount) pull requests to review")
        }
        return parts.joined(separator: " · ")
    }

    /// Review for a session with a tool call waiting, and the way back to where it runs.
    private func actions(for session: AgentSession, isWaiting: Bool) -> [RowAction] {
        var actions: [RowAction] = []
        if let back = session.origin.action {
            actions.append(RowAction(title: back.title) {
                session.origin.focus()
                viewModel.close()
            })
        }
        if isWaiting {
            actions.append(RowAction(title: "Review", role: .primary) {
                AgentDeck.shared.bringForward(session: session.id)
                viewModel.showApproval()
            })
        }
        return actions
    }

    private func sessionRow(_ session: AgentSession, at now: Date) -> some View {
        let state = SessionState(session.state)
        return OrbitRow(id: "session.\(session.id)", symbol: "terminal", title: session.project,
                        subtitle: session.line(at: now), status: state.title, statusColor: state.color(in: theme),
                        needsYou: state == .waiting, actions: actions(for: session, isWaiting: false))
    }

    private func ciRow(_ run: CIRun) -> some View {
        var actions: [RowAction] = []
        if let open = run.openAction {
            actions.append(RowAction(title: open.title) { open.perform(in: viewModel, fromRecent: true) })
        }
        return OrbitRow(id: "ci.\(run.id)", symbol: run.symbol,
                        title: ci.others > 0 ? "\(run.workflow) and \(ci.others) more" : run.workflow,
                        subtitle: run.summary, status: run.statusText,
                        statusColor: run.phase == .running ? theme.live : theme.tertiary, actions: actions)
    }

    private func reviewsRow(_ count: Int) -> some View {
        OrbitRow(id: "ci.reviews", symbol: "arrow.triangle.pull",
                 title: count == 1 ? "A pull request to review" : "\(count) pull requests to review",
                 subtitle: "Waiting for your review on GitHub", status: CIMonitor.reviewsText(count),
                 actions: [RowAction(title: "Open") {
                     NSWorkspace.shared.open(CIMonitor.reviewsPage)
                     viewModel.close()
                 }])
    }

    @Environment(\.notchTheme) private var theme
}

/// A session's state, as its row says it.
private enum SessionState: Equatable {
    case ready, working, waiting, done

    init(_ state: AgentSession.State) {
        switch state {
        case .ready: self = .ready
        case .working: self = .working
        case .waiting: self = .waiting
        case .done: self = .done
        }
    }

    var title: String {
        switch self {
        case .ready: "Ready"
        case .working: "Working"
        case .waiting: "Waiting"
        case .done: "Done"
        }
    }

    /// Green while it runs, the accent while it needs you; nothing once it's done.
    func color(in theme: NotchTheme) -> Color? {
        switch self {
        case .ready: theme.tertiary
        case .working: theme.live
        case .waiting: theme.accent
        case .done: nil
        }
    }
}

/// The session a tool call waits on: a raised card ringed in the accent, its project and what it
/// asks, and its buttons always showing. Review goes to the glance, where Allow is.
private struct WaitingSessionCard: View {
    let session: AgentSession
    let now: Date
    let actions: [RowAction]
    @Environment(\.notchTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Text(waited)
                .font(NotchFont.time(14))
                .foregroundStyle(theme.accentText)
                .lineLimit(1)
                .frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(theme.accent)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(session.project)
                        .font(NotchFont.headline)
                        .foregroundStyle(theme.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(session.line(at: now))
                    .font(NotchFont.subheadline)
                    .foregroundStyle(theme.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Always showing, whatever Row actions says: this is the one that needs you.
            HStack(spacing: 6) {
                ForEach(actions) { action in
                    RowActionButton(action: action, height: 28)
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(height: NotchTheme.rowHeight + 6)
        .background(theme.cardShape.fill(theme.raised))
        .overlay(theme.cardShape.strokeBorder(theme.accent, lineWidth: 1.5))
        .padding(.horizontal, 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(session.project), needs you")
    }

    /// How long it has waited: "Now", then minutes.
    private var waited: String {
        let minutes = Int(now.timeIntervalSince(session.since) / 60)
        return minutes < 1 ? "Now" : AgentSession.span(minutes: minutes)
    }
}

/// Claude's two limits side by side: what's used, and when it starts over.
private struct UsageMeters: View {
    let numbers: UsageNumbers
    let now: Date
    @Environment(\.notchTheme) private var theme

    var body: some View {
        HStack(spacing: 24) {
            ForEach(UsageLimit.allCases, id: \.self) { limit in
                if let window = numbers[limit] {
                    meter(limit, window)
                }
            }
        }
        .padding(.horizontal, 10)
    }

    private func meter(_ limit: UsageLimit, _ window: UsageWindow) -> some View {
        let hasReset = window.hasReset(at: now)
        let fraction = hasReset ? 0 : min(max(Double(window.percent) / 100, 0), 1)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(limit == .fiveHour ? "5-hour limit" : "7-day limit")
                    .font(NotchFont.label)
                    .tracking(0.66)
                    .textCase(.uppercase)
                    .foregroundStyle(theme.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(hasReset ? "Reset" : "\(window.percent)% · resets \(resets(window.resetsAt))")
                    .font(NotchFont.time(11.5, .medium))
                    .foregroundStyle(theme.secondary)
                    .lineLimit(1)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    theme.controlShape.fill(theme.hover)
                    theme.controlShape.fill(window.percent >= UsageWindow.warnsAt ? window.tint(theme.primary) : theme.primary)
                        .frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 6)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// "13:00" today, a weekday further off.
    private func resets(_ date: Date) -> String {
        date.timeIntervalSince(now) < 20 * 3600
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated))
    }
}
