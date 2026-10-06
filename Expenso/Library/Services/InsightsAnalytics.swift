import Foundation

enum InsightsPeriod: String, CaseIterable, Identifiable, Sendable {
    case thisMonth, lastMonth, last7Days, last30Days, thisYear, allTime
    var id: String { rawValue }
    var title: String {
        switch self {
        case .thisMonth: return "This Month"
        case .lastMonth: return "Last Month"
        case .last7Days: return "Last 7 Days"
        case .last30Days: return "Last 30 Days"
        case .thisYear: return "This Year"
        case .allTime: return "All Time"
        }
    }
}

enum InsightsKind: String, CaseIterable, Identifiable, Sendable {
    case expense, income
    var id: String { rawValue }
    var title: String { self == .expense ? "Spending" : "Income" }
}

/// Values are already converted with each transaction's locked rate, rounded per row.
/// A nil amount represents an invalid amount or unavailable conversion, never zero.
struct InsightsTransaction: Equatable, Sendable {
    let id: String
    let title: String
    let type: String
    let category: String
    let date: Date?
    let amount: Decimal?
    var usesEstimatedConversion = false
}

struct InsightsRange: Equatable, Sendable {
    let start: Date
    let endExclusive: Date
    let dayCount: Int

    /// Display the inclusive calendar dates, not the exclusive boundary's next day.
    func formatted(calendar: Calendar, locale: Locale = .current) -> String {
        let lastIncluded = endExclusive.addingTimeInterval(-1)
        if calendar.isDate(start, inSameDayAs: lastIncluded) {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: start)
        }
        let formatter = DateIntervalFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: start, to: lastIncluded)
    }

    func historyFilter(kind: InsightsKind, category: String? = nil,
                       calendar: Calendar = .current) -> TransactionHistoryFilter {
        TransactionHistoryFilter(type: kind.rawValue, category: category, startDay: start,
            endDay: calendar.date(byAdding: .day, value: -1, to: endExclusive))
    }
}

struct InsightsCategoryTotal: Identifiable, Sendable {
    let id: String
    let amount: Decimal
    let count: Int
    let share: Decimal
}

struct InsightsBucket: Identifiable, Sendable {
    let id: Date
    let endExclusive: Date
    let amount: Decimal
    let count: Int

    func range(calendar: Calendar) -> InsightsRange {
        InsightsRange(start: id, endExclusive: endExclusive,
            dayCount: calendar.dateComponents([.day], from: id, to: endExclusive).day ?? 0)
    }
}

struct InsightsReport: Sendable {
    let range: InsightsRange
    let previousRange: InsightsRange?
    let kind: InsightsKind
    let total: Decimal?
    let previousTotal: Decimal?
    let change: Decimal?
    /// Signed percentage points: 25 means a 25% increase, nil when prior total is zero.
    let changePercent: Decimal?
    let count: Int
    let invalidAmountCount: Int
    let previousInvalidAmountCount: Int
    let estimatedConversionCount: Int
    let previousEstimatedConversionCount: Int
    let excludedUnknownTypeCount: Int
    /// Undated rows cannot be placed in any period and are counted across the ledger.
    let excludedUndatedCount: Int
    let categories: [InsightsCategoryTotal]
    let buckets: [InsightsBucket]
    let averagePerDay: Decimal?
    let averageTransaction: Decimal?
    let daysWithoutSpending: Int?
    let largest: InsightsTransaction?

    var peakBucket: InsightsBucket? {
        guard let total, !total.isNaN, total > 0 else { return nil }
        return buckets.filter { !$0.amount.isNaN && $0.amount > 0 }.sorted {
            $0.amount == $1.amount ? $0.id < $1.id : $0.amount > $1.amount
        }.first
    }

    /// Percentage points (25 means 25%), keeping exact money out of Double geometry.
    func sharePercent(for bucket: InsightsBucket) -> Decimal? {
        guard let total, !total.isNaN, total > 0,
              !bucket.amount.isNaN, bucket.amount >= 0 else { return nil }
        return try? Money.multiply(InsightsAnalytics.divide(bucket.amount, by: total), 100)
    }
}

enum InsightsError: LocalizedError {
    case invalidRange
    var errorDescription: String? { "The transaction dates could not be grouped into a supported calendar range." }
}

