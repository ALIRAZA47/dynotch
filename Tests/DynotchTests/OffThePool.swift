import Foundation

/// Runs something that blocks, like a socket client waiting for an answer, on a thread of its own.
/// Tasks share a few threads, three on CI, and a task that blocks keeps one. If the rest of the test
/// needs that thread before the blocking can end, nothing moves until the job's time runs out.
func offThePool<Value>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(with: Result(catching: work)) }
    }
}
