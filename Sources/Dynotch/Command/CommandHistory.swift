import Foundation

/// What's been run from the command field, so an empty field can offer it first. It holds a command's
/// ID, how much it's been used and when, and never what was typed. It's kept in Dynotch's settings,
/// so a scratch run counts in scratch.
enum CommandHistory {
    /// How much a command has been used. The count halves every `halfLife` it isn't, which weighs how
    /// recent against how frequent in one number.
    struct Use: Codable, Equatable {
        var count: Double
        var last: Date

        func weight(at now: Date) -> Double {
            count * pow(0.5, max(now.timeIntervalSince(last), 0) / CommandHistory.halfLife)
        }
    }

    /// A command used ten times two weeks ago still beats one used once today. Three times doesn't.
    static let halfLife: TimeInterval = 5 * 24 * 3600
    /// How many commands are remembered. The ones that have faded most go first.
    static let limit = 40

    private static let key = "commandHistory"

    static func record(_ id: String, now: Date = .now, in defaults: UserDefaults = .dynotch) {
        var uses = load(from: defaults)
        let count = uses[id]?.weight(at: now) ?? 0
        uses[id] = Use(count: count + 1, last: now)
        let kept = order(uses, at: now).prefix(limit)
        save(uses.filter { kept.contains($0.key) }, to: defaults)
    }

    /// The IDs, most used first, going by how recently too.
    static func ranked(now: Date = .now, in defaults: UserDefaults = .dynotch) -> [String] {
        order(load(from: defaults), at: now)
    }

    static func forget(in defaults: UserDefaults = .dynotch) {
        defaults.removeObject(forKey: key)
    }

    /// The latest use breaks a tie, and then the ID, so the order never shuffles between looks.
    private static func order(_ uses: [String: Use], at now: Date) -> [String] {
        uses.sorted { left, right in
            let (leftWeight, rightWeight) = (left.value.weight(at: now), right.value.weight(at: now))
            if leftWeight != rightWeight { return leftWeight > rightWeight }
            if left.value.last != right.value.last { return left.value.last > right.value.last }
            return left.key < right.key
        }.map(\.key)
    }

    private static func load(from defaults: UserDefaults) -> [String: Use] {
        guard let data = defaults.data(forKey: key), let uses = try? JSONDecoder().decode([String: Use].self, from: data) else { return [:] }
        return uses
    }

    private static func save(_ uses: [String: Use], to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(uses) { defaults.set(data, forKey: key) }
    }
}
