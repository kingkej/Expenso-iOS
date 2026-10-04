import Foundation
import CoreData
import SwiftUI

enum CurrencySettings {
    static let key = "baseCurrencyCode"
    static var base: String {
        let code = UserDefaults.standard.string(forKey: key) ?? "RUB"
        return codes.contains(code) ? code : "RUB"
    }
    static let codes = Array(Set(Locale.commonISOCurrencyCodes + ["RUB", "BAM"]))
        .filter { !["XAU", "XAG", "XPD", "XPT", "XTS", "XXX"].contains($0) }.sorted()
    static func label(_ code: String) -> String {
        "\(code) — \(Locale(identifier: "en").localizedString(forCurrencyCode: code) ?? code)"
    }
}

extension CurrencyRateSnapshot {
    var displaySource: String { source.hasPrefix("https://") ? "Daily currency API" : source }
}

struct CurrencyPickerView: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    var title = "Currency"

    private var filtered: [String] {
        CurrencySettings.codes.filter { search.isEmpty || CurrencySettings.label($0).localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        NavigationStack {
            List(filtered, id: \.self) { code in
                Button {
                    selection = code
                    dismiss()
                } label: {
                    HStack {
                        Text(CurrencySettings.label(code)).foregroundStyle(.primary)
                        Spacer()
                        if selection == code { Image(systemName: "checkmark") }
                    }
                }
                .accessibilityAddTraits(selection == code ? .isSelected : [])
            }
            .searchable(text: $search, prompt: "Code or currency name")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly) }
            }
        }
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
    static func format(_ value: Decimal, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .decimal
        let digits = fractionDigits(currency)
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        return "\(formatter.string(from: NSDecimalNumber(decimal: value)) ?? string(value)) \(currency)"
    }
    static func fractionDigits(_ currency: String) -> Int {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.maximumFractionDigits
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
    static func totalLabel<S: Sequence>(_ transactions: S, base: String, balance: Bool = false) -> String where S.Element == ExpenseCD {
        do { return format(try total(transactions, base: base, balance: balance), currency: base) }
        catch { return "Rates needed" }
    }
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
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
        return try? JSONDecoder().decode(CurrencyRateSnapshot.self, from: rateSnapshotData)
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
