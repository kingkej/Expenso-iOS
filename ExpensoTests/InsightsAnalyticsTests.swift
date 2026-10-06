import Foundation
import Testing
@testable import Expenso

@Suite("Spending insights — deterministic calendar and Decimal statistics")
struct InsightsAnalyticsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func row(_ id: String, _ amount: Decimal?, _ day: String?,
                     category: String = "food", type: String = "expense") -> InsightsTransaction {
        InsightsTransaction(id: id, title: id, type: type, category: category,
            date: day.map(date), amount: amount)
    }

    @Test("Estimated-rate counts follow valid amount, type and comparison period")
    func estimatedRateCounts() throws {
        func estimated(_ id: String, _ amount: Decimal?, _ day: String?, type: String = "expense") -> InsightsTransaction {
            var transaction = row(id, amount, day, type: type)
            transaction.usesEstimatedConversion = true
            return transaction
        }
        let records = [estimated("current", 100, "2026-10-02T12:00:00Z"),
                       estimated("prior", 50, "2026-09-02T12:00:00Z"),
                       estimated("unknown", 10, "2026-10-02T12:00:00Z", type: "unknown"),
                       estimated("income", 20, "2026-10-02T12:00:00Z", type: "income"),
                       estimated("invalid", nil, "2026-10-02T12:00:00Z"),
                       estimated("undated", 10, nil),
                       row("exact", 5, "2026-10-02T12:00:00Z")]
        let report = try InsightsAnalytics.report(records, period: .thisMonth, kind: .expense,
            now: date("2026-10-04T12:00:00Z"), calendar: calendar)
        #expect(report.estimatedConversionCount == 1)
        #expect(report.previousEstimatedConversionCount == 1)
        #expect(report.total == nil)
        #expect(report.previousTotal == 50)
        #expect(report.excludedUnknownTypeCount == 1)
        let income = try InsightsAnalytics.report(records, period: .thisMonth, kind: .income,
            now: date("2026-10-04T12:00:00Z"), calendar: calendar)
        #expect(income.estimatedConversionCount == 1)
        #expect(income.previousEstimatedConversionCount == 0)
        #expect(income.total == 20)
    }

    @Test("Peak period uses exact Decimal share and earliest positive tie")
    func peakAndShare() throws {
        let records = [row("later", 25, "2026-10-03T12:00:00Z"),
            row("earlier", 25, "2026-10-01T12:00:00Z"),
            row("rest", 20, "2026-10-04T12:00:00Z"), row("remaining", 30, "2026-10-02T12:00:00Z")]
        let report = try InsightsAnalytics.report(records, period: .thisMonth, kind: .expense,
            now: date("2026-10-04T12:00:00Z"), calendar: calendar)
        let peak = try #require(report.peakBucket)
        #expect(peak.id == date("2026-10-02T00:00:00Z"))
        #expect(report.sharePercent(for: peak) == 30)
        let tied = try InsightsAnalytics.report(Array(records.prefix(2)), period: .thisMonth, kind: .expense,
            now: date("2026-10-04T12:00:00Z"), calendar: calendar)
        #expect(tied.peakBucket?.id == date("2026-10-01T00:00:00Z"))
        #expect(tied.peakBucket.flatMap { tied.sharePercent(for: $0) } == 50)
        let quiet = try #require(report.buckets.first { $0.amount == 25 })
        #expect(report.sharePercent(for: quiet) == 25)
        let zero = InsightsBucket(id: peak.id, endExclusive: peak.endExclusive, amount: 0, count: 0)
        #expect(report.sharePercent(for: zero) == 0)
        let invalid = InsightsBucket(id: peak.id, endExclusive: peak.endExclusive, amount: .nan, count: 1)
        #expect(report.sharePercent(for: invalid) == nil)
        let negative = InsightsBucket(id: peak.id, endExclusive: peak.endExclusive, amount: -1, count: 1)
        #expect(report.sharePercent(for: negative) == nil)
    }

    @Test("Zero and unavailable totals cannot produce a peak or percentage", arguments: [Decimal?.some(0), nil])
    func unavailablePeak(_ amount: Decimal?) throws {
        let report = try InsightsAnalytics.report([row("row", amount, "2026-10-01T12:00:00Z")],
            period: .thisMonth, kind: .expense, now: date("2026-10-02T12:00:00Z"), calendar: calendar)
        #expect(report.peakBucket == nil)
        let bucket = InsightsBucket(id: date("2026-10-01T00:00:00Z"),
            endExclusive: date("2026-10-02T00:00:00Z"), amount: 0, count: 0)
        #expect(report.sharePercent(for: bucket) == nil)
    }

    @Test("A daily label is a single date and a longer label excludes the next day")
    func rangeLabels() {
        let locale = Locale(identifier: "en_US_POSIX")
        let start = date("2026-10-01T00:00:00Z")
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let daily = InsightsRange(start: start, endExclusive: date("2026-10-02T00:00:00Z"), dayCount: 1)
        #expect(daily.formatted(calendar: calendar, locale: locale) == formatter.string(from: start))
        let interval = DateIntervalFormatter()
        interval.locale = locale
        interval.calendar = calendar
        interval.timeZone = calendar.timeZone
        interval.dateStyle = .medium
        interval.timeStyle = .none
        let monthly = InsightsRange(start: start, endExclusive: date("2026-11-01T00:00:00Z"), dayCount: 31)
        #expect(monthly.formatted(calendar: calendar, locale: locale) ==
            interval.string(from: start, to: date("2026-10-31T00:00:00Z")))
        #expect(monthly.formatted(calendar: calendar, locale: locale) != daily.formatted(calendar: calendar, locale: locale))
    }

    @Test("Bucket ranges and single-day labels survive short and long DST days", arguments: [
        ("2026-03-08T05:00:00Z", "2026-03-09T04:00:00Z", 23),
        ("2026-11-01T04:00:00Z", "2026-11-02T05:00:00Z", 25)
    ])
    func bucketDaylightSaving(_ startText: String, _ endText: String, hours: Int) throws {
        var local = calendar
        local.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let bucket = InsightsBucket(id: date(startText), endExclusive: date(endText), amount: 10, count: 1)
        let range = bucket.range(calendar: local)
        #expect(range.start == bucket.id && range.endExclusive == bucket.endExclusive)
        #expect(range.dayCount == 1)
        #expect(range.endExclusive.timeIntervalSince(range.start) == Double(hours * 3_600))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = local
        formatter.timeZone = local.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        #expect(range.formatted(calendar: local, locale: Locale(identifier: "en_US_POSIX")) == formatter.string(from: bucket.id))
        #expect(range.historyFilter(kind: .expense, calendar: local).endDay == bucket.id)
    }

    @Test("Exact totals, shares, averages, quiet days and previous period agree")
    func usefulStats() throws {
        let records = [
            row("a", 10.25, "2026-10-01T08:00:00Z"),
            row("b", 19.75, "2026-10-02T10:00:00Z", category: "custom.pet"),
            row("c", 10, "2026-10-02T10:00:00Z"),
            row("prior", 20, "2026-09-03T10:00:00Z"),
            row("income", 900, "2026-10-01T10:00:00Z", type: "income"),
            row("future", 500, "2026-10-05T00:00:00Z")
        ]
        let report = try InsightsAnalytics.report(records, period: .thisMonth, kind: .expense,
            now: date("2026-10-04T12:00:00Z"), calendar: calendar)
        #expect(report.total == 40)
        #expect(report.previousTotal == 20)
        #expect(report.change == 20)
        #expect(report.changePercent == 100)
        #expect(report.count == 3)
        #expect(report.averagePerDay == 10)
        #expect(report.daysWithoutSpending == 2)
        #expect(report.largest?.id == "b")
        #expect(report.categories.map(\.id) == ["food", "custom.pet"])
        #expect(report.categories[0].amount == 20.25)
        #expect(report.categories[0].share == Decimal(string: "0.50625"))
        #expect(report.buckets.map(\.amount) == [10.25, 29.75, 0, 0])
        #expect(report.range.dayCount == 4)
        #expect(report.previousRange?.endExclusive == date("2026-09-05T00:00:00Z"))
    }

    @Test("Month comparison clips shorter months and year comparison handles leap day")
    func calendarComparisons() throws {
        let march = try InsightsAnalytics.report([], period: .thisMonth, kind: .expense,
            now: date("2024-03-31T12:00:00Z"), calendar: calendar)
        #expect(march.range.dayCount == 31)
        #expect(march.previousRange?.dayCount == 29)
        #expect(march.previousRange?.start == date("2024-02-01T00:00:00Z"))
        #expect(march.previousRange?.endExclusive == date("2024-03-01T00:00:00Z"))
        let leap = try InsightsAnalytics.report([], period: .thisYear, kind: .expense,
            now: date("2024-02-29T12:00:00Z"), calendar: calendar)
        #expect(leap.range.dayCount == 60)
        #expect(leap.previousRange?.dayCount == 59)
        #expect(leap.previousRange?.endExclusive == date("2023-03-01T00:00:00Z"))
        let january = try InsightsAnalytics.report([], period: .lastMonth, kind: .expense,
            now: date("2026-01-03T12:00:00Z"), calendar: calendar)
        #expect(january.range.start == date("2025-12-01T00:00:00Z"))
        #expect(january.range.endExclusive == date("2026-01-01T00:00:00Z"))
        #expect(january.previousRange?.start == date("2025-11-01T00:00:00Z"))
    }

    @Test("Calendar-day windows and chart drilldowns remain exact through DST")
    func daylightSaving() throws {
        var local = calendar
        local.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let records = [row("before", 10, "2026-03-08T06:30:00Z"), row("after", 20, "2026-03-08T07:30:00Z")]
        let report = try InsightsAnalytics.report(records, period: .last7Days, kind: .expense,
            now: date("2026-03-08T16:00:00Z"), calendar: local)
        #expect(report.range.dayCount == 7)
        #expect(report.range.endExclusive.timeIntervalSince(report.range.start) == 7 * 86_400 - 3_600)
        #expect(report.buckets.count == 7)
        let last = try #require(report.buckets.last)
        #expect(last.amount == 30)
        let range = InsightsRange(start: last.id, endExclusive: last.endExclusive, dayCount: 1)
        let filter = range.historyFilter(kind: .expense, category: "food", calendar: local)
        for record in records {
            #expect(filter.matches(.init(title: record.title, note: "", type: record.type,
                category: record.category, currency: "RUB", originalAmount: record.amount,
                occurredOn: record.date), calendar: local))
        }
        #expect(!filter.matches(.init(title: "next day", note: "", type: "expense", category: "food",
            currency: "RUB", originalAmount: 1, occurredOn: last.endExclusive), calendar: local))
    }

    @Test("Incomplete conversions disable affected statistics, never silently produce partial charts")
    func incompleteAmounts() throws {
        let records = [row("ok", 10, "2026-10-01T12:00:00Z"), row("missing", nil, "2026-10-02T12:00:00Z"),
            row("income", 25, "2026-10-01T12:00:00Z", type: "income")]
        let report = try InsightsAnalytics.report(records, period: .thisMonth, kind: .expense,
            now: date("2026-10-04T12:00:00Z"), calendar: calendar)
        #expect(report.total == nil)
        #expect(report.invalidAmountCount == 1)
        #expect(report.count == 2)
        #expect(report.buckets.isEmpty && report.categories.isEmpty)
        #expect(report.change == nil && report.largest == nil && report.averagePerDay == nil)
        #expect(report.daysWithoutSpending == nil)
        let income = try InsightsAnalytics.report(records, period: .thisMonth, kind: .income,
            now: date("2026-10-04T12:00:00Z"), calendar: calendar)
        #expect(income.total == 25)
    }

    @Test("Invalid previous amounts disable comparison but not complete current statistics")
    func incompleteComparison() throws {
        let records = [row("now", 10, "2026-10-01T00:00:00Z"), row("prior", -1, "2026-09-01T00:00:00Z")]
        let report = try InsightsAnalytics.report(records, period: .thisMonth, kind: .expense,
            now: date("2026-10-01T12:00:00Z"), calendar: calendar)
        #expect(report.total == 10)
        #expect(report.previousTotal == nil && report.changePercent == nil)
        #expect(report.previousInvalidAmountCount == 1)
        #expect(report.categories.count == 1)
    }

    @Test("Unknown types and undated rows are disclosed; zero rows do not create a spending day")
    func exclusionsAndZeros() throws {
        let records = [row("zero", 0, "2026-10-01T00:00:00Z"), row("unknown", 50, "2026-10-02T00:00:00Z", type: "broken"), row("undated", 70, nil)]
        let report = try InsightsAnalytics.report(records, period: .thisMonth, kind: .expense,
            now: date("2026-10-03T12:00:00Z"), calendar: calendar)
        #expect(report.total == 0 && report.previousTotal == 0)
        #expect(report.changePercent == nil)
        #expect(report.excludedUnknownTypeCount == 1 && report.excludedUndatedCount == 1)
        #expect(report.daysWithoutSpending == 3)
        #expect(report.categories.first?.share == 0)
    }

    @Test("All-time and empty histories remain bounded with exact monthly or yearly bucket sums")
    func longHistory() throws {
        let records = [row("old", 1, "1900-01-01T00:00:00Z"), row("new", 2, "2026-10-04T00:00:00Z")]
        let report = try InsightsAnalytics.report(records, period: .allTime, kind: .expense,
            now: date("2026-10-04T12:00:00Z"), calendar: calendar)
        #expect(report.total == 3 && report.previousRange == nil && report.change == nil)
        #expect(report.buckets.count <= 122)
        #expect(report.buckets.reduce(Decimal.zero) { $0 + $1.amount } == 3)
        #expect(report.buckets.first?.id == report.range.start)
        #expect(report.buckets.last?.endExclusive == report.range.endExclusive)
        let empty = try InsightsAnalytics.report([], period: .allTime, kind: .expense,
            now: date("2026-10-04T12:00:00Z"), calendar: calendar)
        #expect(empty.count == 0 && empty.total == 0 && empty.averageTransaction == nil)
        #expect(empty.buckets.count == 1)
    }

    @Test("Aggregate overflow fails visibly")
    func overflow() throws {
        let maximum = Decimal.greatestFiniteMagnitude
        let records = [row("a", maximum, "2026-10-01T00:00:00Z"), row("b", maximum, "2026-10-01T00:00:00Z")]
        #expect(throws: MoneyError.self) {
            try InsightsAnalytics.report(records, period: .thisMonth, kind: .expense,
                now: date("2026-10-04T12:00:00Z"), calendar: calendar)
        }
    }

    @Test("Excluded old unknown types cannot dilute All Time averages or quiet-day counts")
    func allTimeUnknownType() throws {
        let records = [row("valid", 40, "2026-10-04T00:00:00Z"),
            row("ancient-invalid", 9, "1900-01-01T00:00:00Z", type: "corrupt")]
        let report = try InsightsAnalytics.report(records, period: .allTime, kind: .expense,
            now: date("2026-10-04T12:00:00Z"), calendar: calendar)
        #expect(report.range.dayCount == 1)
        #expect(report.averagePerDay == 40)
        #expect(report.daysWithoutSpending == 0)
        #expect(report.buckets.count == 1)
    }

    @Test("Dashboard and Insights include the same complete local days, including after rollover")
    func dashboardPeriodParity() throws {
        for now in [date("2026-10-04T23:59:00Z"), date("2026-10-05T00:01:00Z")] {
            for (dashboard, insights) in [(ExpenseCDFilterTime.week, InsightsPeriod.last7Days), (.month, .last30Days)] {
                let window = ExpenseCalendarWindow(filter: dashboard, now: now, calendar: calendar)
                let (range, _) = try InsightsAnalytics.ranges([], period: insights, now: now, calendar: calendar)
                #expect(window.start == range.start)
                #expect(window.endExclusive == range.endExclusive)
                #expect(window.predicate.evaluate(with: ["occuredOn": range.start]))
                #expect(window.predicate.evaluate(with: ["occuredOn": range.endExclusive.addingTimeInterval(-1)]))
                #expect(!window.predicate.evaluate(with: ["occuredOn": range.start.addingTimeInterval(-1)]))
                #expect(!window.predicate.evaluate(with: ["occuredOn": range.endExclusive]))
            }
        }
        let all = ExpenseCalendarWindow(filter: .all, now: date("2026-10-04T12:00:00Z"), calendar: calendar)
        #expect(!all.predicate.evaluate(with: ["occuredOn": NSNull()]))
        #expect(!all.predicate.evaluate(with: ["occuredOn": all.endExclusive]))
        #expect(all.predicate.evaluate(with: ["occuredOn": date("1900-01-01T00:00:00Z")]))
    }
}

