import Darwin
import DynotchShared
import Foundation

/// One request from the `dynotch` command: a line of JSON naming what it wants in `op`.
struct SocketRequest: @unchecked Sendable {
    let op: String
    let fields: [String: Any]

    init?(line: Data) {
        guard let fields = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let op = fields["op"] as? String else { return nil }
        self.op = op
        self.fields = fields
    }

    func string(_ name: String) -> String? { fields[name] as? String }
    func number(_ name: String) -> Double? { (fields[name] as? NSNumber)?.doubleValue }
}

/// The socket behind `dynotch progress`, `dynotch status` and the agent hooks. It's a Unix domain
/// socket, never TCP, in a folder only this user can open, and it also asks the kernel who's on the
/// other end of each connection. Clients send one line of JSON and get one line back. An answer can
/// take as long as it needs: a connection stays open until it's answered or its client goes away.
final class LocalSocketServer: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case pathTooLong
        /// Not a real folder of this user's, so it can't be trusted to keep others out.
        case unsafeFolder
        /// Another Dynotch is already listening here.
        case inUse
        case system(String, Int32)
    }

    typealias Receiver = @Sendable (SocketRequest, SocketConnection) -> Void

    static let mostConnections = 64

    private let path: String
    private let requestTimeout: TimeInterval
    private let receive: Receiver
    private let queue = DispatchQueue(label: "app.dynotch.socket")
    private var listener: DispatchSourceRead?
    private var connections: [ObjectIdentifier: SocketConnection] = [:]

    /// `requestTimeout` is how long a client has to finish its line.
    init(path: String, requestTimeout: TimeInterval = 5, receive: @escaping Receiver) {
        self.path = path
        self.requestTimeout = requestTimeout
        self.receive = receive
    }

    deinit { stop() }

    func start() throws {
        guard let address = SocketLocation.address(for: path) else { throw Failure.pathTooLong }
        try Self.prepareFolder((path as NSString).deletingLastPathComponent)
        // A socket that answers belongs to a running Dynotch. One that doesn't was left by a crash.
        if SocketClient(path: path).isAnswering { throw Failure.inUse }
        unlink(path)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.system("socket", errno) }
        func fail(_ call: String) -> Failure {
            let failure = Failure.system(call, errno)
            close(descriptor)
            unlink(path)
            return failure
        }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0 else { throw fail("fcntl") }
        let bound = withUnsafePointer(to: address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { throw fail("bind") }
        guard chmod(path, 0o600) == 0 else { throw fail("chmod") }
        // Room for a burst: a whole batch of hooks can arrive at once, and a full queue reads as "not running".
        guard listen(descriptor, SOMAXCONN) == 0 else { throw fail("listen") }

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll(on: descriptor) }
        source.setCancelHandler { close(descriptor) }
        queue.sync { listener = source }
        source.resume()
    }

    func stop() {
        queue.sync {
            guard let listener else { return }
            listener.cancel()
            self.listener = nil
            connections.values.forEach { $0.drop() }
            connections.removeAll()
            unlink(path)
        }
    }

    /// Makes the folder if it isn't there, then insists it's this user's alone: a real folder, not a
    /// link, that they own and nobody else can enter.
    static func prepareFolder(_ folder: String) throws {
        let parent = (folder as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        } catch {
            throw Failure.system("mkdir", errno)
        }
        guard mkdir(folder, 0o700) == 0 || errno == EEXIST else { throw Failure.system("mkdir", errno) }
        var info = stat()
        guard lstat(folder, &info) == 0 else { throw Failure.system("lstat", errno) }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else { throw Failure.unsafeFolder }
        guard info.st_mode & 0o077 == 0 || chmod(folder, 0o700) == 0 else { throw Failure.system("chmod", errno) }
    }

    private func acceptAll(on descriptor: Int32) {
        while true {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else {
                if errno == EINTR { continue }
                return
            }
            var user = uid_t(), group = gid_t()
            guard fcntl(client, F_SETFD, FD_CLOEXEC) == 0, getpeereid(client, &user, &group) == 0,
                  SocketLocation.accepts(peer: user), connections.count < Self.mostConnections else {
                close(client)
                continue
            }
            var connection: SocketConnection?
            connection = SocketConnection(descriptor: client, queue: queue, requestTimeout: requestTimeout, receive: receive) { [weak self] finished in
                self?.connections[ObjectIdentifier(finished)] = nil
            }
            if let connection {
                connections[ObjectIdentifier(connection)] = connection
                connection.begin()
            }
        }
    }
}

