import Darwin
import Foundation
import Testing
@testable import Dynotch

/// A socket in a scratch folder of its own, never the real one.
private final class ScratchSocket {
    let folder: String
    var path: String { folder + "/run/s.sock" }

    init() {
        // Short, since a socket's path can't be long.
        folder = NSTemporaryDirectory() + "dyn-" + UUID().uuidString.prefix(8)
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: folder) }

    /// A server that answers `ping` and keeps everything else waiting, handing it to `held`.
    func server(requestTimeout: TimeInterval = 5, held: @escaping @Sendable (SocketRequest, SocketConnection) -> Void = { _, _ in }) throws -> LocalSocketServer {
        let server = LocalSocketServer(path: path, requestTimeout: requestTimeout) { request, connection in
            if request.op == "ping" {
                connection.reply(["ok": true, "pong": request.string("word") ?? ""])
            } else {
                held(request, connection)
            }
        }
        try server.start()
        return server
    }
}

/// A connection with nothing in the way, for sending what the client never would.
private func rawConnection(to path: String) throws -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    var on: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    guard let address = SocketLocation.address(for: path) else { throw SocketClient.Failure.notRunning }
    let result = withUnsafePointer(to: address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard result == 0 else { throw SocketClient.Failure.notRunning }
    return descriptor
}

private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<300 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?
    var value: Value? { lock.withLock { stored } }
    func put(_ value: Value) { lock.withLock { stored = value } }
}

struct LocalSocketTests {
    @Test func aRequestGetsItsAnswer() throws {
        let scratch = ScratchSocket()
        let server = try scratch.server()
        defer { server.stop() }
        let answer = try SocketClient(path: scratch.path).send(["op": "ping", "word": "hello"])
        #expect(answer["pong"] as? String == "hello")
    }

    @Test func theSocketAndItsFolderAreThisUsersAlone() throws {
        let scratch = ScratchSocket()
        let server = try scratch.server()
        defer { server.stop() }
        var info = stat()
        #expect(lstat(scratch.path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFSOCK)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(lstat((scratch.path as NSString).deletingLastPathComponent, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700)
    }

    @Test func aFolderOthersCouldEnterIsTightened() throws {
        let scratch = ScratchSocket()
        let run = (scratch.path as NSString).deletingLastPathComponent
        #expect(mkdir(run, 0o755) == 0)
        #expect(chmod(run, 0o755) == 0)
        let server = try scratch.server()
        defer { server.stop() }
        var info = stat()
        #expect(lstat(run, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700)
    }

    @Test func aLinkInPlaceOfTheFolderIsRefused() throws {
        let scratch = ScratchSocket()
        let elsewhere = scratch.folder + "/elsewhere"
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        #expect(symlink(elsewhere, (scratch.path as NSString).deletingLastPathComponent) == 0)
        #expect(throws: LocalSocketServer.Failure.unsafeFolder) { try scratch.server() }
    }

    @Test func onlyThisUserGetsIn() {
        #expect(LocalSocketServer.accepts(peer: geteuid()))
        #expect(!LocalSocketServer.accepts(peer: geteuid() + 1))
        #expect(!LocalSocketServer.accepts(peer: 0, owner: 501))
    }

    @Test func aPathThatCantFitIsRefused() {
        let long = "/tmp/" + String(repeating: "a", count: SocketLocation.longestPath)
        #expect(SocketLocation.address(for: long) == nil)
        let server = LocalSocketServer(path: long) { _, _ in }
        #expect(throws: LocalSocketServer.Failure.pathTooLong) { try server.start() }
    }

    @Test func theEnvironmentCanMoveTheSocket() {
        #expect(SocketLocation.current(environment: ["DYNOTCH_SOCKET": "/tmp/x.sock"]) == "/tmp/x.sock")
        #expect(SocketLocation.current(environment: [:]).hasSuffix("/Dynotch/run/dynotch.sock"))
    }

