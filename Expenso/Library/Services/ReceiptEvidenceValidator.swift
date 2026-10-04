import Foundation

/// Model-generated suggestions, not trusted transaction values or instructions.
struct ReceiptSemanticSuggestion: Sendable {
    let merchant: String?
    let totalPrinted: String?
    let currencyPrinted: String?
    let datePrinted: String?
}

enum ReceiptEvidenceValidator {
    static func validate(_ suggestion: ReceiptSemanticSuggestion, rawText: String) -> ReceiptExtraction {
        var warnings = ["AI receipt suggestions require your review. OCR text is untrusted data, never instructions."]

        let merchant = grounded(suggestion.merchant, field: "Merchant", limit: 120,
                                rawText: rawText, warnings: &warnings)

        var amount: Decimal?
        if let printed = grounded(suggestion.totalPrinted, field: "Total", limit: 40,
                                  rawText: rawText, warnings: &warnings) {
            if isStandaloneNumber(printed, in: rawText), let parsed = ReceiptParser.parsePrintedAmount(printed) {
                amount = parsed
            } else {
                warnings.append("The suggested total is not an unambiguous standalone printed amount.")
            }
        }

        let printedCurrencies = detectedCurrencyCodes(in: rawText)
        if printedCurrencies.count > 1 {
            amount = nil
            warnings.append("Conflicting printed currencies were found. Confirm amount and currency manually.")
        }
        var currency: String?
        if let printed = grounded(suggestion.currencyPrinted, field: "Currency", limit: 16,
                                  rawText: rawText, warnings: &warnings) {
            if printed == "$" {
                warnings.append("The $ symbol is ambiguous; USD was not assumed.")
            } else if let code = currencyCode(printed), isCurrencyToken(printed, in: rawText) {
                if printedCurrencies.count == 1, printedCurrencies.contains(code) {
                    currency = code
                } else if printedCurrencies.isEmpty {
                    warnings.append("The suggested ISO code has no printed monetary or currency-label context.")
                } else if printedCurrencies.count == 1 {
                    warnings.append("The suggested ISO code does not match the currency supported by printed monetary evidence.")
                }
            } else {
                warnings.append("The suggested currency is not an explicit supported printed currency token.")
            }
        }

        var date: Date?
        if let printed = grounded(suggestion.datePrinted, field: "Date", limit: 32,
                                  rawText: rawText, warnings: &warnings) {
            let exactDateToken = matches("^(?:[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{2}\\.[0-9]{2}\\.[0-9]{4})$", in: printed)
            let suggestedDate = exactDateToken ? ReceiptParser.parse(lines: [printed]).date : nil
            let allDates = ReceiptParser.parse(lines: rawText.components(separatedBy: .newlines)).date
            if let suggestedDate, allDates == suggestedDate {
                date = suggestedDate
            } else {
                warnings.append("The suggested date is invalid, ambiguous, or conflicts with other printed dates.")
            }
        }

        return ReceiptExtraction(merchant: merchant, amount: amount, currency: currency,
                                 date: date, rawText: rawText, warnings: warnings)
    }

    private static let fiatCodes = Set(Locale.commonISOCurrencyCodes + ["RUB", "BAM"])

    private static func grounded(_ candidate: String?, field: String, limit: Int,
                                 rawText: String, warnings: inout [String]) -> String? {
        guard let candidate else { return nil }
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= limit, trimmed.utf8.count <= limit * 4,
              rawText.range(of: trimmed, options: .literal) != nil else {
            warnings.append("\(field) suggestion is empty, too long, or not present exactly in the OCR text.")
            return nil
        }
        return trimmed
    }

    private static func literalRanges(_ candidate: String, in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var remainder = text.startIndex..<text.endIndex
        while let range = text.range(of: candidate, options: .literal, range: remainder) {
            ranges.append(range)
            remainder = range.upperBound..<text.endIndex
        }
        return ranges
    }