/// A client of the socket, until it's been answered or has gone away. Answer from anywhere.
final class SocketConnection: @unchecked Sendable {
    private let descriptor: Int32
    private let queue: DispatchQueue
    private let requestTimeout: TimeInterval
    private let receive: LocalSocketServer.Receiver
    private let ended: (SocketConnection) -> Void
    private var source: DispatchSourceRead?
    private var deadline: DispatchSourceTimer?
    private var buffer = Data()
    private var hasRequest = false
    private var isOpen = true
    private var isClientGone = false
    private var whenGone: (@Sendable () -> Void)?

    fileprivate init(descriptor: Int32, queue: DispatchQueue, requestTimeout: TimeInterval,
                     receive: @escaping LocalSocketServer.Receiver, ended: @escaping (SocketConnection) -> Void) {
        self.descriptor = descriptor
        self.queue = queue
        self.requestTimeout = requestTimeout
        self.receive = receive
        self.ended = ended
    }

    /// Sends the one answer and ends the connection. A second answer goes nowhere.
    func reply(_ fields: [String: Any]) {
        let fields = JSONSerialization.isValidJSONObject(fields) ? fields : ["ok": false, "error": "That can't be sent"]
        guard var data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        queue.async { [self] in
            guard isOpen else { return }
            send(data)
            end()
        }
    }

    /// `action` runs if the client goes before it's answered, as a hook does when Claude Code stops it.
    func whenClientGoes(_ action: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            if isClientGone {
                action()
            } else if isOpen {
                whenGone = action
            }
        }
    }

    fileprivate func begin() {
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        // A client that stops reading can't hold up the others for long.
        var patience = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &patience, socklen_t(MemoryLayout<timeval>.size))

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + requestTimeout)
        timer.setEventHandler { [weak self] in self?.drop() }
        timer.resume()
        deadline = timer

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        let descriptor = descriptor
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let count = read(descriptor, &chunk, chunk.count)
        guard count > 0 else {
            if count < 0, errno == EINTR || errno == EAGAIN { return }
            clientWentAway()
            return
        }
        // Once a request is in, only the client leaving matters.
        guard !hasRequest else { return }
        buffer.append(contentsOf: chunk[0..<count])
        if let end = buffer.firstIndex(of: 0x0A) {
            hasRequest = true
            deadline?.cancel()
            deadline = nil
            let line = Data(buffer[buffer.startIndex..<end])
            buffer = Data()
            if let request = SocketRequest(line: line) {
                receive(request, self)
            } else {
                reply(["ok": false, "error": "That isn't a request"])
            }
        } else if buffer.count > SocketLocation.longestRequest {
            drop()
        }
    }

    private func clientWentAway() {
        isClientGone = true
        let action = whenGone
        end()
        action?()
    }

    private func send(_ data: Data) {
        data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = write(descriptor, bytes.baseAddress! + sent, bytes.count - sent)
                if count > 0 {
                    sent += count
                } else if errno != EINTR {
                    return
                }
            }
        }
    }

    /// Ends the connection without a word. The client sees it close.
    fileprivate func drop() {
        end()
    }

    private func end() {
        guard isOpen else { return }
        isOpen = false
        whenGone = nil
        deadline?.cancel()
        deadline = nil
        source?.cancel()
        source = nil
        ended(self)
    }
}