    @Test func oneLeftByACrashIsReplaced() throws {
        let scratch = ScratchSocket()
        try LocalSocketServer.prepareFolder((scratch.path as NSString).deletingLastPathComponent)
        // Bound and closed, as a crash leaves it: the file's there and nothing is listening.
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        guard let address = SocketLocation.address(for: scratch.path) else { throw SocketClient.Failure.notRunning }
        _ = withUnsafePointer(to: address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(stale)
        #expect(FileManager.default.fileExists(atPath: scratch.path))
        #expect(!SocketClient(path: scratch.path).isAnswering)
        let server = try scratch.server()
        defer { server.stop() }
        #expect(SocketClient(path: scratch.path).isAnswering)
    }

    @Test func aSecondDynotchLeavesTheFirstAlone() throws {
        let scratch = ScratchSocket()
        let first = try scratch.server()
        defer { first.stop() }
        #expect(throws: LocalSocketServer.Failure.inUse) { try scratch.server() }
        #expect(try SocketClient(path: scratch.path).send(["op": "ping"])["ok"] as? Bool == true)
    }

    @Test func stoppingRemovesTheSocket() throws {
        let scratch = ScratchSocket()
        let server = try scratch.server()
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
    }

    @Test func nothingListeningSaysNotRunning() {
        let scratch = ScratchSocket()
        #expect(throws: SocketClient.Failure.notRunning) { try SocketClient(path: scratch.path).send(["op": "ping"]) }
    }

    @Test func aRequestThatIsntOneIsToldSo() async throws {
        let scratch = ScratchSocket()
        let server = try scratch.server()
        defer { server.stop() }
        let raw = try rawConnection(to: scratch.path)
        defer { close(raw) }
        #expect(write(raw, "not json\n", 9) == 9)
        var reply = [UInt8](repeating: 0, count: 200)
        let count = read(raw, &reply, reply.count)
        #expect(String(decoding: reply[0..<max(count, 0)], as: UTF8.self).contains("\"ok\":false"))
    }

    @Test func aClientThatNeverFinishesItsLineIsDropped() async throws {
        let scratch = ScratchSocket()
        let server = try scratch.server(requestTimeout: 0.1)
        defer { server.stop() }
        let raw = try rawConnection(to: scratch.path)
        defer { close(raw) }
        #expect(write(raw, "{\"op\":", 6) == 6)
        var byte: UInt8 = 0
        #expect(read(raw, &byte, 1) == 0)
    }

    @Test func aRequestTooLongIsDropped() async throws {
        let scratch = ScratchSocket()
        let server = try scratch.server()
        defer { server.stop() }
        let raw = try rawConnection(to: scratch.path)
        defer { close(raw) }
        let chunk = [UInt8](repeating: 0x61, count: 1 << 20)
        var written = 0
        while written <= LocalSocketServer.longestRequest + chunk.count {
            let count = write(raw, chunk, chunk.count)
            if count <= 0 { break }
            written += count
        }
        var byte: UInt8 = 0
        #expect(read(raw, &byte, 1) <= 0)
    }

    @Test func tooManyConnectionsAreTurnedAway() async throws {
        let scratch = ScratchSocket()
        let server = try scratch.server()
        defer { server.stop() }
        var held: [Int32] = []
        defer { held.forEach { close($0) } }
        for _ in 0..<LocalSocketServer.mostConnections { held.append(try rawConnection(to: scratch.path)) }
        // Each of those has been let in before the next goes past the listener's queue.
        try? await Task.sleep(for: .milliseconds(100))
        let extra = try rawConnection(to: scratch.path)
        defer { close(extra) }
        var byte: UInt8 = 0
        #expect(read(extra, &byte, 1) == 0)
    }

    @Test func anAnswerCanTakeAsLongAsItNeeds() async throws {
        let scratch = ScratchSocket()
        let waiting = Box<SocketConnection>()
        let server = try scratch.server(requestTimeout: 0.1) { _, connection in waiting.put(connection) }
        defer { server.stop() }
        let path = scratch.path
        let answer = Task { try await offThePool { try SocketClient(path: path).send(["op": "hold"], timeout: nil) } }
        await waitUntil { waiting.value != nil }
        // Well past the time a client has to send its line: that clock stops once the request is in.
        try await Task.sleep(for: .milliseconds(300))
        waiting.value?.reply(["ok": true, "decision": "deny"])
        #expect(try await answer.value["decision"] as? String == "deny")
    }

    @Test func theServerHearsWhenAWaitingClientGoes() async throws {
        let scratch = ScratchSocket()
        let waiting = Box<SocketConnection>()
        let gone = Flag()
        let server = try scratch.server { _, connection in
            connection.whenClientGoes { gone.set() }
            waiting.put(connection)
        }
        defer { server.stop() }
        let raw = try rawConnection(to: scratch.path)
        let line = "{\"op\":\"hold\"}\n"
        #expect(write(raw, line, line.utf8.count) == line.utf8.count)
        await waitUntil { waiting.value != nil }
        #expect(!gone.isSet)
        close(raw)
        await waitUntil { gone.isSet }
        #expect(gone.isSet)
    }

    @Test func aClientAlreadyGoneIsNoticedWhenAsked() async throws {
        let scratch = ScratchSocket()
        let waiting = Box<SocketConnection>()
        let server = try scratch.server { _, connection in waiting.put(connection) }
        defer { server.stop() }
        let raw = try rawConnection(to: scratch.path)
        let line = "{\"op\":\"hold\"}\n"
        #expect(write(raw, line, line.utf8.count) == line.utf8.count)
        await waitUntil { waiting.value != nil }
        close(raw)
        try await Task.sleep(for: .milliseconds(100))
        let gone = Flag()
        waiting.value?.whenClientGoes { gone.set() }
        await waitUntil { gone.isSet }
        #expect(gone.isSet)
    }

    @Test func anAnsweredClientDoesntCountAsGone() async throws {
        let scratch = ScratchSocket()
        let gone = Flag()
        let server = try scratch.server { _, connection in
            connection.whenClientGoes { gone.set() }
            connection.reply(["ok": true])
        }
        defer { server.stop() }
        _ = try SocketClient(path: scratch.path).send(["op": "hold"])
        try await Task.sleep(for: .milliseconds(100))
        #expect(!gone.isSet)
    }

    @Test func onlyTheFirstAnswerGoesOut() async throws {
        let scratch = ScratchSocket()
        let server = try scratch.server { _, connection in
            connection.reply(["ok": true, "which": "first"])
            connection.reply(["ok": true, "which": "second"])
        }
        defer { server.stop() }
        let answer = try SocketClient(path: scratch.path).send(["op": "hold"])
        #expect(answer["which"] as? String == "first")
    }

    @Test func anAnswerThatCantBeSentSaysSoRatherThanCrash() throws {
        let scratch = ScratchSocket()
        let server = try scratch.server { _, connection in connection.reply(["date": Date()]) }
        defer { server.stop() }
        let answer = try SocketClient(path: scratch.path).send(["op": "hold"])
        #expect(answer["ok"] as? Bool == false)
    }

    @Test func aWaitForAnAnswerCanRunOut() async throws {
        let scratch = ScratchSocket()
        let server = try scratch.server()
        defer { server.stop() }
        #expect(throws: SocketClient.Failure.noAnswer) {
            try SocketClient(path: scratch.path).send(["op": "hold"], timeout: 0.1)
        }
    }
}

