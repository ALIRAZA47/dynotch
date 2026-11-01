import Foundation

/// An event as typed. A misread title must never become an event, so a line has one shape and anything
/// else is refused with the reason: the name first, then the day and the time side by side, then a
/// time zone and a length if there are any, as in "dentist fri 3pm", "standup mon 9am 30m",
/// "lunch tomorrow 12-1pm" and "call fri 3pm est". The shape is what tells a day from a word in the title:
/// in "SAT prep 3pm" and "sun cream shop 3pm" it isn't one. So a time alone isn't taken to mean today, or
/// "dentist wensday 3pm" would be. `NSDataDetector` isn't used here: it answers almost anything, and
/// differently by the hour it's asked.
enum EventText {
    /// What came of reading the text.
    enum Reading: Equatable {
        case event(NewEvent)
        /// No clock time in it. A day alone isn't enough.
        case noTime
        /// A time and no day that can be read, which is where a misspelled one ends up.
        case noDay
        /// A time that could be morning or afternoon, like "3:30" or "at 5".
        case needsAMOrPM
        /// When it ends, with nothing to say when it starts: "until 5pm".
        case noStart
        /// More than one time or day, and no telling which is meant.
        case severalTimes
        /// A day and a time with words between them: "fri dentist 3pm".
        case dayApart
        /// Words after the time that aren't a zone or a length: "fri 3pm dentist".
        case titleLast
        /// A day that a word beside it changes, as in "black friday", or that the time doesn't fit.
        case unclearDay
        /// Something that might be a time zone, but can't be read as one.
        case unclearZone
        /// A length that wasn't read: "for 3 days".
        case unclearLength
        /// A day the month doesn't have, a weekday the date doesn't fall on, or a time the clocks skip.
        case noSuchDate
        /// A time and nothing else.
        case noTitle
        /// A time that's already gone.
        case past(Date)
    }

    /// An hour, unless a length is typed.
    static let length: TimeInterval = 3600
    /// The longest a range of times can run, in minutes: "3pm-2pm" would be 23 hours.
    private static let longestRange = 16 * 60
    /// And one that goes past midnight: "11pm-1pm" would be 14.
    private static let longestNight = 12 * 60
    /// How long ago a date with no year still means this year's, in days.
    private static let justGone = 30
    private static let wholeDay = 24 * 60
    /// Before this, a time on a night is the small hours of the day after: "fri night 1am".
    private static let endOfNight = 5 * 60

