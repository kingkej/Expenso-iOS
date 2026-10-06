import Foundation
import CoreData
import Testing
@testable import Expenso

struct TransactionHistoryFilterTests {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: "America/New_York")!
        return result
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func record(title: String = "Coffee", note: String = "Morning meeting", type: String = "expense",
                        category: String = "food", currency: String = "RUB", amount: Decimal? = 100,
                        day: Date? = nil) -> TransactionHistoryRecord {
        TransactionHistoryRecord(title: title, note: note, type: type, category: category,
            currency: currency, originalAmount: amount, occurredOn: day)
    }

    @Test("Search reads titles and notes case-insensitively, with literal punctuation")
    func literalSearch() {
        #expect(TransactionHistoryFilter(search: " COFFEE ").matches(record()))
        #expect(TransactionHistoryFilter(search: "meeting").matches(record()))
        #expect(TransactionHistoryFilter(search: "%_").matches(record(note: "Receipt %_ code")))
        #expect(!TransactionHistoryFilter(search: "%_").matches(record()))
        #expect(!TransactionHistoryFilter(search: "food").matches(record()))
    }

    @Test("Type, category and original currency are exact, combined filters")
    func exactFields() {
        let filter = TransactionHistoryFilter(type: "expense", category: "food", currency: "RUB")
        #expect(filter.matches(record()))
        #expect(!filter.matches(record(type: "income")))
        #expect(!filter.matches(record(category: "food-extra")))
        #expect(!filter.matches(record(currency: "EUR")))
        #expect(!filter.matches(record(currency: "rub")))
    }

    @Test("Missing-category drilldown preserves uncategorized rows instead of selecting Others")
    func missingCategory() {
        let filter = TransactionHistoryFilter(category: "")
        #expect(filter.matches(record(category: "")))
        #expect(!filter.matches(record(category: TRANS_TAG_OTHERS)))
        #expect(!filter.matches(record(category: "unsupported-tag")))
    }

    @Test("Amount bounds use precise original decimals and include both boundaries")
    func originalAmounts() {
        let lower = Decimal(string: "100.000000001")!
        let upper = Decimal(string: "100.000000002")!
        let filter = TransactionHistoryFilter(minimumAmount: lower, maximumAmount: upper)
        #expect(filter.matches(record(amount: lower)))
        #expect(filter.matches(record(currency: "BAM", amount: upper)))
        #expect(!filter.matches(record(amount: 100)))
        #expect(!filter.matches(record(amount: Decimal(string: "100.000000003"))))
        #expect(!filter.matches(record(amount: nil)))
        #expect(!filter.matches(record(amount: .nan)))
        #expect(!filter.matches(record(amount: -1)))
    }

    @Test("All-time includes undated records; constrained dates do not")
    func missingDates() {
        #expect(TransactionHistoryFilter().matches(record()))
        #expect(!TransactionHistoryFilter(startDay: date(2026, 1, 1)).matches(record()))
        #expect(!TransactionHistoryFilter(endDay: date(2026, 1, 31)).matches(record()))
    }

    @Test("Inclusive local days correctly span a short daylight-saving day")
    func inclusiveDays() {
        let day = date(2026, 3, 8)
        let filter = TransactionHistoryFilter(startDay: day, endDay: day)
        #expect(filter.matches(record(day: day), calendar: calendar))
        #expect(filter.matches(record(day: date(2026, 3, 8, hour: 23, minute: 59)), calendar: calendar))
        #expect(!filter.matches(record(day: date(2026, 3, 7, hour: 23, minute: 59)), calendar: calendar))
        #expect(!filter.matches(record(day: date(2026, 3, 9)), calendar: calendar))
    }

    @Test("Calendar months respect leap days and exclude adjacent months")
    func calendarMonth() {
        var filter = TransactionHistoryFilter()
        filter.selectMonth(containing: date(2024, 2, 15), calendar: calendar)
        #expect(filter.startDay == date(2024, 2, 1))
        #expect(filter.endDay == date(2024, 2, 29))
        #expect(filter.matches(record(day: date(2024, 2, 29, hour: 23, minute: 59)), calendar: calendar))
        #expect(!filter.matches(record(day: date(2024, 3, 1)), calendar: calendar))
        #expect(!filter.matches(record(day: date(2024, 1, 31)), calendar: calendar))
    }

    @Test("Invalid ranges are rejected instead of silently swapping values")
    func invalidRanges() {
        let amounts = TransactionHistoryFilter(minimumAmount: 101, maximumAmount: 100)
        #expect(throws: TransactionHistoryFilter.ValidationError.self) { try amounts.validate() }
        #expect(!amounts.matches(record()))
        let dates = TransactionHistoryFilter(startDay: date(2026, 10, 4), endDay: date(2026, 10, 3))
        #expect(throws: TransactionHistoryFilter.ValidationError.self) { try dates.validate(calendar: calendar) }
        #expect(throws: TransactionHistoryFilter.ValidationError.self) {
            try TransactionHistoryFilter(minimumAmount: .nan).validate()
        }
    }

    @Test("Empty amounts are unbounded; decimal comma is supported without grouping", arguments: ["12.50", "12,50", " 12.50 "])
    func validBound(_ input: String) throws {
        #expect(try TransactionHistoryFilter.amountBound(input) == Decimal(string: "12.50"))
        #expect(try TransactionHistoryFilter.amountBound(" ") == nil)
    }

    @Test("Malformed, negative, grouped and excessive precision bounds are rejected", arguments: ["-1", "NaN", "1e3", "1,234.50", "1 234", "1.0000000001", ".5", "12."])
    func invalidBound(_ input: String) {
        #expect(throws: TransactionHistoryFilter.ValidationError.self) {
            try TransactionHistoryFilter.amountBound(input)
        }
    }
}

