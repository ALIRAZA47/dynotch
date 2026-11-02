import AppKit
import SwiftUI

/// Translate and Summarize: what becomes of what `OnDeviceText` answers, and the notices that say how
/// it went. The answer goes on the clipboard, like Copy Text. What's in a clip or a file never goes in
/// a notice, or in the Recent list: only what was typed into the command field shows.
@MainActor
enum TextActions {
    typealias Notify = ImageActions.Notify

    /// The most that's translated at once, and what's left of a very long clip. Past this the start
    /// is what gets done, and the notice says so.
    static let longestTranslation = 20_000
    /// What the on-device model takes in one go. It holds 4,096 tokens on macOS 26, and a token is
    /// about four letters of English. Scripts without spaces take more tokens, and for those there's
    /// a second try with `shortSummary`.
    static let longestSummary = 9_000
    static let shortSummary = 3_000
    /// Below this there's nothing to summarize.
    static let shortestSummary = 300

    private static let key = "text"
    private static let translating = LiveNotice(key: key, symbol: "character.bubble", tint: .white, text: "Translating")
    private static let summarizing = LiveNotice(key: key, symbol: "text.line.3.summary", tint: .white, text: "Summarizing")

    /// Translates and copies. `showsResult` is for what was typed, which may be shown back.
    static func translate(_ request: TranslationRequest, showsResult: Bool, to pasteboard: NSPasteboard = .dynotch,
                          system: OnDeviceText.System = .live, notify: @escaping Notify = ImageActions.show) async {
        let text = String(request.text.prefix(longestTranslation))
        let isPartial = text.count < request.text.count
        let answer = await ImageActions.saying(translating, notify: notify) {
            await system.translate(text, request.source, request.target, request.targetName)
        }
        switch answer {
        case .success(let translation):
            copy(translation, to: pasteboard)
            notify(copied(showsResult ? translation : isPartial ? "The start of it, in \(request.targetName)" : "In \(request.targetName)"), 5)
        case .failure(let failure):
            notify(notice(for: failure, title: "Can't translate"), 6)
        }
    }

    /// Summarizes and copies. A first try can come back too long for the model, as scripts differ in
    /// how much of it they take, so that gets one more try with less.
    static func summarize(_ text: String, to pasteboard: NSPasteboard = .dynotch, system: OnDeviceText.System = .live,
                          notify: @escaping Notify = ImageActions.show) async {
        let first = String(text.prefix(longestSummary))
        var answered = first
        let answer = await ImageActions.saying(summarizing, notify: notify) {
            let answer = await system.summarize(first)
            guard case .failure(.tooLong) = answer, first.count > shortSummary else { return answer }
            answered = String(text.prefix(shortSummary))
            return await system.summarize(answered)
        }
        switch answer {
        case .success(let summary):
            copy(summary, to: pasteboard)
            notify(copied(answered.count < text.count ? "A summary of the start of it" : "The summary"), 4)
        case .failure(let failure):
            notify(notice(for: failure, title: "Can't summarize"), 6)
        }
    }

    static func copied(_ detail: String) -> LiveNotice {
        LiveNotice(key: key, symbol: "doc.on.clipboard.fill", tint: .white, text: "Copied", detail: detail)
    }

    /// What's being translated or summarized never shows here.
    static func notice(for failure: OnDeviceText.Failure, title: String) -> LiveNotice {
        LiveNotice(key: key, symbol: "exclamationmark.triangle.fill", tint: .orange, text: title, detail: failure.message,
                   actions: failure.fix.map { [$0] } ?? [])
    }

    private static func copy(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// Translate on a clip or a text file: a submenu of languages, the Mac's own first. `text` is read
/// when one is picked, as a file might be large, and says so if it can't be.
struct TranslateMenu: View {
    let text: () async -> String?
    var after: () -> Void = {}

    private static var languages: [(name: String, code: String)] {
        let own = TranslationRequest.listed(Locale.current.language)
        return (own.map { [$0] } ?? []) + TranslationRequest.languages.filter { $0.code != own?.code }
    }

    var body: some View {
        Menu("Translate To") {
            ForEach(Self.languages, id: \.code) { language in
                Button(language.name) {
                    after()
                    Task {
                        guard let text = await text() else {
                            ImageActions.show(TextActions.notice(for: .unreadable, title: "Can't translate"), for: 6)
                            return
                        }
                        await TextActions.translate(TranslationRequest(text: text, source: nil, target: language), showsResult: false)
                    }
                }
            }
        }
    }
}
