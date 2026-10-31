import SwiftUI

/// The sessions, in a tab that's only there while there are some.
struct AgentsTabView: View {
    @ObservedObject var viewModel: NotchViewModel

    var body: some View { EmptyView() }
}

/// The tool call waiting for an answer. This is the only place with Allow and Deny.
struct ApprovalGlance: View {
    let approval: AgentApproval
    @ObservedObject var viewModel: NotchViewModel
    let band: CGFloat

    var body: some View { EmptyView() }

    /// How much taller than the closed notch the glance is for this approval.
    static func extraHeight(for approval: AgentApproval) -> CGFloat { 54 }
}

/// How many tool calls are waiting for an answer.
struct AgentsWaitingBadge: View {
    let count: Int
    var size: CGFloat = ClosedLayout.glyphSize

    var body: some View { EmptyView() }
}

extension SnapshotRenderer {
    static func agentScenes() -> [Scene] { [] }
}
