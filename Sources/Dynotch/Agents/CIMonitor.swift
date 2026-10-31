import Foundation

/// A GitHub Actions run being watched.
struct CIRun: Identifiable, Equatable {
    let id: Int
    var repository: String
    var branch: String
    var workflow: String
    var url: URL
}

/// Watches GitHub Actions through `gh`, only while a run is active. Dynotch stores no token.
@MainActor
final class CIMonitor: ObservableObject {
    static let shared = CIMonitor()

    /// The run on show, while one is active.
    @Published private(set) var run: CIRun?
    /// Pull requests waiting for your review.
    @Published private(set) var reviewCount = 0

    private init() {}

    func start() {}

    /// Back to nothing, between snapshot scenes.
    func clearSample() {
        run = nil
        reviewCount = 0
    }
}
