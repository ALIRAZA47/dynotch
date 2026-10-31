import Foundation

/// Finds a login code in a notification's text: 4 to 8 digits, or 123 456, in a message that says
/// it's a code. Nothing here is kept: the code lives on the notice, and goes when the notice does.
enum OneTimeCode {
    private static let words = try? NSRegularExpression(
        pattern: #"\b(codes?|otp|passcode|password|verif(y|ication)|one[- ]time|2fa|two[- ]factor|pin|token|log ?in|sign ?in)\b"#,
        options: .caseInsensitive)

    /// Digits standing on their own: not part of a word, a price, a time, a date or an order number.
    private static let digits = try? NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}#$€£:.,/])(\d{3}[ -]\d{3}|\d{4,8})(?![\p{N}]|[:.,/]\d|%)"#)

    /// The code, with any space or dash taken out so it pastes as one.
    static func find(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let words, let digits, words.firstMatch(in: text, range: range) != nil else { return nil }
        for match in digits.matches(in: text, range: range) {
            guard let found = Range(match.range(at: 1), in: text) else { continue }
            let code = text[found].filter(\.isNumber)
            if !isYear(code) { return code }
        }
        return nil
    }

    private static func isYear(_ code: String) -> Bool {
        code.count == 4 && (code.hasPrefix("19") || code.hasPrefix("20"))
    }
}