    static func read(_ text: String, now: Date = .now, calendar: Calendar = .current) -> Reading {
        let ends = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;!?)]"))
        let (body, typedLength) = pullLength(from: text.trimmingCharacters(in: ends))
        var line = pieces(of: body)
        let days = line.compactMap(\.day)
        guard let place = line.firstIndex(where: { $0.clock != nil }), let clock = line[place].clock else { return .noTime }
        guard line.filter({ $0.clock != nil }).count == 1, days.count <= 1 else { return .severalTimes }
        // "until 5pm" can have the day between. "end" can't: "year end fri 3pm" is a name.
        guard !untilWords.contains(line[..<place].last { $0.word != nil }?.word?.lowercased() ?? ""),
              place == 0 || !endWords.contains(line[place - 1].word?.lowercased() ?? "") else { return .noStart }

        let part = days.first?.part
        let from: Int, to: Int?
        switch clock {
        case .invalid:
            return .noTime
        case .exact(let start, let end):
            (from, to) = (start, end)
        case .bareRange(let start, let end):
            // "work fri 9-5pm". After a name, as in "table 4 - 8pm sat", the 4 could belong to it.
            guard let dayPlace = line.firstIndex(where: { $0.day != nil }), dayPlace < place else { return .needsAMOrPM }
            (from, to) = (start, end)
        case .unsure(let minutes):
            guard let minutes, let settled = part.flatMap({ settled(minutes, by: $0) }) else { return .needsAMOrPM }
            (from, to) = (settled, nil)
        }

        let namesAnotherDay = body.range(of: otherDays, options: [.regularExpression, .caseInsensitive]) != nil
        let local = DayText.gregorian(like: calendar)
        var there = local
        switch pullTail(after: place, from: &line) {
        case .nothing: break
        case .zone(let zone): there.timeZone = zone
        case .unclearZone: return .unclearZone
        case .length: return namesAnotherDay ? .unclearDay : .unclearLength
        case .words: return namesAnotherDay ? .unclearDay : .titleLast
        }

        let dayPlace = line.firstIndex { $0.day != nil }
        if let dayPlace, dayPlace < place, !line[(dayPlace + 1)..<place].allSatisfy(isJoiner) { return .dayApart }
        let words = titleWords(of: line[..<min(place, dayPlace ?? place)])
        let title = title(of: words)
        guard title.contains(where: { $0.isLetter || $0.isNumber }) else { return .noTitle }
        guard title.range(of: leftoverLength, options: [.regularExpression, .caseInsensitive]) == nil else { return .unclearLength }
        guard !endsInAZone(words) else { return .unclearZone }
        guard let day = days.first else { return .noDay }
        // "between 3 and 5pm fri", "3 or 4pm fri", "5 to 7 dec": the title's holding half of it.
        guard !["and", "or", "between", "&"].contains(words.last?.lowercased() ?? ""),
              words.joined(separator: " ").range(of: #"[0-9](?:st|nd|rd|th)?(?:,| to| -| –| —)$"#, options: .regularExpression) == nil else { return .severalTimes }
        let lead = words.last?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,")) ?? ""
        guard !namesAnotherDay, title.range(of: beforeTheDay, options: [.regularExpression, .caseInsensitive]) == nil,
              !isChanged(day, by: lead), !isAnExam(body[day.range], in: body),
              part.map({ $0.minutes.contains(from) || ($0 == .night && from < endOfNight) }) != false else { return .unclearDay }

        var overnight = 0
        if part == .night, from < endOfNight, day.kind != .today || local.component(.hour, from: now) * 60 >= endOfNight { overnight = wholeDay }
        if typedLength == nil, let to {
            let isOvernight = to <= from
            let minutes = isOvernight ? to + wholeDay - from : to - from
            guard minutes > 0, minutes <= (isOvernight ? longestNight : longestRange) else { return .severalTimes }
        }
        let today = local.startOfDay(for: now)
        // A date with no year that's just gone isn't next year's.
        if case .date(nil, _?, _, _) = day.kind, let last = DayText.day(day.kind, now: now, calendar: local, looksBack: true),
           let daysAgo = local.dateComponents([.day], from: last, to: today).day, (1...justGone).contains(daysAgo),
           let start = moment(on: last, at: from, local: local, there: there) {
            return .past(start)
        }
        guard let date = DayText.day(day.kind, now: now, calendar: local),
              let start = moment(on: date, at: from + overnight, local: local, there: there) else { return .noSuchDate }
        guard start >= now else { return .past(start) }
        var end = start.addingTimeInterval(typedLength ?? Self.length)
        if typedLength == nil, let to {
            // On the clock, so a change of the clocks that night doesn't move it.
            guard let finish = moment(on: date, at: to + overnight + (to <= from ? wholeDay : 0), local: local, there: there) else { return .noSuchDate }
            end = finish
        }
        return .event(NewEvent(title: title, start: start, end: end))
    }

    /// That clock time on that day, or nil when the clocks skip it. Midnight is the end of the day.
    private static func moment(on day: Date, at minutes: Int, local: Calendar, there: Calendar) -> Date? {
        guard let day = local.date(byAdding: .day, value: minutes / wholeDay, to: day) else { return nil }
        var parts = local.dateComponents([.year, .month, .day], from: day)
        parts.hour = minutes % wholeDay / 60
        parts.minute = minutes % 60
        guard let date = there.date(from: parts) else { return nil }
        let read = there.dateComponents([.hour, .minute], from: date)
        return read.hour == parts.hour && read.minute == parts.minute ? date : nil
    }

    /// Whichever of morning or evening fits "tonight at 8" or "monday morning at 9", if only one does.
    private static func settled(_ minutes: Int, by part: DayText.Part) -> Int? {
        let fits = [minutes % (12 * 60), minutes % (12 * 60) + 12 * 60].filter(part.minutes.contains)
        return fits.count == 1 ? fits[0] : nil
    }

    // MARK: The line

    /// The line in order: its words, with the day and the time picked out of them.
    private enum Piece {
        case word(String)
        case day(DayText.Found)
        case clock(Clock, typed: String)

        var word: String? { if case .word(let word) = self { word } else { nil } }
        var day: DayText.Found? { if case .day(let day) = self { day } else { nil } }
        var clock: Clock? { if case .clock(let clock, _) = self { clock } else { nil } }
    }

    private static func pieces(of text: String) -> [Piece] {
        var pieces: [Piece] = []
        func addWords(_ part: Substring) {
            pieces += part.split(whereSeparator: \.isWhitespace).map { .word(String($0)) }
        }
        func addClocks(_ part: String) {
            var position = part.startIndex
            for clock in clocks(in: part) {
                addWords(part[position..<clock.range.lowerBound])
                pieces.append(.clock(clock.clock, typed: String(part[clock.range])))
                position = clock.range.upperBound
            }
            addWords(part[position...])
        }
        var position = text.startIndex
        for day in DayText.find(in: text) {
            addClocks(String(text[position..<day.range.lowerBound]))
            pieces.append(.day(day))
            position = day.range.upperBound
        }
        addClocks(String(text[position...]))
        // "high noon fri 8pm": with another time to go by, noon is only a word.
        guard pieces.filter({ $0.clock != nil }).count > 1 else { return pieces }
        return pieces.map { piece in
            if case .clock(_, let typed) = piece, ["noon", "midnight"].contains(typed.lowercased()) { return .word(typed) }
            return piece
        }
    }

    /// What can stand between a day and a time, or lead up to either: "fri at 3pm", "sun, 3pm".
    private static let joiners: Set<String> = ["at", "@", "on", "from", ",", ".", ";", ":", "-", "–", "—"]

    private static func isJoiner(_ piece: Piece) -> Bool {
        piece.word.map { joiners.contains($0.lowercased()) } ?? false
    }

    /// The words ahead of the day and the time, without what only led up to them.
    private static func titleWords(of pieces: ArraySlice<Piece>) -> [String] {
        var pieces = pieces
        while pieces.last.map(isJoiner) == true { pieces.removeLast() }
        return pieces.compactMap(\.word)
    }

    private static func title(of words: [String]) -> String {
        let edges = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:!?-–—"))
        let title = words.joined(separator: " ").trimmingCharacters(in: edges)
        return title.hasSuffix("(") || title.hasSuffix("[") ? String(title.dropLast()).trimmingCharacters(in: edges) : title
    }

    // MARK: The day

    /// Right before a weekday, these change which one it is, or show it's somebody: "first monday",
    /// "the following friday", "easter monday", "lunch with sun".
    private static let wordsBeforeAWeekday: Set<String> = [
        "every", "each", "first", "second", "third", "fourth", "fifth", "following", "the", "what's", "whats", "with", "w", "w/", "mr", "mrs", "ms", "dr", "prof", "rev",
        "easter", "holy", "whit",
    ]
    /// Holidays, with the weekday they're named for. "wear black sat 3pm" is fine.
    private static let holidays = ["black": 6, "good": 6, "cyber": 2, "palm": 1, "ash": 4, "shrove": 3, "maundy": 5, "holiday": 2, "giving": 3, "business": 7]

    /// Anywhere in the line, these move the day it names: "dentist fri 3pm next week".
    private static let otherDays = #"\b(?:every|fortnight|from now|next (?:week|month|year)|in (?:a|an|one|two|three|four|five|six|[0-9]+) (?:days?|weeks?|wks?|months?|mos?|years?)|(?:days?|weeks?|wks?|months?) (?:from|after|before|later|ago|on))\b"#
    /// Last in the name, right before the day, these move it or repeat it: "a week fri", "december fri",
    /// "gym weekly mon". On its own, a month that's also a name isn't one: "lunch with june fri".
    private static let beforeTheDay = #"\b(?:(?:a|an|one|two|three|four|five|six|seven|eight|nine|ten|few|couple(?: of)?|next|this|following|[0-9]+) (?:days?|weeks?|wks?|months?|mos?|weekend)|(?:in|late|early|mid|mid-|next|this|end of|start of|beginning of|week of) ?(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sept?(?:ember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)|january|february|march|july|september|october|november|december|(?:after|before|in|during|next|this) (?:the )?(?:new year|christmas|xmas|eid|ramadan|diwali|easter|summer|winter|spring|autumn|fall|term|semester|quarter|[0-9]{4})|(?:days?|weeks?|week's|weeks'|months?) time|end of (?:the )?(?:month|week|year)|christmas (?:day|eve)|new year(?:['’]?s)? (?:day|eve)|boxing day|alternate (?:days|weeks|months)|weekly|fortnightly|biweekly|bimonthly|daily|monthly|quarterly|yearly|annually)$"#

    /// "tutor SAT 3pm": in a line that's otherwise in lowercase, these are more likely something else.
    private static func isAnExam(_ day: Substring, in line: String) -> Bool {
        ["SAT", "SUN", "MON"].contains(String(day.prefix { !$0.isWhitespace })) && line != line.uppercased()
    }

    private static func isChanged(_ day: DayText.Found, by word: String) -> Bool {
        guard !["after", "before"].contains(word) else { return true }
        switch day.kind {
        case .weekday(let weekday, _):
            return wordsBeforeAWeekday.contains(word) || holidays[word] == weekday
                || word.range(of: #"^[0-9]+(?:st|nd|rd|th)$"#, options: .regularExpression) != nil
        case .date:
            return ["next", "last", "this"].contains(word) || word.range(of: #"^(?:19|20|21)[0-9]{2}$"#, options: .regularExpression) != nil
        default:
            return false
        }
    }

    // MARK: Times

    private enum Clock: Equatable {
        /// Minutes from midnight, up to a whole day for midnight itself.
        case exact(start: Int, end: Int?)
        /// A range that starts with a number and nothing else, as "3-4pm" does.
        case bareRange(start: Int, end: Int)
        /// No am or pm, and it could be either. A single time has its minutes here.
        case unsure(Int?)
        /// Not a time, like 13pm.
        case invalid
    }

    /// One end of a time.
    private struct Side {
        var hour = 0
        var minute = 0
        var hasMinutes = false
        /// "15.50" is as likely money, and "4.15" a version, so it takes more to count.
        var isDotted = false
        var hasLeadingZero = false
        var isPM: Bool?
        /// Noon or midnight, in minutes.
        var word: Int?

        /// From the groups of `side`: a word, the hour, what's between it and the minutes, the minutes, and am or pm.
        init?(_ groups: ArraySlice<String?>) {
            let groups = Array(groups)
            if let word = groups[0] {
                self.word = word.hasSuffix("noon") ? 12 * 60 : EventText.wholeDay
            } else if let digits = groups[1], let hour = Int(digits) {
                self.hour = hour
                minute = groups[3].flatMap { Int($0) } ?? 0
                hasMinutes = groups[3] != nil
                isDotted = groups[2] == "."
                hasLeadingZero = digits.hasPrefix("0") && digits.count == 2
                isPM = groups[4].map { $0 == "p" }
            } else {
                return nil
            }
        }

        /// A number alone isn't a time, so "sprint 12" stays in the title.
        var countsAlone: Bool { word != nil || isPM != nil || (hasMinutes && (!isDotted || hasLeadingZero)) }

        var clock: Clock {
            if let word { return .exact(start: word, end: nil) }
            guard minute < 60 else { return .invalid }
            if let isPM {
                guard (1...12).contains(hour) else { return .invalid }
                return .exact(start: (hour % 12 + (isPM ? 12 : 0)) * 60 + minute, end: nil)
            }
            guard hour <= 23, hour > 0 || hasMinutes || hasLeadingZero else { return .invalid }
            let minutes = hour * 60 + minute
            return hour >= 13 || hour == 0 || hasLeadingZero ? .exact(start: minutes, end: nil) : .unsure(minutes)
        }
    }

    private static let side = #"(?:((?:12\s*)?(?:noon|midnight))|([0-9]{1,2})(?:([:.])([0-9]{2}))?(?:\s*([ap])\.?m\b\.?)?)"#
    private static let upTo = #"\s*(?:-|–|—|\bto\b|\buntil\b|\btill\b|\btil\b)\s*"#

    private static func clocks(in text: String) -> [(clock: Clock, range: Range<String.Index>)] {
        let pattern = #"(?<![\w:./$€£¥₹#-])((?:at|@)\s*)?"# + side + #"(?:"# + upTo + side + #")?(?![\w:/-]|\.[0-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let groups = (0..<match.numberOfRanges).map { index in Range(match.range(at: index), in: text).map { String(text[$0]).lowercased() } }
            guard let first = Side(groups[2...6]) else { return nil }
            let second = Side(groups[7...11])
            guard groups[1] != nil || first.countsAlone || second?.countsAlone == true else { return nil }
            return (clock(from: first, to: second), range)
        }
    }

    private static func clock(from first: Side, to second: Side?) -> Clock {
        guard let second else { return first.clock }
        // "03:00-04:00pm", with or without its zeros.
        if let isPM = second.isPM, first.isPM == nil, first.word == nil, (1...12).contains(first.hour), case .exact(let end, _) = second.clock {
            return range(from: first, to: end, isPM: isPM)
        }
        switch (first.clock, second.clock) {
        case (.invalid, _), (_, .invalid):
            return .invalid
        case (.exact(let start, _), .exact(let end, _)):
            return first.word == nil && first.isPM == nil && !first.hasMinutes ? .bareRange(start: start, end: end) : .exact(start: start, end: end)
        case (.unsure(let start?), .exact(let end, _)) where second.word == nil:
            // "9:00-17:00": the end says it's a 24-hour clock.
            return start < end && start >= endOfNight ? .exact(start: start, end: end) : .unsure(nil)
        default:
            return .unsure(nil)
        }
    }

    /// "3-4pm": the end speaks for the start, or "11-1pm" goes across noon. What's left is asked: "9-2am"
    /// could run past midnight from either end, "9-12pm" could be the morning or the evening, and
    /// "3-2pm" and "12-1am" could be several things.
    private static func range(from first: Side, to end: Int, isPM: Bool) -> Clock {
        guard first.hour != 12 || isPM, end != 12 * 60 else { return .unsure(nil) }
        var side = first
        side.isPM = isPM
        var starts: Int?
        if case .exact(let start, _) = side.clock, start < end { starts = start }
        side.isPM = !isPM
        if starts == nil, case .exact(let start, _) = side.clock, start < end, start >= endOfNight { starts = start }
        guard let starts else { return .unsure(nil) }
        return first.hasMinutes ? .exact(start: starts, end: end) : .bareRange(start: starts, end: end)
    }

    /// Ahead of the time, with or without the day between, these make it an end rather than a start.
    private static let untilWords: Set<String> = ["until", "till", "til"]
    /// And so do these, but only right beside the time. "half past 7pm" is another way of saying it.
    private static let endWords: Set<String> = ["end", "ends", "ending", "finish", "finishes", "finishing", "before", "after", "to", "through", "thru", "past", "quarter", "half"]

    // MARK: Lengths

    /// "for 45 min", "for an hour" and "for half an hour" anywhere, or a length with its unit at the
    /// very end. A number alone is too easily something else, a length up front is as likely to be in
    /// the title, as in "2h workshop fri 3pm", and "400m" or "for 5m fri" is more likely a distance or money.
    private static func pullLength(from text: String) -> (text: String, length: TimeInterval?) {
        let short = #"[0-9]{1,2}\s*m"#
        let minutes = #"[0-9]+(?:[.,][0-9]+)?\s*(?:min|mins|minute|minutes)"#
        let hours = #"[0-9]+(?:[.,][0-9]+)?\s*(?:h|hr|hrs|hour|hours)(?:[0-9]{2}|\s*(?:and\s+)?(?:"# + short + "|" + minutes + #"))?"#
        let amount = #"half an hour|an hour and a half|an hour|"# + hours + "|" + minutes
        for pattern in [#"\bfor\s+("# + amount + #")(?![\w:.])"#, #"(?:\s+for)?\s("# + amount + "|" + short + #")\s*$"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let whole = Range(match.range, in: text), let group = Range(match.range(at: 1), in: text),
                  let length = seconds(in: String(text[group])), length >= 60 else { continue }
            var rest = text
            rest.replaceSubrange(whole, with: " ")
            return (rest.trimmingCharacters(in: .whitespaces), length)
        }
        return (text, nil)
    }

    private static func seconds(in amount: String) -> TimeInterval? {
        switch amount.lowercased() {
        case "half an hour": 1800
        case "an hour": 3600
        case "an hour and a half": 5400
        default: TimerText.parse(amount.replacingOccurrences(of: " and ", with: " ").replacingOccurrences(of: ",", with: "."))?.duration
        }
    }

    /// A length that's still in the title: too long, in days, in words, or in the wrong place.
    private static let leftoverLength = #"\bfor\s+(?:[\w.,]+\s+|[0-9.,]+)?(?:h|hrs?|hours?|m|mins?|minutes?|days?|weeks?|months?)\b|\b[0-9]+(?:[.,][0-9]+)?\s*(?:h|hrs?|hours?|mins?|minutes?)$|\b[0-9]{1,2}\s*m$"#
    /// After the time, what's about a length rather than a name.
    private static let lengthAfterTheTime = #"(?:[0-9]\s*|\b(?:half|two|three|four|five|six|seven|eight|nine|ten|twenty|thirty|forty|fifty|sixty|ninety)\s+)(?:h|hrs?|hours?|mins?|minutes?|days?|weeks?|months?)\b"#

    // MARK: Zones

    /// What comes after the time: nothing, or a zone. Anything else is refused.
    private enum Tail: Equatable {
        case nothing
        case zone(TimeZone)
        case unclearZone
        case length
        case words
    }

    /// Initials that mean other things, in capitals too: "gym fri 6pm PT", "pay gst", "class fri 3pm ART".
    private static let wordsNotZones: Set<String> = ["aft", "art", "ast", "bst", "cat", "cot", "ct", "eat", "et", "gst", "ict", "mt", "pet", "pt", "trt", "wat", "west", "wet", "wit"]

    private static func isZone(_ word: String) -> Bool {
        WorldTime.initials(word) != nil && !wordsNotZones.contains(word.lowercased())
    }

    /// Takes a zone from the end of the line, with the day still in its place. Nothing else can come after
    /// the time, which is what keeps "fri 3pm next week" and "fri 3pm with sam pst" from being events.
    private static func pullTail(after clock: Int, from line: inout [Piece]) -> Tail {
        let tail = line.indices.filter { $0 > clock && line[$0].word != nil && !isJoiner(line[$0]) }
        let words = tail.compactMap { line[$0].word }
        guard !words.isEmpty else { return .nothing }
        func take(_ result: Tail) -> Tail {
            for index in tail.reversed() { line.remove(at: index) }
            return result
        }
        if (2...3).contains(words.count), words.last?.lowercased() == "time" {
            let name = words.dropLast().joined(separator: " ")
            if name.lowercased() == "local" { return take(.nothing) }
            if let place = WorldTime.place(name), !place.isInitials || isZone(name) { return take(.zone(place.zone)) }
        } else if words.count == 1 {
            // "(est)" and "e.s.t." are that zone, and "et/pt" and "gmt+5" can't be read as one.
            let typed = words[0].filter { $0 != "." }.trimmingCharacters(in: CharacterSet(charactersIn: "()[],"))
            if isZone(typed), let place = WorldTime.initials(typed) { return take(.zone(place.zone)) }
            let parts = typed.split { !$0.isLetter }.map(String.init)
            if !parts.isEmpty, parts.allSatisfy({ WorldTime.initials($0) != nil }) { return .unclearZone }
        }
        return words.joined(separator: " ").range(of: lengthAfterTheTime, options: [.regularExpression, .caseInsensitive]) == nil ? .words : .length
    }

    /// "call est fri 3pm", "call lahore time fri 3pm": a zone ahead of the time, where it isn't read.
    private static func endsInAZone(_ words: [String]) -> Bool {
        guard let last = words.last?.lowercased() else { return false }
        guard last == "time" else { return isZone(last) }
        return (1...2).contains { count in
            words.count > count && WorldTime.place(words.dropLast().suffix(count).joined(separator: " ")) != nil
        }
    }
}
