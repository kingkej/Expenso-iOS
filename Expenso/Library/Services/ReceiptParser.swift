import Foundation

/// Suggestions only: every extracted value must be reviewed before updating a form.
struct ReceiptExtraction: Sendable {
    let merchant: String?
    let amount: Decimal?
    let currency: String?
    let date: Date?
    let rawText: String
    let warnings: [String]
}

enum ReceiptParser {
    /// Shared numeric validation for grounded semantic suggestions, without total-label rules.
    static func parsePrintedAmount(_ text: String) -> Decimal? { parseAmount(text) }

    static func parse(lines: [String]) -> ReceiptExtraction {
        let rawText = lines.joined(separator: "\n")
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var warnings: [String] = []
        var totalCandidates: [Decimal] = []
        var invalidTotal = false

        for (index, line) in trimmed.enumerated() {
            let normalized = normalize(line)
            guard !isExcluded(normalized), let match = firstMatch(totalLabel, in: normalized) else { continue }
            let end = match.range.location + match.range.length
            var tail = (normalized as NSString).substring(from: end)
                .trimmingCharacters(in: CharacterSet(charactersIn: " :=\t"))
            if tail.isEmpty || removingCurrency(tail).isEmpty {
                // Only the immediately following line is eligible; no skipping
                // item labels or walking forward until a convenient number appears.
                if index + 1 < trimmed.count {
                    tail = normalize(trimmed[index + 1])
                }
            }
            guard let amount = parseAmount(removingCurrency(tail)) else {
                invalidTotal = true
                continue
            }
            if !totalCandidates.contains(amount) { totalCandidates.append(amount) }
        }

        var amount: Decimal?
        if invalidTotal {
            amount = nil
            warnings.append("A final-total amount is ambiguous or invalid. Review the receipt manually.")
        } else if totalCandidates.count > 1 {
            amount = nil
            warnings.append("Conflicting final totals were found. No amount was selected.")
        } else {
            amount = totalCandidates.first
            if amount == nil { warnings.append("No unambiguous final total was found. Line items were not summed.") }
        }

        let detected = currencies(in: rawText)
        let currency: String?
        if detected.codes.count > 1 {
            currency = nil
            amount = nil
            warnings.append("Multiple currencies were found. Select the transaction currency manually.")
        } else if detected.hasDollar && detected.codes != ["USD"] {
            currency = nil
            warnings.append("The $ symbol is ambiguous. It does not establish USD.")
        } else {
            currency = detected.codes.first
            if currency == nil { warnings.append("No explicit supported currency was found.") }
        }

        let date = receiptDate(in: rawText, warnings: &warnings)
        return ReceiptExtraction(merchant: merchant(in: trimmed), amount: amount,
                                 currency: currency, date: date, rawText: rawText, warnings: warnings)
    }

    // Labels must lead a line and end at a word boundary. This deliberately
    // avoids guesses from unlabeled amounts, largest prices, or invoice balances.
    private static let totalLabel = "^(?:grand\\s+total|amount\\s+due|total(?:\\s+amount)?(?:\\s+due)?|итого(?:\\s+к\\s+оплате)?|всего(?:\\s+к\\s+оплате)?|к\\s+оплате|ukupno(?:\\s+za\\s+platiti)?|ukupan\\s+iznos|za\\s+(?:platiti|uplatu|naplatu)|iznos\\s+za\\s+uplatu)(?=\\s|:|=|$)"
    private static let excludedLabel = "(?:sub\\s*total|tax|vat|tender|change|cash|card|paid|received|savings|items|quantity|balance|points|rewards|discount|подытог|промежуточ|налог|ндс|налич|карт|сдача|оплачено|товаров|экономия|скидка|бонус|porez|pdv|osnovica|kusur|gotovina|kartica|placeno|popust|bez\\s+pdv)"
    private static let currencyPattern = "(?i)(?<![\\p{L}\\p{N}])(?:RUB|BAM|EUR|USD|KM|руб(?:лей|ля)?\\.?)(?![\\p{L}\\p{N}])|[€₽$]"

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isExcluded(_ line: String) -> Bool {
        firstMatch(excludedLabel, in: line) != nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func removingCurrency(_ value: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: currencyPattern) else { return value }
        return regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func currencies(in text: String) -> (codes: [String], hasDollar: Bool) {
        guard let regex = try? NSRegularExpression(pattern: currencyPattern) else { return ([], false) }
        var codes: [String] = []
        var hasDollar = false
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let token = (text as NSString).substring(with: match.range).uppercased()
            let code: String
            switch token {
            case "$": hasDollar = true; continue
            case "€": code = "EUR"
            case "₽": code = "RUB"
            case "KM": code = "BAM"
            default: code = token.hasPrefix("РУБ") ? "RUB" : token
            }
            if !codes.contains(code) { codes.append(code) }
        }
        return (codes, hasDollar)
    }

