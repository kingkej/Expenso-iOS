import Foundation
import CoreData
import SwiftUI

/// Formatters are expensive to construct and mutable. Keep reuse bounded and serialized
/// so background projections and UI formatting can share them safely.
private final class MoneyFormattingCache: @unchecked Sendable {
    static let shared = MoneyFormattingCache()
    private let lock = NSRecursiveLock()
    private let numbers = NSCache<NSString, NumberFormatter>()
    private let dates = NSCache<NSString, DateFormatter>()
    private var observers: [NSObjectProtocol] = []

    private init() {
        numbers.countLimit = 256
        dates.countLimit = 8
        for name in [NSLocale.currentLocaleDidChangeNotification, Notification.Name.NSSystemTimeZoneDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                defer { self.lock.unlock() }
                self.numbers.removeAllObjects()
                self.dates.removeAllObjects()
            })
        }
    }

    func number(_ value: Decimal, currency: String, locale: Locale, compact: Bool) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(locale.identifier)|\(currency)|\(compact)" as NSString
        let formatter: NumberFormatter
        if let cached = numbers.object(forKey: key) { formatter = cached }
        else {
            formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = .decimal
            let digits = compact ? 1 : fractionDigits(currency)
            formatter.minimumFractionDigits = compact ? 0 : digits
            formatter.maximumFractionDigits = digits
            formatter.usesGroupingSeparator = !compact
            numbers.setObject(formatter, forKey: key)
        }
        return formatter.string(from: NSDecimalNumber(decimal: value))
    }

    func fractionDigits(_ currency: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let key = "digits|\(currency)" as NSString
        if let formatter = numbers.object(forKey: key) { return formatter.maximumFractionDigits }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        numbers.setObject(formatter, forKey: key)
        return formatter.maximumFractionDigits
    }

    func day(_ date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        let zone = TimeZone.current
        let key = zone.identifier as NSString
        let formatter: DateFormatter
        if let cached = dates.object(forKey: key) { formatter = cached }
        else {
            formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = zone
            formatter.dateFormat = "yyyy-MM-dd"
            dates.setObject(formatter, forKey: key)
        }
        return formatter.string(from: date)
    }
}

enum AmountDisplaySettings {
    static let compactKey = "compactSummaryAmounts"
}

enum CurrencySettings {
    static let key = "baseCurrencyCode"
    static var base: String { base(in: .standard) }
    static func base(in defaults: UserDefaults) -> String {
        let code = defaults.string(forKey: key) ?? "RUB"
        return codes.contains(code) ? code : "RUB"
    }
    static let codes = Array(Set(Locale.commonISOCurrencyCodes + ["RUB", "BAM"]))
        .filter { !["XAU", "XAG", "XPD", "XPT", "XTS", "XXX"].contains($0) }.sorted()
    // Currency names are deliberately English and immutable for this app session.
    static let names: [String: String] = {
        let locale = Locale(identifier: "en")
        return Dictionary(uniqueKeysWithValues: codes.map { code in
            (code, locale.localizedString(forCurrencyCode: code) ?? code)
        })
    }()
    static func label(_ code: String) -> String {
        "\(code) — \(names[code] ?? code)"
    }
}

extension CurrencyRateSnapshot {
    var displaySource: String { source.hasPrefix("https://") ? "Daily currency API" : source }

    static func cachedDecode(_ data: Data) -> Self? {
        CurrencySnapshotCache.shared.decode(data)
    }
}

private final class CurrencySnapshotCache: @unchecked Sendable {
    private final class Entry {
        let value: CurrencyRateSnapshot
        init(_ value: CurrencyRateSnapshot) { self.value = value }
    }
    static let shared = CurrencySnapshotCache()
    private let cache = NSCache<NSData, Entry>()

    private init() { cache.countLimit = 128 }

    func decode(_ data: Data) -> CurrencyRateSnapshot? {
        let key = data as NSData
        if let entry = cache.object(forKey: key) { return entry.value }
        guard let value = try? JSONDecoder().decode(CurrencyRateSnapshot.self, from: data) else { return nil }
        cache.setObject(Entry(value), forKey: key)
        return value
    }
}

