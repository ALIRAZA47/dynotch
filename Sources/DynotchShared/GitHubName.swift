/// What the command reads from a remote and the app takes from a request, checked the same way.
package enum GitHubName {
    private static let longestRepository = 140

    /// `OWNER/NAME`, in the characters GitHub allows. Stricter than a pattern: neither part can pass
    /// for an option, or for a step up a path in the address `gh` builds from it.
    package static func isRepository(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        return text.utf8.count <= longestRepository && parts.count == 2 && parts.allSatisfy { part in
            !part.isEmpty && !part.hasPrefix("-") && part != "." && part != ".."
                && part.utf8.allSatisfy { isLetterOrDigit($0) || "_.-".utf8.contains($0) }
        }
    }

    private static func isLetterOrDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }
}