    private static func parseAmount(_ text: String) -> Decimal? {
        let value = normalize(text)
        guard !value.isEmpty, value.count <= 40,
              firstMatch("^[0-9][0-9 .,]*$", in: value)?.range.length == (value as NSString).length else { return nil }
        let dotCount = value.filter { $0 == "." }.count
        let commaCount = value.filter { $0 == "," }.count
        var integer = value
        var fraction: String?

        if dotCount > 0 && commaCount > 0 {
            guard let separatorIndex = value.lastIndex(where: { $0 == "." || $0 == "," }) else { return nil }
            fraction = String(value[value.index(after: separatorIndex)...])
            integer = String(value[..<separatorIndex])
            // The decimal separator cannot also be used for integer grouping.
            guard !integer.contains(value[separatorIndex]) else { return nil }
        } else if dotCount + commaCount == 1 {
            guard let separatorIndex = value.firstIndex(where: { $0 == "." || $0 == "," }) else { return nil }
            fraction = String(value[value.index(after: separatorIndex)...])
            integer = String(value[..<separatorIndex])
        }
        if let fraction {
            // A single separator followed by three digits could be either a
            // decimal fraction or thousands separator, so it remains unresolved.
            guard (1...2).contains(fraction.count), fraction.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        }

        let separators = Set(integer.filter { $0 == " " || $0 == "." || $0 == "," })
        guard separators.count <= 1 else { return nil }
        if let grouping = separators.first {
            let groups = integer.split(separator: grouping, omittingEmptySubsequences: false)
            guard let first = groups.first, (1...3).contains(first.count),
                  first.allSatisfy({ $0.isASCII && $0.isNumber }),
                  groups.dropFirst().allSatisfy({ $0.count == 3 && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else { return nil }
            integer = groups.joined()
        }
        guard !integer.isEmpty, integer.count <= 28 else { return nil }
        let canonical = integer + (fraction.map { "." + $0 } ?? "")
        guard let decimal = Decimal(string: canonical, locale: Locale(identifier: "en_US_POSIX")),
              !decimal.isNaN, decimal >= 0 else { return nil }
        return decimal
    }

    private static func receiptDate(in text: String, warnings: inout [String]) -> Date? {
        let pattern = "(?<![0-9])(?:[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{2}\\.[0-9]{2}\\.[0-9]{4})(?![0-9])"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.isLenient = false
        var dates: [Date] = []
        var invalid = false
        if let regex = try? NSRegularExpression(pattern: pattern) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let token = (text as NSString).substring(with: match.range)
                formatter.dateFormat = token.contains("-") ? "yyyy-MM-dd" : "dd.MM.yyyy"
                guard let date = formatter.date(from: token), formatter.string(from: date) == token else {
                    invalid = true
                    continue
                }
                if !dates.contains(date) { dates.append(date) }
            }
        }
        let hasSlashDate = firstMatch("(?<![0-9])[0-9]{1,4}/[0-9]{1,2}/[0-9]{1,4}(?![0-9])", in: text) != nil
        if invalid || dates.count > 1 || hasSlashDate {
            warnings.append("Receipt dates are invalid, conflicting, or ambiguous. Confirm the date manually.")
            return nil
        }
        if dates.isEmpty { warnings.append("No unambiguous receipt date was found.") }
        return dates.first
    }

    private static func merchant(in lines: [String]) -> String? {
        for line in lines.prefix(3) where !line.isEmpty {
            let normalized = normalize(line)
            guard line.count <= 80,
                  line.filter({ $0.isLetter }).count >= 3,
                  firstMatch(totalLabel, in: normalized) == nil,
                  !isExcluded(normalized),
                  firstMatch("(?:receipt|invoice|fiscal|racun|fiskalni|кассовый|чек|date|datum|дата|tel|phone|www|https|[0-9]{4}-[0-9]{2})", in: normalized) == nil,
                  firstMatch("[0-9]+[.,][0-9]{1,2}(?![0-9])", in: normalized) == nil,
                  currencies(in: line).codes.isEmpty, !line.contains("$") else { continue }
            return line
        }
        return nil
    }
}