@Suite("Insights conversion parity — isolated Core Data integration")
@MainActor
struct InsightsProjectionTests {
    @Test("Projected per-row rounding matches History, reports and category totals")
    func lockedRates() throws {
        let store = try CurrencyTestStore()
        _ = try store.transaction(amount: "1", currency: "BAM", rates: ["BAM": 1, "RUB": Decimal(string: "0.005")!])
        _ = try store.transaction(amount: "1", currency: "BAM", rates: ["BAM": 1, "RUB": Decimal(string: "0.005")!])
        try store.context.save()
        let projected = try HistoryLedgerProjection.fetch(in: store.context)
        let rows = projected.map { InsightsTransaction(id: $0.id.uriRepresentation().absoluteString,
            title: $0.record.title, type: $0.record.type, category: $0.record.category,
            date: $0.record.occurredOn, amount: try? $0.amount(in: "RUB")) }
        let report = try InsightsAnalytics.report(rows, period: .allTime, kind: .expense,
            now: ISO8601DateFormatter().date(from: "2026-10-04T12:00:00Z")!)
        #expect(report.total == Decimal(string: "0.02"))
        #expect(report.total == (try Money.total(LedgerStoreTransaction.records(in: store.context), base: "RUB")))
        #expect(report.categories.first?.amount == report.total)
    }
}
