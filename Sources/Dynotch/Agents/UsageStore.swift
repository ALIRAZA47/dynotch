import Foundation

/// How much of Claude's limits have been used, as the last active session reported it.
@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    private init() {}

    func start() {}

    /// Back to nothing, between snapshot scenes.
    func clearSample() {}
}
