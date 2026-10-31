import Foundation
import FoundationModels
import NaturalLanguage
import Translation

/// What the Mac can do with text by itself: translating with `TranslationSession` and summarizing
/// with Apple's on-device model. Neither sends anything anywhere, and both need macOS 26. Translation
/// only uses languages that are already installed: asking for a download takes a SwiftUI view, and
/// this runs without one. Answers are plain text, since `@Generable` is a macro the Command Line
/// Tools can't run.
enum OnDeviceText {
    /// Why it couldn't be done, in words for a notice.
    enum Failure: Error, Equatable {
        case needsNewerMacOS
        /// macOS knows these languages but they aren't downloaded: "Spanish to English".
        case notInstalled(String)
        case unsupported(String)
        case alreadyIn(String)
        case unknownLanguage
        case appleIntelligenceOff
        case modelNotReady
        case deviceNotEligible
        case refused
        case unsupportedLanguage
        case failed

        var message: String {
            switch self {
            case .needsNewerMacOS: "This needs macOS 26"
            case .notInstalled(let languages): "Download \(languages) in Translation Languages"
            case .unsupported(let language): "macOS can't translate \(language)"
            case .alreadyIn(let language): "That's already in \(language)"
            case .unknownLanguage: "Couldn't tell what language that is"
            case .appleIntelligenceOff: "Turn on Apple Intelligence first"
            case .modelNotReady: "Apple Intelligence is still getting ready"
            case .deviceNotEligible: "This Mac can't run Apple Intelligence"
            case .refused: "Apple's model wouldn't summarize that"
            case .unsupportedLanguage: "Apple's model doesn't read that language"
            case .failed: "Something went wrong on the Mac"
            }
        }

        /// Where in System Settings to put it right, for those that can be.
        var fix: NoticeAction? {
            let pane = switch self {
            case .notInstalled: "com.apple.Localization-Settings.extension"
            case .appleIntelligenceOff: "com.apple.Siri-Settings.extension"
            default: ""
            }
            return URL(string: "x-apple.systempreferences:" + pane).flatMap { pane.isEmpty ? nil : NoticeAction(title: "Open Settings", kind: .openURL($0)) }
        }
    }

    /// What's asked of the Mac. The tests stand in for it, which also makes it the same on every macOS.
    struct System: Sendable {
        var translate: @Sendable (String, Locale.Language?, Locale.Language, String) async -> Result<String, Failure>
        var summarize: @Sendable (String) async -> Result<String, Failure>

        static let live = System(translate: OnDeviceText.translate, summarize: OnDeviceText.summarize)
    }

    /// This macOS has both.
    static var isAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    /// What language this looks like, when no one said.
    static func language(of text: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage.map { Locale.Language(identifier: $0.rawValue) }
    }

    /// `name` is what to call the target.
    private static func translate(_ text: String, from source: Locale.Language?, to target: Locale.Language,
                                  name: String) async -> Result<String, Failure> {
        guard #available(macOS 26, *) else { return .failure(.needsNewerMacOS) }
        guard let source = source ?? language(of: text) else { return .failure(.unknownLanguage) }
        guard source.languageCode != target.languageCode else { return .failure(.alreadyIn(name)) }
        let availability = LanguageAvailability()
        switch await availability.status(from: source, to: target) {
        case .installed: break
        case .supported: return .failure(.notInstalled("\(TranslationRequest.name(of: source)) to \(name)"))
        case .unsupported:
            let knowsTarget = await availability.supportedLanguages.contains { $0.languageCode == target.languageCode }
            return .failure(.unsupported(knowsTarget ? TranslationRequest.name(of: source) : name))
        @unknown default: return .failure(.failed)
        }
        do {
            return .success(try await TranslationSession(installedSource: source, target: target).translate(text).targetText)
        } catch {
            return .failure(.failed)
        }
    }

