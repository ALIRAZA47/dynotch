import AppKit

/// Timed lyrics, read from LRC: "[00:17.12] A line" with a time or several before each line, and
/// empty lines for the gaps between verses.
struct Lyrics: Equatable {
    struct Line: Equatable {
        let time: TimeInterval
        let text: String
    }

    /// In the order they're sung.
    let lines: [Line]
    /// How wide the longest line is on the closed notch's row, so the notch stays one width for the
    /// whole song instead of changing with each line. Worked out once, as the notch asks often.
    let rowWidth: CGFloat

    /// More than any song has, and longer than any line should be. These come from a stranger.
    private static let mostLines = 3000
    private static let longestLine = 300

    /// Nil when nothing in it has a time.
    init?(lrc: String) {
        var lines: [Line] = []
        for row in lrc.split(whereSeparator: \.isNewline) where lines.count < Self.mostLines {
            var rest = Substring(row)
            var times: [TimeInterval] = []
            while times.count + lines.count < Self.mostLines, let (time, after) = Self.stamp(at: rest) {
                times.append(time)
                rest = after
            }
            let text = Self.cleaned(rest)
            lines += times.map { Line(time: $0, text: text) }
        }
        guard lines.contains(where: { !$0.text.isEmpty }) else { return nil }
        self.lines = lines.sorted { $0.time < $1.time }
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        rowWidth = lines.lazy.map { ($0.text as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
    }

    /// Tabs turn into spaces, and control characters and what could turn the line around go. Joiners
    /// stay, as Persian, Urdu and emoji need them.
    private static func cleaned(_ text: Substring) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\t" {
                scalars.append(" ")
            } else if scalar.properties.generalCategory != .control, !(0x202A...0x202E).contains(scalar.value), !(0x2066...0x2069).contains(scalar.value) {
                scalars.append(scalar)
            }
        }
        return String(String(scalars).trimmingCharacters(in: .whitespaces).prefix(longestLine))
    }

    /// The time at the start of `text`, and what's after it. Tags like [ar:M83] aren't times.
    private static func stamp(at text: Substring) -> (TimeInterval, Substring)? {
        guard text.first == "[", let end = text.firstIndex(of: "]") else { return nil }
        let parts = text[text.index(after: text.startIndex)..<end].split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3, let minutes = Int(parts[0]), minutes >= 0 else { return nil }
        // Hundredths usually, and a colon before them in some files.
        let seconds = parts.count == 3 ? Double("\(parts[1]).\(parts[2])") : Double(parts[1])
        guard let seconds, seconds >= 0, seconds < 60 else { return nil }
        return (Double(minutes) * 60 + seconds, text[text.index(after: end)...])
    }

    /// When the line changes from here on, with `elapsed` gone at `now`. A moment after each line's
    /// time, so that line is the one that's found.
    func changes(after elapsed: TimeInterval, from now: Date) -> [Date] {
        lines.filter { $0.time > elapsed }.map { now.addingTimeInterval($0.time - elapsed + 0.05) }
    }

    /// The line being sung at `elapsed`. Nil before the first and in a gap.
    func line(at elapsed: TimeInterval) -> String? {
        var low = 0, high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if lines[middle].time <= elapsed { low = middle + 1 } else { high = middle }
        }
        guard low > 0, !lines[low - 1].text.isEmpty else { return nil }
        return lines[low - 1].text
    }
}