enum MoneyError: LocalizedError {
    case invalidAmount, missingRate, overflow, schemaNotReady, concurrentEdit
    var errorDescription: String? {
        switch self {
        case .invalidAmount: return "Enter a valid, nonnegative amount using a decimal point or comma."
        case .missingRate: return "A locked exchange rate is missing for this currency. Edit the transaction to fetch a daily rate or enter a manual rate."
        case .overflow: return "The converted amount is too large."
        case .schemaNotReady: return "The multi-currency storage upgrade has not been enabled yet."
        case .concurrentEdit: return "This transaction changed in another window. Close and reopen the editor before saving."
        }
    }
}

/// Value-only revision captures changes even when another window has already saved them.
struct TransactionRevision: Equatable {
    let id: NSManagedObjectID
    let createdAt: Date?
    let updatedAt: Date?
    let occurredOn: Date?
    let title: String?
    let note: String?
    let type: String?
    let tag: String?
    let amount: Double
    let image: Data?
    let currency: String?
    let amountText: String?
    let rateData: Data?

    init(_ transaction: ExpenseCD) {
        id = transaction.objectID
        createdAt = transaction.createdAt
        updatedAt = transaction.updatedAt
        occurredOn = transaction.occuredOn
        title = transaction.title
        note = transaction.note
        type = transaction.type
        tag = transaction.tag
        amount = transaction.amount
        image = transaction.imageAttached
        currency = transaction.supportsCurrencyMetadata ? transaction.currencyCode : nil
        amountText = transaction.supportsCurrencyMetadata ? transaction.amountText : nil
        rateData = transaction.supportsCurrencyMetadata ? transaction.rateSnapshotData : nil
    }
}

