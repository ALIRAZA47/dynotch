import Carbon
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
    /// Compiled scripts by source. A seek is a new script for each position, so this is kept small.
    private var compiled: [String: NSAppleScript] = [:]

    func run(_ source: String) async -> ScriptResult? {
        await withCheckedContinuation { continuation in
            queue.async {
                var error: NSDictionary?
                let descriptor = self.script(for: source)?.executeAndReturnError(&error)
                continuation.resume(returning: error == nil ? descriptor.map(ScriptResult.init) : nil)
            }
        }
    }

    /// Calls one handler of a script with text for its arguments. The text stays text: none of it
    /// becomes source, so nothing in it can run. `handler` goes in lower case, as AppleScript keeps it.
    func run(_ source: String, handler: String, arguments: [String]) async -> ScriptResult? {
        await withCheckedContinuation { continuation in
            queue.async {
                let call = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
                                                  targetDescriptor: .currentProcess(), returnID: AEReturnID(kAutoGenerateReturnID),
                                                  transactionID: AETransactionID(kAnyTransactionID))
                call.setDescriptor(NSAppleEventDescriptor(string: handler), forKeyword: AEKeyword(keyASSubroutineName))
                let list = NSAppleEventDescriptor.list()
                for (index, argument) in arguments.enumerated() {
                    list.insert(NSAppleEventDescriptor(string: argument), at: index + 1)
                }
                call.setParam(list, forKeyword: AEKeyword(keyDirectObject))
                var error: NSDictionary?
                let descriptor = self.script(for: source)?.executeAppleEvent(call, error: &error)
                continuation.resume(returning: error == nil ? descriptor.map(ScriptResult.init) : nil)
            }
        }
    }

    private func script(for source: String) -> NSAppleScript? {
        let script = compiled[source] ?? NSAppleScript(source: source)
        if compiled[source] == nil, compiled.count >= 32 { compiled.removeAll() }
        compiled[source] = script
        return script
    }
}