/// Read-only statistics. All arithmetic stays Decimal; Double is only for chart geometry.
enum InsightsAnalytics {
    static func report(_ records: [InsightsTransaction], period: InsightsPeriod, kind: InsightsKind,
                       now: Date = Date(), calendar: Calendar = .current) throws -> InsightsReport {
        let (range, previous) = try ranges(records, period: period, now: now, calendar: calendar)
        let dated = records.filter { $0.date?.timeIntervalSinceReferenceDate.isFinite == true }
        let current = dated.filter { contains($0.date!, in: range) }
        let matching = current.filter { $0.type == kind.rawValue }
        let prior = previous.map { window in dated.filter { $0.type == kind.rawValue && contains($0.date!, in: window) } } ?? []
        let invalid = matching.filter { !valid($0.amount) }.count
        let priorInvalid = prior.filter { !valid($0.amount) }.count
        let total = invalid == 0 ? try sum(matching) : nil
        let previousTotal = previous != nil && priorInvalid == 0 ? try sum(prior) : nil
        let change: Decimal?
        let percent: Decimal?
        if let total, let previousTotal {
            change = try Money.add(total, -previousTotal)
            percent = previousTotal > 0 ? try Money.multiply(divide(change!, by: previousTotal), 100) : nil
        } else { change = nil; percent = nil }

        var categories: [InsightsCategoryTotal] = []
        var buckets: [InsightsBucket] = []
        var largest: InsightsTransaction?
        var noSpendingDays: Int?
        if let total {
            for (category, rows) in Dictionary(grouping: matching, by: \.category) {
                let amount = try sum(rows)
                categories.append(.init(id: category, amount: amount, count: rows.count,
                    share: total > 0 ? try divide(amount, by: total) : 0))
            }
            categories.sort { $0.amount == $1.amount ? $0.id < $1.id : $0.amount > $1.amount }
            buckets = try trend(matching, range: range, calendar: calendar)
            largest = matching.sorted {
                $0.amount == $1.amount ? $0.id < $1.id : $0.amount! > $1.amount!
            }.first
            if kind == .expense {
                let spendingDays = Set(matching.filter { $0.amount! > 0 }.map { calendar.startOfDay(for: $0.date!) })
                noSpendingDays = range.dayCount - spendingDays.count
            }
        }
        return InsightsReport(range: range, previousRange: previous, kind: kind,
            total: total, previousTotal: previousTotal, change: change, changePercent: percent,
            count: matching.count, invalidAmountCount: invalid, previousInvalidAmountCount: priorInvalid,
            estimatedConversionCount: matching.filter { valid($0.amount) && $0.usesEstimatedConversion }.count,
            previousEstimatedConversionCount: prior.filter { valid($0.amount) && $0.usesEstimatedConversion }.count,
            excludedUnknownTypeCount: current.filter { InsightsKind(rawValue: $0.type) == nil }.count,
            excludedUndatedCount: records.count - dated.count,
            categories: categories, buckets: buckets,
            averagePerDay: try total.map { try divide($0, by: Decimal(range.dayCount)) },
            averageTransaction: try total.flatMap { matching.isEmpty ? nil : try divide($0, by: Decimal(matching.count)) },
            daysWithoutSpending: noSpendingDays, largest: largest)
    }

    private static func valid(_ value: Decimal?) -> Bool {
        guard let value else { return false }
        return !value.isNaN && value >= 0
    }

    private static func sum(_ rows: [InsightsTransaction]) throws -> Decimal {
        try rows.reduce(Decimal.zero) { try Money.add($0, $1.amount!) }
    }

    fileprivate static func divide(_ numerator: Decimal, by denominator: Decimal) throws -> Decimal {
        var lhs = numerator, rhs = denominator, result = Decimal()
        let status = NSDecimalDivide(&result, &lhs, &rhs, .plain)
        guard status == .noError || status == .lossOfPrecision, !result.isNaN else { throw MoneyError.overflow }
        return result
    }

    private static func contains(_ date: Date, in range: InsightsRange) -> Bool {
        date >= range.start && date < range.endExclusive
    }

    private static func range(_ start: Date, _ end: Date, calendar: Calendar) throws -> InsightsRange {
        guard start.timeIntervalSinceReferenceDate.isFinite, end.timeIntervalSinceReferenceDate.isFinite,
              start < end, let days = calendar.dateComponents([.day], from: start, to: end).day,
              days > 0 else { throw InsightsError.invalidRange }
        return InsightsRange(start: start, endExclusive: end, dayCount: days)
    }