enum Money {
    static func parse(_ text: String) throws -> Decimal {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard normalized.count <= 40,
              normalized.range(of: "^[0-9]+(?:\\.[0-9]{1,9})?$", options: .regularExpression) != nil,
              let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")),
              !value.isNaN, value >= 0, value <= 1_000_000_000 else { throw MoneyError.invalidAmount }
        return value
    }
    static func string(_ value: Decimal) -> String { NSDecimalNumber(decimal: value).stringValue }
    static func format(_ value: Decimal, currency: String, locale: Locale = .current) -> String {
        "\(exactNumber(value, currency: currency, locale: locale)) \(currency)"
    }
    private static func exactNumber(_ value: Decimal, currency: String, locale: Locale) -> String {
        MoneyFormattingCache.shared.number(value, currency: currency, locale: locale, compact: false) ?? string(value)
    }
    /// Summary-only abbreviation; stored values and exact money arithmetic are unchanged.
    static func display(_ value: Decimal, currency: String, compact: Bool, locale: Locale = .current) -> String {
        guard !value.isNaN else { return "Invalid amount" }
        return "\(displayNumber(value, currency: currency, compact: compact, locale: locale)) \(currency)"
    }
    /// Numeric component for cards with a separate, stable currency caption.
    static func displayNumber(_ value: Decimal, currency: String, compact: Bool, locale: Locale = .current) -> String {
        guard !value.isNaN else { return "Invalid amount" }
        let magnitude = value < 0 ? -value : value
        guard compact, magnitude >= 1_000 else { return exactNumber(value, currency: currency, locale: locale) }
        let suffixes = ["", "K", "M", "B", "T"]
        var scaled = magnitude
        var index = 0
        func divideByThousand(_ amount: Decimal) -> Decimal? {
            var lhs = amount, rhs: Decimal = 1_000, result = Decimal()
            let status = NSDecimalDivide(&result, &lhs, &rhs, .plain)
            return (status == .noError || status == .lossOfPrecision) && !result.isNaN ? result : nil
        }
        while scaled >= 1_000 && index < suffixes.count - 1 {
            guard let next = divideByThousand(scaled) else { return exactNumber(value, currency: currency, locale: locale) }
            scaled = next
            index += 1
        }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 1, .plain)
        // Promote after rounding too: 999.95K should read 1M, not 1,000K.
        if rounded >= 1_000 && index < suffixes.count - 1 {
            guard let next = divideByThousand(rounded) else { return exactNumber(value, currency: currency, locale: locale) }
            rounded = next
            index += 1
        }
        let signed = value < 0 ? -rounded : rounded
        return "\(MoneyFormattingCache.shared.number(signed, currency: currency, locale: locale, compact: true) ?? string(signed))\(suffixes[index])"
    }
    static func fractionDigits(_ currency: String) -> Int {
        MoneyFormattingCache.shared.fractionDigits(currency)
    }
    static func rounded(_ value: Decimal, currency: String) -> Decimal {
        var value = value
        var result = Decimal()
        NSDecimalRound(&result, &value, fractionDigits(currency), .plain)
        return result
    }
    static func add(_ lhs: Decimal, _ rhs: Decimal) throws -> Decimal {
        var lhs = lhs, rhs = rhs, result = Decimal()
        guard NSDecimalAdd(&result, &lhs, &rhs, .plain) == .noError else { throw MoneyError.overflow }
        return result
    }
    static func multiply(_ lhs: Decimal, _ rhs: Decimal) throws -> Decimal {
        var lhs = lhs, rhs = rhs, result = Decimal()
        let status = NSDecimalMultiply(&result, &lhs, &rhs, .plain)
        guard status == .noError || status == .lossOfPrecision, !result.isNaN else { throw MoneyError.overflow }
        return result
    }
    static func total<S: Sequence>(_ transactions: S, base: String, balance: Bool = false) throws -> Decimal where S.Element == ExpenseCD {
        var total: Decimal = 0
        for transaction in transactions where !transaction.isDeleted {
            guard [TRANS_TYPE_INCOME, TRANS_TYPE_EXPENSE].contains(transaction.type ?? "") else { continue }
            let amount = try transaction.amount(in: base)
            total = try add(total, balance && transaction.type == TRANS_TYPE_EXPENSE ? -amount : amount)
        }
        return total
    }
    static func totalLabel<S: Sequence>(_ transactions: S, base: String, balance: Bool = false, compact: Bool = false) -> String where S.Element == ExpenseCD {
        do { return display(try total(transactions, base: base, balance: balance), currency: base, compact: compact) }
        catch { return "Rates needed" }
    }
    static func day(_ date: Date) -> String {
        MoneyFormattingCache.shared.day(date)
    }
}

extension ExpenseCD {
    var supportsCurrencyMetadata: Bool { entity.attributesByName["currencyCode"] != nil }
    /// V1 records have no currency metadata. The owner's existing ledger is RUB.
    var originalCurrency: String { supportsCurrencyMetadata ? currencyCode ?? "RUB" : "RUB" }
    var originalDecimal: Decimal? {
        if supportsCurrencyMetadata, let amountText { return Decimal(string: amountText, locale: Locale(identifier: "en_US_POSIX")) }
        guard amount.isFinite, amount >= 0 else { return nil }
        return Decimal(string: String(amount), locale: Locale(identifier: "en_US_POSIX"))
    }
    var lockedRates: CurrencyRateSnapshot? {
        guard supportsCurrencyMetadata, let rateSnapshotData else { return nil }
        return CurrencyRateSnapshot.cachedDecode(rateSnapshotData)
    }
    var originalAmountLabel: String {
        guard let amount = originalDecimal, !amount.isNaN else { return "Invalid amount" }
        return Money.format(amount, currency: originalCurrency)
    }
    func amount(in base: String) throws -> Decimal {
        guard let amount = originalDecimal, !amount.isNaN, amount >= 0 else { throw MoneyError.invalidAmount }
        if base == originalCurrency { return Money.rounded(amount, currency: base) }
        guard let lockedRates else { throw MoneyError.missingRate }
        return Money.rounded(try Money.multiply(amount, lockedRates.rate(from: originalCurrency, to: base)), currency: base)
    }
    func convertedAmountLabel(in base: String) -> String {
        do { return Money.format(try amount(in: base), currency: base) }
        catch { return "Conversion unavailable" }
    }
}
