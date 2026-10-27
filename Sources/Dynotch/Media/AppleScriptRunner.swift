import Foundation

/// The result of a script, read off the script thread so it can cross actors.
struct ScriptResult: Sendable {
    struct Item: Sendable {
        let text: String?
        let number: Double
    }

    let text: String?
    let data: Data
    /// The items, when the script returned a list.
    let items: [Item]

    init(_ descriptor: NSAppleEventDescriptor) {
        text = descriptor.stringValue
        data = descriptor.data
        let count = descriptor.numberOfItems
        items = count > 0 ? (1...count).map { index in
            let item = descriptor.atIndex(index)
            return Item(text: item?.stringValue, number: item?.doubleValue ?? 0)
        } : []
    }

    /// Zero-based, unlike AppleScript.
    func string(_ index: Int) -> String? { index < items.count ? items[index].text : nil }
    func number(_ index: Int) -> Double? { index < items.count ? items[index].number : nil }
}

/// Runs AppleScript on one background thread, since NSAppleScript isn't thread-safe
/// and a busy target app can block for seconds.
final class AppleScriptRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.dynotch.applescript", qos: .userInitiated)
    private var compiled: [String: NSAppleScript] = [:]

    func run(_ source: String) async -> ScriptResult? {
        await withCheckedContinuation { continuation in
            queue.async {
                let script = self.compiled[source] ?? NSAppleScript(source: source)
                self.compiled[source] = script
                var error: NSDictionary?
                let descriptor = script?.executeAndReturnError(&error)
                continuation.resume(returning: error == nil ? descriptor.map(ScriptResult.init) : nil)
            }
        }
    }
}