    private static func adding(_ value: Int, _ component: Calendar.Component, to date: Date, calendar: Calendar) throws -> Date {
        guard let result = calendar.date(byAdding: component, value: value, to: date) else { throw InsightsError.invalidRange }
        return result
    }

    static func ranges(_ records: [InsightsTransaction], period: InsightsPeriod,
                       now: Date, calendar: Calendar) throws -> (InsightsRange, InsightsRange?) {
        guard now.timeIntervalSinceReferenceDate.isFinite else { throw InsightsError.invalidRange }
        let today = calendar.startOfDay(for: now)
        let tomorrow = try adding(1, .day, to: today, calendar: calendar)
        guard let month = calendar.dateInterval(of: .month, for: today),
              let year = calendar.dateInterval(of: .year, for: today) else { throw InsightsError.invalidRange }
        switch period {
        case .thisMonth:
            let current = try range(month.start, tomorrow, calendar: calendar)
            let previousStart = try adding(-1, .month, to: month.start, calendar: calendar)
            // Calendar-day alignment, clipped for shorter previous months (e.g. March 31 / February).
            let previousEnd = min(month.start, try adding(current.dayCount, .day, to: previousStart, calendar: calendar))
            return (current, try range(previousStart, previousEnd, calendar: calendar))
        case .lastMonth:
            let start = try adding(-1, .month, to: month.start, calendar: calendar)
            let previousStart = try adding(-1, .month, to: start, calendar: calendar)
            return (try range(start, month.start, calendar: calendar), try range(previousStart, start, calendar: calendar))
        case .last7Days, .last30Days:
            let days = period == .last7Days ? 7 : 30
            let start = try adding(-(days - 1), .day, to: today, calendar: calendar)
            let previousStart = try adding(-days, .day, to: start, calendar: calendar)
            return (try range(start, tomorrow, calendar: calendar), try range(previousStart, start, calendar: calendar))
        case .thisYear:
            let previousStart = try adding(-1, .year, to: year.start, calendar: calendar)
            let previousDay = try adding(-1, .year, to: today, calendar: calendar)
            let previousEnd = try adding(1, .day, to: previousDay, calendar: calendar)
            return (try range(year.start, tomorrow, calendar: calendar), try range(previousStart, previousEnd, calendar: calendar))
        case .allTime:
            let first = records.filter { InsightsKind(rawValue: $0.type) != nil }.compactMap(\.date)
                .filter { $0.timeIntervalSinceReferenceDate.isFinite && $0 < tomorrow }.min() ?? today
            return (try range(calendar.startOfDay(for: first), tomorrow, calendar: calendar), nil)
        }
    }

    /// Bounded calendar buckets include quiet days. Long histories use months or grouped years.
    private static func trend(_ records: [InsightsTransaction], range: InsightsRange, calendar: Calendar) throws -> [InsightsBucket] {
        let component: Calendar.Component = range.dayCount <= 62 ? .day : range.dayCount <= 1_826 ? .month : .year
        let span = calendar.dateComponents([component], from: range.start, to: range.endExclusive).value(for: component) ?? 1
        let stride = max(1, Int(ceil(Double(span + 1) / 120)))
        var boundaries: [(Date, Date)] = []
        var cursor = range.start
        while cursor < range.endExclusive {
            guard boundaries.count < 122,
                  let interval = calendar.dateInterval(of: component, for: cursor) else { throw InsightsError.invalidRange }
            let end = min(range.endExclusive, try adding(stride, component, to: interval.start, calendar: calendar))
            guard end > cursor else { throw InsightsError.invalidRange }
            boundaries.append((cursor, end))
            cursor = end
        }
        // Sorted traversal avoids rescanning a large ledger for every chart bucket.
        let sorted = records.sorted { $0.date! < $1.date! }
        var index = 0
        return try boundaries.map { start, end in
            var amount: Decimal = 0
            var count = 0
            while index < sorted.count, sorted[index].date! < end {
                amount = try Money.add(amount, sorted[index].amount!)
                count += 1
                index += 1
            }
            return InsightsBucket(id: start, endExclusive: end, amount: amount, count: count)
        }
    }
}