@Suite("History field projection — isolated SQLite integration")
@MainActor
struct TransactionHistoryProjectionTests {
    private func projection(_ object: ExpenseCD) -> HistoryLedgerProjection {
        HistoryLedgerProjection(id: object.objectID, record: TransactionHistoryRecord(
            title: object.title ?? "", note: object.note ?? "", type: object.type ?? "",
            category: object.tag ?? "", currency: object.originalCurrency,
            originalAmount: object.originalDecimal, occurredOn: object.occuredOn),
            createdAt: object.createdAt, rateSnapshotData: object.rateSnapshotData)
    }

    @Test("Nearest-date warning applies only to valid recognized foreign conversions")
    func estimatedConversions() throws {
        let store = try CurrencyTestStore()
        let nearest = CurrencyRateSnapshot(date: "2026-10-02", rates: ["USD": 1, "RUB": 100],
            source: "Test saved rate", requestedDate: "2026-10-03")
        let encoded = try JSONEncoder().encode(nearest)
        let foreign = try store.transaction(amount: "2", currency: "USD")
        foreign.rateSnapshotData = encoded
        let local = try store.transaction(amount: "10", currency: "RUB")
        local.rateSnapshotData = encoded
        let unknown = try store.transaction(amount: "2", currency: "USD", type: "unknown")
        unknown.rateSnapshotData = encoded
        let unavailable = try store.transaction(amount: "2", currency: "EUR")
        unavailable.rateSnapshotData = encoded
        let rows = [foreign, local, unknown, unavailable].map(projection)
        #expect(rows[0].isEstimated(in: "RUB"))
        #expect(!rows[0].isEstimated(in: "USD"))
        #expect(!rows[1].isEstimated(in: "RUB"))
        #expect(!rows[2].isEstimated(in: "RUB"))
        #expect(!rows[3].isEstimated(in: "RUB"))
        let converted = Array(rows.prefix(2))
        let totals = HistoryFilteredTotals.compute(converted.map { ($0.record.type, try? $0.amount(in: "RUB")) },
            estimatedCount: converted.filter { $0.isEstimated(in: "RUB") }.count)
        #expect(totals.expense == 210)
        #expect(totals.netCashFlow == -210)
        #expect(totals.estimatedConversionCount == 1)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 3)))
        foreign.occuredOn = today
        local.occuredOn = today
        let window = ExpenseCalendarWindow(filter: .month, now: today, calendar: calendar)
        let dashboard = DashboardSummary.compute([foreign, local].map(projection), window: window, currency: "RUB")
        #expect(dashboard.estimatedConversionCount == 1)
        #expect(dashboard.expense == 210)
        foreign.amountText = "-2"
        #expect(!projection(foreign).isEstimated(in: "RUB"))
        foreign.amountText = "2"
        foreign.rateSnapshotData = try JSONEncoder().encode(CurrencyRateSnapshot(date: "2026-10-03",
            rates: nearest.rates, source: "Exact saved rate", requestedDate: "2026-10-03"))
        #expect(!projection(foreign).isEstimated(in: "RUB"))
    }

