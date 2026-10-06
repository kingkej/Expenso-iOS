import Foundation

/// Original ledger values only; converted/base amounts never participate in filtering.
struct TransactionHistoryRecord: Sendable, Equatable {
    var title: String
    var note: String
    var type: String
    var category: String
    var currency: String
    var originalAmount: Decimal?
    var occurredOn: Date?
}

struct TransactionHistoryFilter: Sendable, Equatable {
    var search = ""
    var type: String?
    var category: String?
    var currency: String?
    var minimumAmount: Decimal?
    var maximumAmount: Decimal?
    var startDay: Date?
    var endDay: Date?

    enum ValidationError: LocalizedError {
        case invalidAmount, reversedAmounts, reversedDates
        var errorDescription: String? {
            switch self {
            case .invalidAmount: return "Enter a non-negative original amount using a decimal point or comma, without grouping separators."
            case .reversedAmounts: return "The minimum original amount cannot exceed the maximum."
            case .reversedDates: return "The start day cannot be after the end day."
            }
        }
    }

    static func amountBound(_ text: String) throws -> Decimal? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let normalized = value.replacingOccurrences(of: ",", with: ".")
        guard normalized.count <= 40,
              normalized.range(of: "^[0-9]+(?:\\.[0-9]{1,9})?$", options: .regularExpression) != nil,
              let decimal = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")),
              !decimal.isNaN, decimal >= 0 else { throw ValidationError.invalidAmount }
        return decimal
    }

    func validate(calendar: Calendar = .current) throws {
        for amount in [minimumAmount, maximumAmount].compactMap({ $0 }) {
            guard !amount.isNaN, amount >= 0 else { throw ValidationError.invalidAmount }
        }
        if let minimumAmount, let maximumAmount, minimumAmount > maximumAmount {
            throw ValidationError.reversedAmounts
        }
        if let startDay, let endDay, calendar.startOfDay(for: startDay) > calendar.startOfDay(for: endDay) {
            throw ValidationError.reversedDates
        }
    }

    func matches(_ record: TransactionHistoryRecord, calendar: Calendar = .current) -> Bool {
        guard (try? validate(calendar: calendar)) != nil else { return false }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty && !record.title.localizedCaseInsensitiveContains(query)
            && !record.note.localizedCaseInsensitiveContains(query) { return false }
        if let type, record.type != type { return false }
        if let category, record.category != category { return false }
        if let currency, record.currency != currency { return false }
        if minimumAmount != nil || maximumAmount != nil {
            guard let amount = record.originalAmount, !amount.isNaN, amount >= 0 else { return false }
            if let minimumAmount, amount < minimumAmount { return false }
            if let maximumAmount, amount > maximumAmount { return false }
        }
        if startDay != nil || endDay != nil {
            guard let date = record.occurredOn else { return false }
            if let startDay, date < calendar.startOfDay(for: startDay) { return false }
            if let endDay {
                guard let exclusiveEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDay)),
                      date < exclusiveEnd else { return false }
            }
        }
        return true
    }

    mutating func selectMonth(containing date: Date, calendar: Calendar = .current) {
        guard let interval = calendar.dateInterval(of: .month, for: date),
              let lastDay = calendar.date(byAdding: .day, value: -1, to: interval.end) else { return }
        startDay = interval.start
        endDay = lastDay
    }

    var hasAdvancedFilters: Bool {
        type != nil || category != nil || currency != nil || minimumAmount != nil
            || maximumAmount != nil || startDay != nil || endDay != nil
    }
}
