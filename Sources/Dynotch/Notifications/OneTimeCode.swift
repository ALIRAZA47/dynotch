import Foundation

/// Finds a login code in a notification. A message full of numbers is the hard part, so a code has
/// to stand near a word that says it's one, and the nearest candidate wins. Nothing here is kept:
/// the code lives on the notice, and goes when the notice does.
enum OneTimeCode {
    /// The message first, since a sender is often a number itself: a short code, or a phone number.
    /// The title only counts if it says there's a code, like "Verification code" over a bare number.
    static func find(title: String, subtitle: String, body: String) -> String? {
        let message = [subtitle, body].joined(separator: "\n")
        if let code = find(in: message) { return code }
        let words = words(in: title)
        guard !(words.strong + words.plain + words.login).isEmpty else { return nil }
        return find(in: [title, message].joined(separator: "\n"))
    }

    static func find(in text: String) -> String? {
        guard let digits, let priorWords, let laterWords else { return nil }
        let source = text as NSString
        let whole = NSRange(location: 0, length: source.length)
        let (strong, plain, login) = words(in: text)
        guard !strong.isEmpty || !plain.isEmpty || !login.isEmpty else { return nil }

        var best: (code: String, distance: Int)?
        for match in digits.matches(in: text, range: whole) {
            let range = match.range(at: 1)
            // What's just before and after says what the number is: an order, a card, an amount, a time.
            let before = NSRange(location: max(range.location - 24, 0), length: min(range.location, 24))
            let after = NSRange(location: NSMaxRange(range), length: min(whole.length - NSMaxRange(range), 12))
            guard priorWords.firstMatch(in: text, range: before) == nil,
                  laterWords.firstMatch(in: text, range: after) == nil else { continue }

            let reaches = strong.map { gap(from: $0, to: range, limit: strongReach) } + plain.map { gap(from: $0, to: range, limit: codeReach) }
                + login.map { gap(from: $0, to: range, limit: loginReach, onlyAfter: true) }
            guard let distance = reaches.compactMap({ $0 }).min() else { continue }
            let code = String(source.substring(with: range).compactMap(\.wholeNumberValue).map(String.init).joined())
            // A year is more often just a year, so it has to come right after the word.
            let followsWord = (strong + plain).contains { gap(from: $0, to: range, limit: 8, onlyAfter: true) != nil }
            if isYear(code), !followsWord { continue }
            if distance < best?.distance ?? .max { best = (code, distance) }
        }
        return best?.code
    }

    // MARK: Private

    /// How far from a number each kind of word may be, in characters.
    private static let strongReach = 60
    private static let codeReach = 32
    private static let loginReach = 3

    /// Digits standing on their own, in the groups codes come in. Not part of a word, a price, a time, a
    /// date or a phone number. Any script's digits count, so a code in Arabic numerals is still found.
    private static let digits = try? NSRegularExpression(pattern: #"""
        (?<![\p{Latin}\p{Cyrillic}\p{Nd}\p{Sc}+])(?<!\p{Nd}[- .,:/])\
        (\p{Nd}{3}[ -]\p{Nd}{3}[ -]\p{Nd}{3}|\p{Nd}{2}\ \p{Nd}{2}\ \p{Nd}{2}|\p{Nd}{4}[ -]\p{Nd}{4}|\p{Nd}{3}[ -]\p{Nd}{3}|\p{Nd}{4,8})\
        (?!\p{Nd}|[- .,:/]\p{Nd}|%)
        """#.replacingOccurrences(of: "\\\n", with: ""))

    /// Words that mean a login code by themselves. PIN only in capitals: "pin the doc" is a verb.
    private static let strongWords = try? NSRegularExpression(pattern: #"""
        (?i:\b(otp|passcode|passkey|one[- ]time|2fa|mfa|two[- ]factor|2[- ]step|verif(y|ication)|authenticat(e|ion|or)\
        |confirmation (code|number)|einmalpasswort|tek kullanımlık)\b)|\bPIN\b\
        |验证码|驗證碼|認証コード|確認コード|인증\s?번호|ओटीपी|تصدیقی|التحقق
        """#.replacingOccurrences(of: "\\\n", with: ""))

    /// The word for a code, in the languages it comes in most, with German's and Dutch's compounds.
    private static let codeWords = try? NSRegularExpression(pattern: #"""
        (?i:\b(\p{L}*codes?|c[oó]digos?|codice|\p{L}*kod\p{L}*|\p{L}*код\p{L}*)\b)|コード|کوڈ|رمز|कोड
        """#.replacingOccurrences(of: "\\\n", with: ""))

    /// Only right before the number: "Sign-in: 482913", but not "Log in to claim 2500 points".
    private static let loginWords = try? NSRegularExpression(pattern: #"(?i:\b(sign|log)[- ]?in\b)"#)

    /// Codes of other kinds, and "code" in other senses.
    private static let notCodes = try? NSRegularExpression(pattern: #"""
        (?i:\b(zip|postal|post|area|country|promo|promotion|discount|coupon|voucher|referral|gift|qr|bar|source\
        |status|error|exit|return|dress|morse|tracking|tax|sort|swift)[- ]?codes?\b\
        |\b(x|uni|en|de)codes?\b|\bcode[- ](freeze|review|change|red|of conduct)\b)
        """#.replacingOccurrences(of: "\\\n", with: ""))

    /// A number straight after one of these isn't a code.
    private static let priorWords = try? NSRegularExpression(pattern: #"""
        (?i:\b(order|invoice|ticket|ref|reference|acct|account|card|ending|ending in|room|gate|flight|pr|issue\
        |rs|pkr|inr|usd|eur|gbp|aed|sar|bdt|lkr|npr)[\s:#.]*$)
        """#.replacingOccurrences(of: "\\\n", with: ""))

    /// Nor is one straight before these.
    private static let laterWords = try? NSRegularExpression(pattern: #"""
        (?i:^\s*(pkr|inr|usd|eur|gbp|rs|rupees?|dollars?|points?|min|mins|minutes?|sec|secs|seconds?|hrs?|hours?|days?)\b)
        """#.replacingOccurrences(of: "\\\n", with: ""))

    /// Where a text says it holds a code, leaving out "code" in other senses.
    private static func words(in text: String) -> (strong: [NSRange], plain: [NSRange], login: [NSRange]) {
        let whole = NSRange(location: 0, length: (text as NSString).length)
        let ruledOut = notCodes?.matches(in: text, range: whole).map(\.range) ?? []
        func found(_ words: NSRegularExpression?) -> [NSRange] {
            (words?.matches(in: text, range: whole).map(\.range) ?? [])
                .filter { word in !ruledOut.contains { NSIntersectionRange($0, word).length > 0 } }
        }
        return (found(strongWords), found(codeWords), found(loginWords))
    }

    /// Characters between a word and a number, if the number is within `limit` of it.
    private static func gap(from word: NSRange, to number: NSRange, limit: Int, onlyAfter: Bool = false) -> Int? {
        let distance: Int
        if number.location >= NSMaxRange(word) {
            distance = number.location - NSMaxRange(word)
        } else if word.location >= NSMaxRange(number), !onlyAfter {
            distance = word.location - NSMaxRange(number)
        } else {
            return nil
        }
        return distance <= limit ? distance : nil
    }

    private static func isYear(_ code: String) -> Bool {
        code.count == 4 && (code.hasPrefix("19") || code.hasPrefix("20"))
    }
}