    @Test("Filtered totals match canonical per-transaction rounding and checked Decimal cash flow")
    func exactFilteredTotals() throws {
        let store = try CurrencyTestStore()
        let income = try store.transaction(amount: "12.345678901", currency: "BAM",
            rates: ["BAM": 1, "RUB": Decimal(string: "48.1234")!], type: "income")
        let expense = try store.transaction(amount: "0.005", currency: "RUB")
        let convertedExpense = try store.transaction(amount: "1.005", currency: "USD",
            rates: ["USD": 1, "RUB": Decimal(string: "3.27")!])
        let excluded = try store.transaction(amount: "999", currency: "RUB")
        excluded.note = "Different group"
        let unknown = try store.transaction(amount: "99", currency: "EUR", type: "unrecognized")
        for object in [income, expense, convertedExpense, unknown] { object.note = "Exact group" }
        let objects = [income, expense, convertedExpense, excluded, unknown]
        let filter = TransactionHistoryFilter(search: "Exact group")
        let selectedObjects = objects.filter { filter.matches(projection($0).record) }
        let selected = objects.map(projection).filter { filter.matches($0.record) }
        let totals = HistoryFilteredTotals.compute(selected.map { (type: $0.record.type, amount: try? $0.amount(in: "RUB")) })
        #expect(totals.income == (try Money.total(selectedObjects.filter { $0.type == "income" }, base: "RUB")))
        #expect(totals.expense == (try Money.total(selectedObjects.filter { $0.type == "expense" }, base: "RUB")))
        #expect(totals.netCashFlow == (try Money.total(selectedObjects, base: "RUB", balance: true)))
        #expect(totals.expense == Decimal(string: "3.30"))
        #expect(totals.excludedUnknownTypes == 1)
        var amountFilter = filter
        amountFilter.minimumAmount = 1
        let bounded = selected.filter { amountFilter.matches($0.record) }
        let boundedTotals = HistoryFilteredTotals.compute(bounded.map { (type: $0.record.type, amount: try? $0.amount(in: "RUB")) })
        let boundedObjects = selectedObjects.filter { amountFilter.matches(projection($0).record) }
        #expect(boundedTotals.expense == Decimal(string: "3.29"))
        #expect(boundedTotals.netCashFlow == (try Money.total(boundedObjects, base: "RUB", balance: true)))
        for object in selectedObjects where object.type == "income" || object.type == "expense" {
            #expect(try projection(object).amount(in: "RUB") == object.amount(in: "RUB"))
        }
    }

    @Test("Missing conversion never silently drops an amount; only affected totals become unavailable")
    func unavailableFilteredTotals() throws {
        let store = try CurrencyTestStore()
        let income = try store.transaction(amount: "100", currency: "RUB", type: "income")
        let expense = try store.transaction(amount: "12", currency: "EUR")
        let unknown = try store.transaction(amount: "999", currency: "EUR", type: "unknown")
        let projected = [income, expense, unknown].map(projection)
        #expect(throws: MoneyError.self) { try projection(expense).amount(in: "RUB") }
        let totals = HistoryFilteredTotals.compute(projected.map { (type: $0.record.type, amount: try? $0.amount(in: "RUB")) })
        #expect(totals.income == 100)
        #expect(totals.expense == nil)
        #expect(totals.netCashFlow == nil)
        #expect(totals.excludedUnknownTypes == 1)
        let onlyIncome = HistoryFilteredTotals.compute(projected.filter { $0.record.type == "income" }
            .map { (type: $0.record.type, amount: try? $0.amount(in: "RUB")) })
        #expect(onlyIncome.income == 100)
        #expect(onlyIncome.expense == 0)
        #expect(onlyIncome.netCashFlow == 100)
        let missingIncome = HistoryFilteredTotals.compute([(type: "income", amount: nil), (type: "expense", amount: 12)])
        #expect(missingIncome.income == nil)
        #expect(missingIncome.expense == 12)
        #expect(missingIncome.netCashFlow == nil)
        let empty = HistoryFilteredTotals.compute([])
        #expect(empty.income == 0 && empty.expense == 0 && empty.netCashFlow == 0)
    }

