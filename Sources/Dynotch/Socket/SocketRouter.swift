import Foundation

/// Hands each request from the socket to whoever deals with it, on the main actor. Each feature
/// registers its own ops as it starts, and adds its part to `dynotch status`.
///
/// Nothing that arrives here can answer a tool call or run anything named in a request: a socket op
/// can only tell the notch something, or ask what it's showing. Answers to Claude Code come from a
/// click in the notch and nowhere else.
@MainActor
final class SocketRouter {
    typealias Handler = @MainActor (SocketRequest, SocketConnection) -> Void

    static let shared = SocketRouter()

    private var handlers: [String: Handler] = [:]
    private var statusParts: [String: @MainActor () -> Any] = [:]
    private var server: LocalSocketServer?

    /// Starts listening. Whoever has ops to register does that first, so no request finds them missing.
    func start(path: String = SocketLocation.current()) {
        guard server == nil else { return }
        let server = LocalSocketServer(path: path) { [weak self] request, connection in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.route(request, connection) }
            }
        }
        do {
            try server.start()
            self.server = server
        } catch {
            NSLog("Dynotch: the socket didn't start: %@", String(describing: error))
        }
    }

    func stop() {
        server?.stop()
        server = nil
    }

    /// `handler` deals with requests for `op`, and has to answer each one, now or later.
    func handle(_ op: String, _ handler: @escaping Handler) {
        handlers[op] = handler
    }

    /// `part` adds `name` to what `dynotch status` reports. It has to come out as JSON.
    func reportsStatus(_ name: String, _ part: @escaping @MainActor () -> Any) {
        statusParts[name] = part
    }

    /// What can be asked for, besides `status`.
    var ops: [String] { handlers.keys.sorted() }

    func route(_ request: SocketRequest, _ connection: SocketConnection) {
        if request.op == "status" {
            connection.reply(status)
        } else if let handler = handlers[request.op] {
            handler(request, connection)
        } else {
            connection.reply(["ok": false, "error": "Dynotch doesn't know \"\(request.op)\""])
        }
    }

    var status: [String: Any] {
        var report: [String: Any] = ["ok": true]
        report["version"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "development"
        for (name, part) in statusParts { report[name] = part() }
        return report
    }
}
