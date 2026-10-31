import Foundation

extension String {
    /// The groups of `pattern`, which has to match all of this. A group that took no part is nil.
    func groups(of pattern: String) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: "^(?:" + pattern + ")$"),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: self).map { String(self[$0]) }
        }
    }
}