    private static func summarize(_ text: String) async -> Result<String, Failure> {
        guard #available(macOS 26, *) else { return .failure(.needsNewerMacOS) }
        switch SystemLanguageModel.default.availability {
        case .available: break
        case .unavailable(.appleIntelligenceNotEnabled): return .failure(.appleIntelligenceOff)
        case .unavailable(.modelNotReady): return .failure(.modelNotReady)
        case .unavailable(.deviceNotEligible): return .failure(.deviceNotEligible)
        case .unavailable: return .failure(.failed)
        }
        let session = LanguageModelSession(instructions: "Summarize the text you're given in two or three short sentences. "
            + "Use the text's own language. Answer with the summary and nothing else.")
        do {
            return .success(try await session.respond(to: text).content)
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal: return .failure(.refused)
            case .unsupportedLanguageOrLocale: return .failure(.unsupportedLanguage)
            default: return .failure(.failed)
            }
        } catch {
            return .failure(.failed)
        }
    }
}

/// A translation as typed: "hola to english", "hello from english to german", or just "bonjour", which
/// goes to the Mac's own language. The last "to" that names a language is the one that counts, so
/// "how to swim to french" keeps its first "to", and "how to swim" keeps both.
struct TranslationRequest: Equatable {
    let text: String
    let source: Locale.Language?
    let target: Locale.Language
    /// The target's name, to say it by.
    let targetName: String

    /// Names people type, and their codes. macOS can't translate all of these yet, and it says so.
    static let languages: [(name: String, code: String)] = [
        ("Arabic", "ar"), ("Chinese", "zh-Hans"), ("Danish", "da"), ("Dutch", "nl"), ("English", "en"), ("Finnish", "fi"), ("French", "fr"),
        ("German", "de"), ("Hebrew", "he"), ("Hindi", "hi"), ("Indonesian", "id"), ("Italian", "it"), ("Japanese", "ja"), ("Korean", "ko"),
        ("Malay", "ms"), ("Norwegian", "nb"), ("Polish", "pl"), ("Portuguese", "pt"), ("Russian", "ru"), ("Spanish", "es"), ("Swedish", "sv"),
        ("Thai", "th"), ("Traditional Chinese", "zh-Hant"), ("Turkish", "tr"), ("Ukrainian", "uk"), ("Urdu", "ur"), ("Vietnamese", "vi"),
    ]

    private static func language(named name: String) -> (name: String, code: String)? {
        languages.first { $0.name.lowercased() == name.lowercased() }
    }

    /// What to call a language, in English like the rest of the app.
    static func name(of language: Locale.Language) -> String {
        languages.first { Locale.Language(identifier: $0.code).languageCode == language.languageCode }?.name
            ?? Locale(identifier: "en").localizedString(forLanguageCode: language.minimalIdentifier) ?? language.minimalIdentifier
    }

    init(_ body: String, system: Locale.Language = Locale.current.language) {
        let words = #"[A-Za-z]+(?: [A-Za-z]+)?"#
        if let groups = body.groups(of: #"(?i)(.+?)\s+from\s+("# + words + #")\s+to\s+("# + words + #")"#), let text = groups[0],
           let source = groups[1].flatMap(Self.language(named:)), let target = groups[2].flatMap(Self.language(named:)) {
            self.init(text: text, source: Locale.Language(identifier: source.code), target: target)
        } else if let groups = body.groups(of: #"(?i)(.+)\s+to\s+("# + words + #")"#), let text = groups[0],
                  let target = groups[1].flatMap(Self.language(named:)) {
            self.init(text: text, source: nil, target: target)
        } else {
            self.init(text: body, source: nil, target: (Self.name(of: system), system.minimalIdentifier))
        }
    }

    init(text: String, source: Locale.Language?, target: (name: String, code: String)) {
        self.text = text
        self.source = source
        self.target = Locale.Language(identifier: target.code)
        targetName = target.name
    }
}
