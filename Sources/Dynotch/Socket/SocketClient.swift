import Darwin
import Foundation

/// The command's end of the socket: one request, one answer. It blocks, since `Dynotch --cli` has
/// nothing else to do, and a process that's stopped takes its connection with it at once, which is
/// how the notch learns a hook was stopped.
struct SocketClient {
    enum Failure: Error, Equatable {
        /// Nothing is listening: Dynotch isn't running.
        case notRunning
        /// Something answers that isn't this user's, which Dynotch never is.
        case wrongOwner
        /// The connection ended with no answer, or none came in time.
        case noAnswer
    }

    let path: String

    /// Sends `request`, and waits `timeout` seconds for the answer, or for as long as it takes when nil.
    func send(_ request: [String: Any], timeout: TimeInterval? = 5) throws -> [String: Any] {
        let descriptor = try connected()
        defer { close(descriptor) }
        guard JSONSerialization.isValidJSONObject(request) else { throw Failure.noAnswer }
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(0x0A)
        guard write(data, to: descriptor) else { throw Failure.noAnswer }
        if let timeout {
            var patience = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &patience, socklen_t(MemoryLayout<timeval>.size))
        }
        return try answer(from: descriptor)
    }

    /// Something is listening. A socket file left behind by a crash refuses the connection.
    var isAnswering: Bool {
        guard let descriptor = try? connected() else { return false }
        close(descriptor)
        return true
    }

    private func connected() throws -> Int32 {
        guard let address = SocketLocation.address(for: path) else { throw Failure.notRunning }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.notRunning }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            close(descriptor)
            throw Failure.notRunning
        }
        var user = uid_t(), group = gid_t()
        guard getpeereid(descriptor, &user, &group) == 0, LocalSocketServer.accepts(peer: user) else {
            close(descriptor)
            throw Failure.wrongOwner
        }
        return descriptor
    }

    private func write(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress! + sent, bytes.count - sent)
                if count > 0 {
                    sent += count
                } else if errno != EINTR {
                    return false
                }
            }
            return true
        }
    }

    private func answer(from descriptor: Int32) throws -> [String: Any] {
        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while received.count < LocalSocketServer.longestRequest {
            let count = read(descriptor, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw Failure.noAnswer }
            received.append(contentsOf: chunk[0..<count])
            if let end = received.firstIndex(of: 0x0A) {
                let line = received[received.startIndex..<end]
                guard let fields = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                    throw Failure.noAnswer
                }
                return fields
            }
        }
        throw Failure.noAnswer
    }
}
