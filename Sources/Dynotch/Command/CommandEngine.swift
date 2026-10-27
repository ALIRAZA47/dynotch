import AppKit
import SwiftUI

/// What running a command leaves behind.
enum CommandOutcome {
    /// It's done: the notch closes.
    case close
    /// It opened a tab: the field goes and the notch stays.
    case stay
    /// It needs more typing: the field gets this text.
    case fill(String)
}

/// A row in the command field.
struct CommandResult: Identifiable {
    let id: String
    let symbol: String
    let tint: Color
    let title: String
    /// What to type for it, on a suggestion; a value, on a result.
    var hint: String?
    /// Nil for a row that only says something, like that nothing matched.
    var action: (@MainActor (NotchViewModel) -> CommandOutcome)?
}

/// Turns what's typed into the command field into things to do: timers, notes, reminders, toggles,
/// profiles, tabs, shortcuts, sums and conversions, and the notes and Tray files that match.
@MainActor
enum CommandEngine {
    static let maximumResults = 6

    static func results(for query: String, in viewModel: NotchViewModel) -> [CommandResult] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return suggestions }
        let lower = text.lowercased()
        var results: [CommandResult] = []

        // A sum or a conversion answers straight away.
        if let answer = Calculator.answer(text) {
            results.append(copyable(id: "sum", symbol: "equal", value: answer, title: "= \(answer)"))
        } else if let conversion = UnitConversion.convert(text) {
            results.append(copyable(id: "convert", symbol: "arrow.left.arrow.right", value: conversion.value,
                                    title: conversion.text))
        }

        // A first word that says what to do.
        var saidWhat = !results.isEmpty
        if let body = remainder(of: text, after: ["note"]) {
            results.append(note(body))
            saidWhat = true
        }
        if let body = remainder(of: text, after: ["remind me to", "remind me", "reminder", "remind"]) {
            results.append(reminder(body))
            saidWhat = true
        }
        if let spec = remainder(of: text, after: ["timer", "start timer"]) {
            results.append(timer(spec.isEmpty ? nil : spec))
            saidWhat = true
        } else if !saidWhat, TimerText.parse(text) != nil {
            results.append(timer(text))
        }
        if let name = remainder(of: text, after: ["run", "shortcut"]) {
            results.append(contentsOf: shortcuts(matching: name.lowercased(), all: true))
            saidWhat = true
        }
        if let name = remainder(of: text, after: ["profile"]) {
            results.append(contentsOf: profiles(matching: name.lowercased()))
            saidWhat = true
        }

        // Then anything whose name starts that way.
        results.append(contentsOf: toggles(matching: lower))
        results.append(contentsOf: tabs(matching: lower))
        if !saidWhat {
            results.append(contentsOf: profiles(matching: lower))
            results.append(contentsOf: shortcuts(matching: lower, all: false))
        }
        if ["settings", "preferences"].contains(where: { $0.hasPrefix(lower) }) {
            results.append(CommandResult(id: "settings", symbol: "gearshape.fill", tint: .gray, title: "Open Settings") { _ in
                SettingsWindowController.shared.show()
                return .close
            })
        }

        // And the notes and files that mention it.
        if text.count >= 2 {
            results.append(contentsOf: notes(matching: lower))
            results.append(contentsOf: files(matching: lower))
        }

        if results.isEmpty {
            results.append(CommandResult(id: "nothing", symbol: "questionmark", tint: .gray,
                                         title: "Nothing for “\(text)”", hint: "tea 4m"))
        }
        return Array(results.prefix(maximumResults))
    }

    // MARK: Suggestions

    /// With nothing typed: one of each kind of command, and what to type for it.
    private static var suggestions: [CommandResult] {
        let toggles = QuickToggles.shared
        return [
            CommandResult(id: "try-timer", symbol: "timer", tint: .orange, title: "Start a timer", hint: "tea 4m") { _ in
                .fill("tea 4m")
            },
            CommandResult(id: "try-note", symbol: "note.text", tint: .yellow, title: "New note", hint: "note Buy coffee") { _ in
                .fill("note ")
            },
            CommandResult(id: "try-remind", symbol: "checklist", tint: .blue, title: "Remind me",
                          hint: "remind Call Sam 5pm") { _ in
                .fill("remind ")
            },
            CommandResult(id: "try-dark", symbol: "moon.fill", tint: .indigo,
                          title: toggles.isDarkMode ? "Turn off Dark Mode" : "Turn on Dark Mode", hint: "dark") { _ in
                toggles.toggleDarkMode()
                return .close
            },
            CommandResult(id: "try-profile", symbol: "person.crop.circle", tint: .green, title: "Switch profile",
                          hint: "profile Work") { _ in
                .fill("profile ")
            },
            CommandResult(id: "try-sum", symbol: "plus.forwardslash.minus", tint: .gray, title: "Calculate or convert",
                          hint: "18% of 240") { _ in
                .fill("18% of 240")
            },
        ]
    }

    // MARK: Commands

    private static func note(_ body: String) -> CommandResult {
        guard !body.isEmpty else {
            return CommandResult(id: "note", symbol: "note.text", tint: .yellow, title: "New note", hint: "type it")
        }
        return CommandResult(id: "note", symbol: "note.text", tint: .yellow, title: "New note: \(body)") { _ in
            let store = NotesStore.shared
            store.newNote()
            if let id = store.currentID { store.update(id, text: body) }
            announce(symbol: "note.text", tint: .yellow, text: "Note added", detail: body)
            return .close
        }
    }

    private static func reminder(_ body: String) -> CommandResult {
        let calendar = CalendarService.shared
        guard calendar.hasReminderAccess else {
            return CommandResult(id: "remind", symbol: "checklist", tint: .blue, title: "Allow Reminders first") { _ in
                calendar.requestReminderAccess()
                return .stay
            }
        }
        guard !body.isEmpty else {
            return CommandResult(id: "remind", symbol: "checklist", tint: .blue, title: "Remind me", hint: "what, and when")
        }
        let (title, due) = ReminderText.parse(body)
        return CommandResult(id: "remind", symbol: "checklist", tint: .blue, title: "Remind me: \(title)",
                             hint: due.map(ReminderText.describe)) { _ in
            if calendar.addReminder(titled: title, due: due) {
                announce(symbol: "checklist", tint: .blue, text: "Reminder added",
                         detail: due.map { "\(title) · \(ReminderText.describe($0))" } ?? title)
            }
            return .close
        }
    }

    private static func timer(_ spec: String?) -> CommandResult {
        guard let spec, let (name, duration) = TimerText.parse(spec) else {
            return CommandResult(id: "timer", symbol: "timer", tint: .orange, title: "Start a timer", hint: "a name and a time")
        }
        let length = Self.length(duration)
        let title = name.isEmpty ? "Start a \(length) timer" : "Start “\(name)” for \(length)"
        return CommandResult(id: "timer", symbol: "timer", tint: .orange, title: title) { _ in
            TimerStore.shared.start(spec)
            return .close
        }
    }

    /// A thing to switch or do at once, and the words that bring it up.
    private struct QuickCommand {
        let id: String
        let words: [String]
        let symbol: String
        let tint: Color
        let title: String
        let run: @MainActor () -> Void
    }

    private static func toggles(matching text: String) -> [CommandResult] {
        let toggles = QuickToggles.shared
        let mic = MicMonitor.shared
        let pomodoro = PomodoroTimer.shared
        let store = TimerStore.shared
        let all = [
            QuickCommand(id: "dark", words: ["dark mode", "dark", "light mode", "light", "appearance"], symbol: "moon.fill", tint: .indigo,
                   title: toggles.isDarkMode ? "Turn off Dark Mode" : "Turn on Dark Mode", run: toggles.toggleDarkMode),
            QuickCommand(id: "awake", words: ["keep awake", "awake", "caffeinate", "stay awake"], symbol: "cup.and.saucer.fill",
                   tint: .orange, title: toggles.isKeepingAwake ? "Let the Mac sleep again" : "Keep the Mac awake",
                   run: toggles.toggleKeepAwake),
            QuickCommand(id: "mic", words: ["mute", "unmute", "mic", "microphone"], symbol: mic.isMuted ? "mic.fill" : "mic.slash.fill",
                   tint: .red, title: mic.isMuted ? "Unmute the microphone" : "Mute the microphone", run: mic.toggleMute),
            QuickCommand(id: "pomodoro", words: ["pomodoro", "focus session", "start focus"], symbol: "timer", tint: .orange,
                   title: pomodoro.isRunning ? "Pause the focus timer" : "Start a focus session", run: pomodoro.toggle),
            QuickCommand(id: "stopwatch", words: ["stopwatch"], symbol: "stopwatch.fill", tint: .cyan,
                   title: store.stopwatch.isRunning ? "Pause the stopwatch" : "Start the stopwatch", run: store.toggleStopwatch),
            QuickCommand(id: "color", words: ["color", "colour", "pick color", "eyedropper"], symbol: "eyedropper", tint: .teal,
                   title: "Pick a color and copy its hex", run: toggles.pickColor),
            QuickCommand(id: "screenshot", words: ["screenshot", "capture", "screen shot"], symbol: "camera.viewfinder", tint: .gray,
                   title: "Take a screenshot", run: toggles.takeScreenshot),
            QuickCommand(id: "sleep", words: ["sleep display", "sleep", "display off"], symbol: "moon.zzz.fill", tint: .gray,
                   title: "Sleep the display", run: toggles.sleepDisplay),
        ]
        return all.filter { matches(text, $0.words) }.map { toggle in
            CommandResult(id: toggle.id, symbol: toggle.symbol, tint: toggle.tint, title: toggle.title) { _ in
                toggle.run()
                return .close
            }
        }
    }

    private static func tabs(matching text: String) -> [CommandResult] {
        let settings = AppSettings.shared
        let words: [NotchTab: [String]] = [
            .home: ["nook", "home", "player", "music"],
            .tray: ["tray", "files"],
            .focus: ["focus", "timers", "reminders", "notes"],
            .stats: ["control", "toggles", "batteries", "stats", "volume", "brightness"],
        ]
        return settings.enabledTabs.compactMap { tab in
            guard let tabWords = words[tab], let word = tabWords.first(where: { $0.hasPrefix(text) || text == $0 }) else {
                return nil
            }
            return CommandResult(id: "tab-\(tab.rawValue)", symbol: tab.symbol, tint: .white, title: "Open \(tab.title)") { model in
                if word == "notes" { settings.focusShowsNotes = true }
                if word == "reminders" { settings.focusShowsNotes = false }
                model.tab = tab
                return .stay
            }
        }
    }

    private static func profiles(matching text: String) -> [CommandResult] {
        let store = ProfileStore.shared
        return store.profiles
            .filter { text.isEmpty || $0.name.lowercased().hasPrefix(text) }
            .prefix(3)
            .map { profile in
                CommandResult(id: "profile-\(profile.id)", symbol: profile.symbol, tint: profile.tint,
                              title: "Switch to \(profile.name)", hint: profile.id == store.activeID ? "on" : nil) { _ in
                    store.switchTo(named: profile.name)
                    return .close
                }
            }
    }

    /// The user's shortcuts. `all` lists every one while nothing's typed after "run".
    private static func shortcuts(matching text: String, all: Bool) -> [CommandResult] {
        guard all || !text.isEmpty else { return [] }
        let service = ShortcutsService.shared
        return service.all
            .filter { text.isEmpty || $0.lowercased().hasPrefix(text) || (text.count >= 3 && $0.lowercased().contains(text)) }
            .prefix(3)
            .map { name in
                CommandResult(id: "shortcut-\(name)", symbol: "square.stack.3d.up.fill", tint: .pink, title: "Run \(name)",
                              hint: "shortcut") { _ in
                    service.run(name)
                    return .close
                }
            }
    }

    private static func notes(matching text: String) -> [CommandResult] {
        NotesStore.shared.notes
            .filter { !$0.isBlank && $0.text.lowercased().contains(text) }
            .prefix(2)
            .map { note in
                CommandResult(id: "note-\(note.id)", symbol: "note.text", tint: .yellow, title: note.title, hint: "note") { model in
                    NotesStore.shared.select(note.id)
                    AppSettings.shared.focusShowsNotes = true
                    model.tab = .focus
                    return .stay
                }
            }
    }

    private static func files(matching text: String) -> [CommandResult] {
        TrayStore.shared.items
            .filter { $0.url.lastPathComponent.lowercased().contains(text) }
            .prefix(2)
            .map { item in
                CommandResult(id: "file-\(item.id)", symbol: "doc.fill", tint: .teal, title: "Open \(item.url.lastPathComponent)",
                              hint: "Tray") { _ in
                    FileActions.open(item.url)
                    return .close
                }
            }
    }

    // MARK: Helpers

    /// A sum's or a conversion's answer, copied on Return.
    private static func copyable(id: String, symbol: String, value: String, title: String) -> CommandResult {
        CommandResult(id: id, symbol: symbol, tint: .gray, title: title, hint: "copy") { _ in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            announce(symbol: "doc.on.clipboard.fill", tint: .white, text: value, detail: "Copied to the clipboard")
            return .close
        }
    }

    /// What follows one of `words` at the start, or nil when the text doesn't start with one.
    /// The longer words come first, so "remind me" wins over "remind".
    static func remainder(of text: String, after words: [String]) -> String? {
        let lower = text.lowercased()
        for word in words {
            if lower == word { return "" }
            if lower.hasPrefix(word + " ") {
                return String(text.dropFirst(word.count + 1)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Typed so far, it's the start of one of the words, or one of them followed by more.
    private static func matches(_ text: String, _ words: [String]) -> Bool {
        words.contains { $0.hasPrefix(text) || text == $0 }
    }

    /// "4 min", "1 hr, 30 min", "90 sec".
    private static func length(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        formatter.allowedUnits = [.hour, .minute, .second]
        return formatter.string(from: duration) ?? Format.duration(duration)
    }

    private static func announce(symbol: String, tint: Color, text: String, detail: String?) {
        LiveActivityCenter.shared.post(LiveNotice(key: "command", symbol: symbol, tint: tint, text: text, detail: detail), for: 3)
    }
}

/// A reminder as typed: "Call Sam 5pm", "pay rent tomorrow at 9". The date, when there is one,
/// comes out of the title.
enum ReminderText {
    static func parse(_ text: String) -> (title: String, due: Date?) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              var date = match.date, let range = Range(match.range, in: text) else {
            return (text, nil)
        }
        var title = text
        title.removeSubrange(range)
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for word in [" at", " on", " by", " for"] where title.lowercased().hasSuffix(word) {
            title = String(title.dropLast(word.count)).trimmingCharacters(in: .whitespaces)
        }
        // "5pm" typed at six means tomorrow's.
        if date < .now, let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: date) {
            date = tomorrow
        }
        return (title.isEmpty ? text : title, date)
    }

    /// "Today 5:00 PM", "Tomorrow 9:00 AM", "Fri 31 Oct 9:00 AM".
    static func describe(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today \(time)" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow \(time)" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + " " + time
    }
}

/// Arithmetic as typed: + − × ÷ and ^, brackets, percentages, and "15% of 80". Nothing for a bare number.
enum Calculator {
    static func answer(_ text: String) -> String? {
        var expression = text.lowercased()
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        if expression.hasPrefix("=") { expression.removeFirst() }
        // "15% of 80" is 15% times 80.
        if let ofRange = expression.range(of: "% of ") {
            expression.replaceSubrange(ofRange, with: "%*")
        }
        // Only a sum counts: a bare number is left to the timers.
        guard expression.dropFirst().contains(where: { "+-*/^%x".contains($0) }) else { return nil }
        // "4x3" means times; an x anywhere else isn't arithmetic.
        expression = expression.replacingOccurrences(of: "x", with: "*")
        var parser = Parser(Array(expression))
        guard let value = parser.parse(), value.isFinite else { return nil }
        return format(value)
    }

    static func format(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = abs(value) < 1 ? 6 : 4
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private struct Parser {
        let characters: [Character]
        var index = 0

        init(_ characters: [Character]) {
            self.characters = characters
        }

        mutating func parse() -> Double? {
            guard let value = sum() else { return nil }
            skipSpaces()
            return index == characters.count ? value : nil
        }

        private mutating func sum() -> Double? {
            guard var value = product() else { return nil }
            while let next = peek(), next == "+" || next == "-" {
                index += 1
                guard let right = product() else { return nil }
                value = next == "+" ? value + right : value - right
            }
            return value
        }

        private mutating func product() -> Double? {
            guard var value = power() else { return nil }
            while let next = peek(), next == "*" || next == "/" {
                index += 1
                guard let right = power() else { return nil }
                value = next == "*" ? value * right : value / right
            }
            return value
        }

        private mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if peek() == "^" {
                index += 1
                guard let exponent = power() else { return nil }
                return pow(base, exponent)
            }
            return base
        }

        private mutating func unary() -> Double? {
            if peek() == "-" {
                index += 1
                return unary().map { -$0 }
            }
            if peek() == "+" {
                index += 1
                return unary()
            }
            guard var value = primary() else { return nil }
            while peek() == "%" {
                index += 1
                value /= 100
            }
            return value
        }

        private mutating func primary() -> Double? {
            if peek() == "(" {
                index += 1
                guard let value = sum(), peek() == ")" else { return nil }
                index += 1
                return value
            }
            skipSpaces()
            let start = index
            while index < characters.count, characters[index].isNumber || characters[index] == "." {
                index += 1
            }
            return start < index ? Double(String(characters[start..<index])) : nil
        }

        /// The next character that isn't a space.
        private mutating func peek() -> Character? {
            skipSpaces()
            return index < characters.count ? characters[index] : nil
        }

        private mutating func skipSpaces() {
            while index < characters.count, characters[index] == " " { index += 1 }
        }
    }
}

/// "5 km to mi", "70 f in c", "2 cups in ml": length, mass, temperature, volume and speed.
enum UnitConversion {
    static func convert(_ text: String) -> (text: String, value: String)? {
        let pattern = #"^\s*(-?\d+(?:\.\d+)?)\s*([a-z°/]+)\s+(?:to|in|as)\s+([a-z°/]+)\s*$"#
        let lower = text.lowercased()
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
              let numberRange = Range(match.range(at: 1), in: lower),
              let fromRange = Range(match.range(at: 2), in: lower),
              let toRange = Range(match.range(at: 3), in: lower),
              let amount = Double(lower[numberRange]),
              let from = units[String(lower[fromRange])],
              let to = units[String(lower[toRange])],
              from.kind == to.kind else { return nil }
        let base = from.unit.converter.baseUnitValue(fromValue: amount)
        let result = to.unit.converter.value(fromBaseUnitValue: base)
        let value = Calculator.format((result * 100).rounded() / 100)
        return ("\(Calculator.format(amount)) \(from.unit.symbol) = \(value) \(to.unit.symbol)", value)
    }

    private enum Kind { case length, mass, temperature, volume, speed }

    private static let units: [String: (unit: Dimension, kind: Kind)] = {
        var table: [String: (unit: Dimension, kind: Kind)] = [:]
        func add(_ unit: Dimension, _ kind: Kind, _ names: String...) {
            names.forEach { table[$0] = (unit, kind) }
        }
        add(UnitLength.meters, .length, "m", "meter", "meters", "metre", "metres")
        add(UnitLength.kilometers, .length, "km", "kilometer", "kilometers", "kilometre", "kilometres")
        add(UnitLength.centimeters, .length, "cm", "centimeter", "centimeters", "centimetre", "centimetres")
        add(UnitLength.millimeters, .length, "mm")
        add(UnitLength.miles, .length, "mi", "mile", "miles")
        add(UnitLength.feet, .length, "ft", "foot", "feet")
        add(UnitLength.inches, .length, "in", "inch", "inches")
        add(UnitLength.yards, .length, "yd", "yard", "yards")
        add(UnitMass.kilograms, .mass, "kg", "kilo", "kilos", "kilogram", "kilograms")
        add(UnitMass.grams, .mass, "g", "gram", "grams")
        add(UnitMass.milligrams, .mass, "mg")
        add(UnitMass.pounds, .mass, "lb", "lbs", "pound", "pounds")
        add(UnitMass.ounces, .mass, "oz", "ounce", "ounces")
        add(UnitMass.stones, .mass, "st", "stone", "stones")
        add(UnitTemperature.celsius, .temperature, "c", "°c", "celsius")
        add(UnitTemperature.fahrenheit, .temperature, "f", "°f", "fahrenheit")
        add(UnitTemperature.kelvin, .temperature, "k", "kelvin")
        add(UnitVolume.liters, .volume, "l", "liter", "liters", "litre", "litres")
        add(UnitVolume.milliliters, .volume, "ml")
        add(UnitVolume.gallons, .volume, "gal", "gallon", "gallons")
        add(UnitVolume.cups, .volume, "cup", "cups")
        add(UnitVolume.fluidOunces, .volume, "floz")
        add(UnitSpeed.kilometersPerHour, .speed, "kmh", "kph", "km/h")
        add(UnitSpeed.milesPerHour, .speed, "mph")
        add(UnitSpeed.metersPerSecond, .speed, "m/s", "mps")
        add(UnitSpeed.knots, .speed, "kn", "knot", "knots")
        return table
    }()
}