@MainActor
struct SocketRouterTests {
    @Test func anUnknownOpIsToldSo() async throws {
        let scratch = ScratchSocket()
        let router = SocketRouter()
        router.start(path: scratch.path)
        defer { router.stop() }
        let path = scratch.path
        let answer = try await offThePool { try SocketClient(path: path).send(["op": "nonsense"]) }
        #expect(answer["ok"] as? Bool == false)
        #expect(answer["error"] as? String == "Dynotch doesn't know \"nonsense\"")
    }

    @Test func aRegisteredOpIsHandledOnTheMainActor() async throws {
        let scratch = ScratchSocket()
        let router = SocketRouter()
        router.handle("hello") { request, connection in
            connection.reply(["ok": true, "name": request.string("name") ?? ""])
        }
        router.start(path: scratch.path)
        defer { router.stop() }
        let path = scratch.path
        let answer = try await offThePool { try SocketClient(path: path).send(["op": "hello", "name": "Dynotch"]) }
        #expect(answer["name"] as? String == "Dynotch")
    }

    @Test func statusGathersEveryPart() async throws {
        let scratch = ScratchSocket()
        let router = SocketRouter()
        router.reportsStatus("first") { ["a": 1] }
        router.reportsStatus("second") { [1, 2] }
        router.start(path: scratch.path)
        defer { router.stop() }
        let path = scratch.path
        let answer = try await offThePool { try SocketClient(path: path).send(["op": "status"]) }
        #expect(answer["ok"] as? Bool == true)
        #expect(answer["version"] != nil)
        #expect((answer["first"] as? [String: Int])?["a"] == 1)
        #expect(answer["second"] as? [Int] == [1, 2])
    }

    /// Whatever arrives over the socket, no op answers a tool call: only a click in the notch does.
    @Test func noOpOnTheSocketCanAnswerAnApproval() {
        let router = SocketRouter()
        #expect(router.ops.isEmpty)
        ScriptActivityStore(post: { _, _ in }).start(on: router)
        AgentDeck(post: { _, _ in }).start(on: router)
        #expect(router.ops == ["hook", "progress"])
    }
}