    private static func isStandaloneNumber(_ candidate: String, in text: String) -> Bool {
        for range in literalRanges(candidate, in: text) {
            let before = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : nil
            let after = range.upperBound < text.endIndex ? text[range.upperBound] : nil
            if before.map(isNumericNeighbor) == true || after.map(isNumericNeighbor) == true { continue }
            // Do not extract the tail or head of a space-grouped number. Ordinary
            // whitespace-separated columns remain possible, but groups of exactly
            // three digits are treated conservatively as part of one amount.
            let leadingText = text[..<range.lowerBound]
            let prefix = String(leadingText.reversed().prefix(while: { !$0.isNewline }).reversed())
            let suffix = String(text[range.upperBound...].prefix(while: { !$0.isNewline }))
            let leadingDigits = candidate.prefix(while: { $0.isNumber }).count
            if before?.isWhitespace == true, before?.isNewline != true, leadingDigits == 3,
               prefix.trimmingCharacters(in: .whitespaces).last?.isNumber == true { continue }
            if after?.isWhitespace == true, after?.isNewline != true {
                let next = suffix.trimmingCharacters(in: .whitespaces).prefix(while: { $0.isNumber })
                if next.count == 3 { continue }
            }
            return true
        }
        return false
    }

    private static func isNumericNeighbor(_ character: Character) -> Bool {
        character.isNumber || character.isLetter || ".,+-/()%".contains(character)
    }

    private static func currencyCode(_ printed: String) -> String? {
        switch printed.uppercased() {
        case "€": return "EUR"
        case "₽": return "RUB"
        case "KM": return "BAM"
        default:
            let code = printed.uppercased()
            return fiatCodes.contains(code) ? code : nil
        }
    }

    private static func isCurrencyToken(_ candidate: String, in text: String) -> Bool {
        if candidate == "€" || candidate == "₽" { return text.contains(candidate) }
        return literalRanges(candidate, in: text).contains { range in
            let before = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : nil
            let after = range.upperBound < text.endIndex ? text[range.upperBound] : nil
            return before.map({ $0.isLetter || $0.isNumber }) != true
                && after.map({ $0.isLetter || $0.isNumber }) != true
        }
    }

    private static func detectedCurrencyCodes(in text: String) -> Set<String> {
        let alternatives = (fiatCodes.union(["KM"])).sorted().joined(separator: "|")
        let pattern = "(?<![\\p{L}\\p{N}])(?:\(alternatives))(?![\\p{L}\\p{N}])|[€₽]"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return Set(regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            let token = (text as NSString).substring(with: match.range)
            guard token == "€" || token == "₽" || hasCurrencyContext(match.range, in: text) else { return nil }
            return currencyCode(token)
        })
    }

    private static func hasCurrencyContext(_ range: NSRange, in text: String) -> Bool {
        let source = text as NSString
        let rowRange = source.lineRange(for: range)
        let before = source.substring(with: NSRange(location: rowRange.location,
                                                    length: range.location - rowRange.location))
        let end = range.location + range.length
        let after = source.substring(with: NSRange(location: end,
                                                   length: rowRange.location + rowRange.length - end))
        if matches("(?:^|\\b)(?:currency|valuta|валюта)\\s*[:=]?\\s*$", in: before) { return true }
        // Codes such as ALL, TRY, TOP and PEN are also ordinary prose words.
        // Count them only beside a syntactically valid printed monetary number,
        // not merely because they occurred somewhere in a receipt header.
        if let regex = try? NSRegularExpression(pattern: "([0-9][0-9 .,\\u00A0\\u202F]*)\\s*$"),
           let match = regex.firstMatch(in: before, range: NSRange(before.startIndex..., in: before)),
           ReceiptParser.parsePrintedAmount((before as NSString).substring(with: match.range(at: 1))) != nil {
            return true
        }
        if let regex = try? NSRegularExpression(pattern: "^[ \\t\\u00A0\\u202F]*([0-9][0-9 .,\\u00A0\\u202F]*)"),
           let match = regex.firstMatch(in: after, range: NSRange(after.startIndex..., in: after)),
           ReceiptParser.parsePrintedAmount((after as NSString).substring(with: match.range(at: 1))) != nil {
            return true
        }
        return false
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