    @Test("Dashboard totals cover every matching transaction beyond the five-row preview")
    func dashboardFullPeriod() throws {
        let store = try CurrencyTestStore()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 6))!
        let window = ExpenseCalendarWindow(filter: .month, now: today, calendar: calendar)
        var objects: [ExpenseCD] = []
        for _ in 0..<8 {
            let object = try store.transaction(amount: "10", currency: "RUB")
            object.occuredOn = today
            objects.append(object)
        }
        let income = try store.transaction(amount: "100", currency: "RUB", type: "income")
        income.occuredOn = today
        let future = try store.transaction(amount: "999", currency: "RUB")
        future.occuredOn = window.endExclusive
        let undated = try store.transaction(amount: "999", currency: "RUB")
        undated.occuredOn = nil
        let old = try store.transaction(amount: "999", currency: "RUB")
        old.occuredOn = calendar.date(byAdding: .day, value: -30, to: today)
        let summary = DashboardSummary.compute((objects + [income, future, undated, old]).map(projection), window: window, currency: "RUB")
        #expect(summary.expense == 80)
        #expect(summary.income == 100)
        #expect(summary.netCashFlow == 20)
        let expenses = window.historyFilter(type: "expense")
        #expect(objects.allSatisfy { expenses.matches(projection($0).record, calendar: calendar) })
        #expect(!expenses.matches(projection(income).record, calendar: calendar))
        #expect(!expenses.matches(projection(future).record, calendar: calendar))
        #expect(!expenses.matches(projection(undated).record, calendar: calendar))
    }

    @Test("History excludes images, preserves exact originals and never realizes saved ledger objects")
    func lightweightProjectionAndPendingChanges() throws {
        let model = try CurrencyTestStore.model(version: "ExpensoV2")
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
            at: directory.appendingPathComponent("History.sqlite"))
        defer { try? coordinator.remove(store) }
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        defer { context.reset() }
        let entity = try #require(model.entitiesByName["ExpenseCD"])
        let request = HistoryLedgerProjection.request(entity: entity)
        let propertyNames = try #require(request.propertiesToFetch).compactMap { ($0 as? NSPropertyDescription)?.name }
        #expect(request.resultType == .dictionaryResultType)
        #expect(!request.includesPendingChanges)
        #expect(!propertyNames.contains("imageAttached"))
        #expect(propertyNames.contains("rateSnapshotData"))

        let original = ExpenseCD(entity: entity, insertInto: context)
        original.title = "Image-bearing fixture"
        original.note = "Projected note"
        original.tag = "food"
        original.type = "expense"
        original.amount = 12.345678901
        original.amountText = "12.345678901"
        original.currencyCode = "BAM"
        original.imageAttached = Data(repeating: 0xab, count: 1024 * 1024)
        original.occuredOn = Date(timeIntervalSince1970: 100)
        original.rateSnapshotData = Data("opaque preserved metadata".utf8)
        try context.save()
        let savedID = original.objectID
        context.reset()

        let first = try #require(HistoryLedgerProjection.fetch(in: context).first)
        #expect(first.id == savedID)
        #expect(first.record.originalAmount == Decimal(string: "12.345678901"))
        #expect(first.record.currency == "BAM")
        #expect(first.record.note == "Projected note")
        #expect(first.rateSnapshotData == Data("opaque preserved metadata".utf8))
        #expect(context.registeredObjects.isEmpty)

        let edited = try #require(context.existingObject(with: savedID) as? ExpenseCD)
        edited.title = "Pending title"
        #expect(try HistoryLedgerProjection.fetch(in: context).first?.record.title == "Pending title")
        let inserted = ExpenseCD(entity: entity, insertInto: context)
        inserted.title = "Pending new record"
        inserted.amount = 25
        inserted.type = "income"
        inserted.tag = "others"
        context.delete(edited)
        let pending = try HistoryLedgerProjection.fetch(in: context)
        #expect(pending.count == 1)
        #expect(pending.first?.id == inserted.objectID)
        #expect(pending.first?.record.title == "Pending new record")
        #expect(pending.first?.record.currency == "RUB")
        #expect(pending.first?.record.originalAmount == 25)
        #expect(context.hasChanges) // Projection never saves or rolls back pending edits.
    }
}
