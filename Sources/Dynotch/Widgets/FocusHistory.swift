import SwiftUI

/// Finished focus sessions, so a Pomodoro is remembered after its round. One JSON line a session in
/// `focus-history.jsonl`: when it ended and how many minutes it ran, and nothing else. It only ever
/// grows at the end, and only your user can read it.
@MainActor
final class FocusHistory: ObservableObject {
    static let shared = FocusHistory()

    struct Session: Codable, Equatable {
        let end: Date
        let minutes: Int
    }

    /// Today and this week at a glance.
    struct Summary: Equatable {
        var sessionsToday = 0
        var minutesToday = 0
        var sessionsThisWeek = 0
        var minutesThisWeek = 0
        /// Minutes on each day of this week, from the week's first day.
        var days = [Int](repeating: 0, count: 7)
        /// Where today is in `days`.
        var today = 0
    }

    /// What's in the file, as far back as the last two weeks. Earlier lines are left alone there.
    @Published private(set) var sessions: [Session] = []

    /// Sessions whose line couldn't be written yet. They go with the next one.
    private var unwritten: [Session] = []
    /// The file ends part way through a line, as after a crash during a write.
    private var endsMidLine = false
    private let fixedFolder: URL?

    /// A longer session than the settings allow is someone's edit, or a damaged line.
    private static let longest = 24 * 60
    private static let keptInMemory: TimeInterval = 14 * 24 * 3600

    /// `folder` is for the tests. Otherwise it's Dynotch's own, looked up each time, so nothing a
    /// scratch run does reaches the real file, whenever this was first touched.
    init(folder: URL? = nil) {
        fixedFolder = folder
    }

    private var folder: URL { fixedFolder ?? .dynotchSupport }
    private var fileURL: URL { folder.appendingPathComponent("focus-history.jsonl") }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Reads what's there. Anything can edit the file, so a line only counts if it could have been
    /// written here, and the rest are skipped rather than losing the lot.
    func load(now: Date = .now) {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        endsMidLine = data.last != nil && data.last != UInt8(ascii: "\n")
        let earliest = now.addingTimeInterval(-Self.keptInMemory)
        sessions = data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            try? Self.decoder.decode(Session.self, from: Data(line))
        }.filter { (1...Self.longest).contains($0.minutes) && $0.end >= earliest && $0.end <= now.addingTimeInterval(24 * 3600) }
    }

    /// Adds a finished session. It goes in the list whether or not the disk takes it, and it's tried
    /// again with the next one.
    func add(minutes: Int, ended: Date = .now) {
        guard (1...Self.longest).contains(minutes) else { return }
        let session = Session(end: ended, minutes: minutes)
        sessions.append(session)
        unwritten.append(session)
        writeUnwritten()
    }

    func summary(now: Date = .now, calendar: Calendar = .current) -> Summary {
        var summary = Summary()
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return summary }
        let firstDay = calendar.startOfDay(for: week.start)
        summary.today = calendar.dateComponents([.day], from: firstDay, to: calendar.startOfDay(for: now)).day ?? 0
        for session in sessions where week.contains(session.end) {
            summary.sessionsThisWeek += 1
            summary.minutesThisWeek += session.minutes
            let day = calendar.dateComponents([.day], from: firstDay, to: calendar.startOfDay(for: session.end)).day ?? 0
            if summary.days.indices.contains(day) { summary.days[day] += session.minutes }
            if calendar.isDate(session.end, inSameDayAs: now) {
                summary.sessionsToday += 1
                summary.minutesToday += session.minutes
            }
        }
        return summary
    }

    /// One `write` to a file opened for appending, so lines can't land on top of each other. Owner-only
    /// from the first byte.
    private func writeUnwritten() {
        var lines = Data(endsMidLine ? [UInt8(ascii: "\n")] : [])
        for session in unwritten {
            guard let line = try? Self.encoder.encode(session) else { continue }
            lines.append(line)
            lines.append(UInt8(ascii: "\n"))
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor = open(fileURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard descriptor >= 0 else { return }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard (try? handle.write(contentsOf: lines)) != nil else { return }
        unwritten = []
        endsMidLine = false
    }

    // MARK: Snapshots

    /// Minutes on each day of this week, one 25-minute session after another, however far the week has
    /// got. Nothing is saved.
    func loadSample(days: [Int], now: Date = .now, calendar: Calendar = .current) {
        let first = calendar.dateInterval(of: .weekOfYear, for: now).map { calendar.startOfDay(for: $0.start) } ?? now
        sessions = days.enumerated().flatMap { index, minutes -> [Session] in
            guard let day = calendar.date(byAdding: .day, value: index, to: first) else { return [] }
            return stride(from: 0, to: minutes, by: 25).map { Session(end: day.addingTimeInterval(3600 * (9 + Double($0) / 25)), minutes: 25) }
        }
    }
}

/// How the week's going, beside the switch on the Focus tab's second card: today and the week in
/// numbers, and a bar for each day of the week, with today's in the Pomodoro's color. Nothing shows
/// until there's a session this week, but it still takes the room, which pushes what's after it right.
struct FocusStrip: View {
    @ObservedObject private var history = FocusHistory.shared
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let summary = history.summary()
        Group {
            if summary.sessionsThisWeek > 0 {
                // The notes' buttons share the row, and the smallest notch has less of it.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        numbers(summary)
                        bars(summary)
                    }
                    bars(summary)
                }
                .help(Self.spoken(summary))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.spoken(summary))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func numbers(_ summary: FocusHistory.Summary) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 5, verticalSpacing: 0) {
            GridRow {
                Text("Today").foregroundStyle(theme.tertiary)
                Text("\(summary.sessionsToday) · \(Self.time(summary.minutesToday))")
            }
            GridRow {
                Text("Week").foregroundStyle(theme.tertiary)
                Text("\(summary.sessionsThisWeek) · \(Self.time(summary.minutesThisWeek))")
            }
        }
        .font(NotchFont.numeric(10, .medium))
        .foregroundStyle(theme.secondary)
        .lineLimit(1)
        .fixedSize()
    }

    private func bars(_ summary: FocusHistory.Summary) -> some View {
        let highest = max(summary.days.max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(summary.days.indices, id: \.self) { day in
                let isToday = day == summary.today
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(isToday ? PomodoroTimer.Phase.focus.color : theme.primary.opacity(summary.days[day] > 0 ? 0.45 : 0.14))
                    .frame(width: 4, height: max(3, 22 * CGFloat(summary.days[day]) / CGFloat(highest)))
            }
        }
        .frame(height: 22, alignment: .bottom)
    }

    /// "50m", "3h 45m".
    static func time(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes)m" : minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }

    private static func spoken(_ summary: FocusHistory.Summary) -> String {
        func count(_ sessions: Int, _ minutes: Int) -> String {
            "\(sessions) \(sessions == 1 ? "session" : "sessions"), \(TimerText.describe(TimeInterval(minutes * 60)))"
        }
        return "Focus today: \(count(summary.sessionsToday, summary.minutesToday)). "
            + "This week: \(count(summary.sessionsThisWeek, summary.minutesThisWeek))."
    }
}
