import Darwin
import Foundation

/// Where the app and the `dynotch` command meet, and what both ends hold to.
package enum SocketLocation {
    /// The longest path `sockaddr_un` holds, leaving room for its terminator.
    package static let longestPath = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
    /// Enough for an approval of a big file edit. Past this, a hook gets no answer and Claude Code asks itself.
    package static let longestRequest = 8 << 20

    /// A folder of its own inside Application Support, since the folder is what keeps others out.
    package static var standard: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Dynotch/run/dynotch.sock").path
    }

    /// Where the command looks. `DYNOTCH_SOCKET` points it somewhere else, which is how tests keep away
    /// from the real one. The app only ever uses `standard`: it clears the way at its path before it
    /// listens, and whoever starts it chooses its environment, so a path from there could be anything.
    package static func forCommand(environment: [String: String]) -> String {
        if let path = environment["DYNOTCH_SOCKET"], !path.isEmpty { return path }
        return standard
    }

    package static func address(for path: String) -> sockaddr_un? {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count <= longestPath else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    /// Whether what's on the other end runs as this user, which is the only way either end talks.
    package static func accepts(peer: uid_t, owner: uid_t = geteuid()) -> Bool { peer == owner }
}
