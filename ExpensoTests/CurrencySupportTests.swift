import Foundation
import CoreData
import Testing
@testable import Expenso

@Suite("Summary amount display — Decimal-only abbreviations")
struct SummaryAmountDisplayTests {
    private let english = Locale(identifier: "en_US")

    @Test("Concurrent formatter reuse keeps locale and currency precision isolated")
    func concurrentFormatting() async {
        await withTaskGroup(of: Bool.self) { group in
            for index in 0..<100 {
                group.addTask {
                    if index.isMultiple(of: 2) {
                        return Money.format(12.345, currency: "KWD", locale: Locale(identifier: "en_US")) == "12.345 KWD"
                    }
                    return Money.format(12.5, currency: "EUR", locale: Locale(identifier: "de_DE")) == "12,50 EUR"
                }
            }
            for await matches in group { #expect(matches) }
        }
    }

    @Test("Compact thresholds, signs and rollover", arguments: [
        ("0", "0.00 RUB"), ("999.94", "999.94 RUB"), ("-999.94", "-999.94 RUB"),
        ("1000", "1K RUB"), ("-1000", "-1K RUB"), ("1234", "1.2K RUB"),
        ("1250", "1.3K RUB"), ("-1250", "-1.3K RUB"),
        ("999949", "999.9K RUB"), ("999950", "1M RUB"),
        ("-999950", "-1M RUB"), ("1000000", "1M RUB"),
        ("999950000", "1B RUB"), ("1000000000", "1B RUB"),
        ("999950000000", "1T RUB"), ("1000000000000", "1T RUB"),
        ("1200000000000000", "1200T RUB")
    ])
    func compact(_ input: String, expected: String) throws {
        let amount = try #require(Decimal(string: input))
        #expect(Money.display(amount, currency: "RUB", compact: true, locale: english) == expected)
        #expect(Money.string(amount) == input)
    }

    @Test("Exact display retains currency minor units below the cutoff", arguments: [
        ("0", "JPY", "0 JPY"), ("12.6", "JPY", "13 JPY"),
        ("12.345", "KWD", "12.345 KWD"), ("12.5", "EUR", "12.50 EUR")
    ])
    func minorUnits(_ input: String, _ currency: String, expected: String) throws {
        let amount = try #require(Decimal(string: input))
        #expect(Money.display(amount, currency: currency, compact: true, locale: english) == expected)
    }

    @Test("Disabled abbreviation remains exact, including negative and large values", arguments: [
        ("1234.56", "1,234.56 USD"), ("-1234.56", "-1,234.56 USD"),
        ("1000000", "1,000,000.00 USD")
    ])
    func exact(_ input: String, expected: String) throws {
        let amount = try #require(Decimal(string: input))
        #expect(Money.display(amount, currency: "USD", compact: false, locale: english) == expected)
        #expect(Money.format(amount, currency: "USD", locale: english) == expected)
    }

    @Test("Suffixes stay English while decimal separators follow the supplied locale")
    func localized() {
        let german = Locale(identifier: "de_DE")
        #expect(Money.display(1_250, currency: "EUR", compact: true, locale: german) == "1,3K EUR")
        #expect(Money.display(-1_250, currency: "EUR", compact: true, locale: german) == "-1,3K EUR")
        #expect(Money.display(12.5, currency: "EUR", compact: true, locale: german) == "12,50 EUR")
    }

    @Test("Numeric card components omit only the currency caption", arguments: [
        ("1250", "RUB", true, "1.3K"), ("-1250", "RUB", true, "-1.3K"),
        ("1250", "RUB", false, "1,250.00"), ("0", "JPY", true, "0"),
        ("12.345", "KWD", true, "12.345")
    ])
    func numericComponent(_ input: String, _ currency: String, _ compact: Bool, expected: String) throws {
        let amount = try #require(Decimal(string: input))
        #expect(Money.displayNumber(amount, currency: currency, compact: compact, locale: english) == expected)
        #expect(Money.display(amount, currency: currency, compact: compact, locale: english) == "\(expected) \(currency)")
    }

    @Test("Invalid Decimal never enters abbreviation comparisons", arguments: [false, true])
    func invalid(_ compact: Bool) {
        #expect(Money.display(.nan, currency: "RUB", compact: compact, locale: english) == "Invalid amount")
        #expect(Money.displayNumber(.nan, currency: "RUB", compact: compact, locale: english) == "Invalid amount")
    }
}

@Suite("Currency calculations")
@MainActor
struct CurrencySupportTests {
    @Test("Rent concepts match rental Travel spending without replacing the exact category", arguments: [
        "rent", "rental", "rentals", "аренда", "аренды", "аренду", "аренде", "арендой"
    ])
    func rentalConceptSearch(_ search: String) throws {
        let store = try CurrencyTestStore()
        let rental = try store.transaction(amount: "59500", currency: "RUB")
        rental.title = "Car rental"
        rental.tag = TRANS_TAG_TRAVEL
        let otherTravel = try store.transaction(amount: "7230", currency: "RUB")
        otherTravel.title = "Train tickets"
        otherTravel.tag = TRANS_TAG_TRAVEL
        let housing = try store.transaction(amount: "7741", currency: "RUB")
        housing.title = "Apartment rent"
        housing.tag = TRANS_TAG_HOUSING
        try store.context.save()
        let before = [LedgerRecord(rental), LedgerRecord(otherTravel), LedgerRecord(housing)]
        let data = SpendingDataStore(context: store.context, baseCurrency: "RUB")
        let report = try data.report(startDate: "2026-10-01", endDate: "2026-10-01",
            kind: "expense", category: TRANS_TAG_TRAVEL, search: search)
        #expect(report.totalExpense == "59500" && report.matchingCount == 1)
        #expect(report.category == TRANS_TAG_TRAVEL && report.kind == "expense")
        #expect(report.startDate == "2026-10-01" && report.endDate == "2026-10-01")
        #expect(report.titleSearch == search)
        #expect(report.titleSearchTerms.contains("rental") && report.titleSearchTerms.contains("аренда"))
        #expect(report.titleSearchTerms.count <= 16)
        #expect(report.topTransactions.first?.id == rental.objectID.uriRepresentation().absoluteString)
        let allTravel = try data.report(startDate: "2026-10-01", endDate: "2026-10-01",
            kind: "expense", category: TRANS_TAG_TRAVEL, search: "")
        #expect(allTravel.totalExpense == "66730" && allTravel.matchingCount == 2)
        #expect([LedgerRecord(rental), LedgerRecord(otherTravel), LedgerRecord(housing)] == before)
        #expect(!store.context.hasChanges)
    }

    @Test("Alias token matching excludes parents and retains requested date and kind filters")
    func rentalSearchBoundaries() throws {
        let store = try CurrencyTestStore()
        let included = try store.transaction(amount: "59500", currency: "RUB")
        included.title = "Rental (car)"
        included.tag = TRANS_TAG_TRAVEL
        let parents = try store.transaction(amount: "100", currency: "RUB")
        parents.title = "Parents visit"
        parents.tag = TRANS_TAG_TRAVEL
        let old = try store.transaction(amount: "200", currency: "RUB")
        old.title = "Rent car"
        old.tag = TRANS_TAG_TRAVEL
        let oldDate = ISO8601DateFormatter().date(from: "2026-09-01T12:00:00Z")
        old.occuredOn = try #require(oldDate)
        let income = try store.transaction(amount: "300", currency: "RUB", type: TRANS_TYPE_INCOME)
        income.title = "Rent refund"
        income.tag = TRANS_TAG_TRAVEL
        try store.context.save()
        let records = [included, parents, old, income]
        let before = records.map(LedgerRecord.init)
        let report = try SpendingDataStore(context: store.context, baseCurrency: "RUB")
            .report(startDate: "2026-10-01", endDate: "2026-10-01", kind: "expense", category: TRANS_TAG_TRAVEL, search: "rent")
        #expect(report.totalExpense == "59500" && report.totalIncome == "0")
        #expect(report.matchingCount == 1 && report.skippedOtherKindCount == 1)
        #expect(report.topTransactions.map(\.id) == [included.objectID.uriRepresentation().absoluteString])
        #expect(records.map(LedgerRecord.init) == before && !store.context.hasChanges)
    }

    @Test("Other bounded spending concepts bridge English and Russian titles", arguments: [
        ("coffee", "Coffee shop", "Кофе утром"), ("кофе", "Coffee shop", "Кофе утром"),
        ("taxi", "Taxi ride", "Такси домой"), ("такси", "Taxi ride", "Такси домой"),
        ("groceries", "Groceries delivery", "Покупка продуктов"),
        ("продуктами", "Groceries delivery", "Покупка продуктов")
    ])
    func otherSearchConcepts(_ query: String, _ english: String, _ russian: String) throws {
        let store = try CurrencyTestStore()
        let first = try store.transaction(amount: "10", currency: "RUB")
        first.title = english
        let second = try store.transaction(amount: "20", currency: "RUB")
        second.title = russian
        try store.context.save()
        let report = try SpendingDataStore(context: store.context, baseCurrency: "RUB")
            .report(startDate: "", endDate: "", kind: "expense", category: "all", search: query)
        #expect(report.matchingCount == 2 && report.totalExpense == "30")
        #expect(report.titleSearchTerms.count >= 2 && report.titleSearchTerms.count <= 16)
        #expect(!store.context.hasChanges)
    }

    @Test("Unrecognized wildcard and quote searches remain literal", arguments: [
        ("a*b", "Invoice a*b", "Invoice axb"),
        ("O'Reilly", "O'Reilly books", "Other books"),
        ("café", "CAFE receipt", "Coffee receipt")
    ])
    func literalSearch(_ query: String, _ matchingTitle: String, _ otherTitle: String) throws {
        let store = try CurrencyTestStore()
        let matching = try store.transaction(amount: "12", currency: "RUB")
        matching.title = matchingTitle
        let other = try store.transaction(amount: "99", currency: "RUB")
        other.title = otherTitle
        try store.context.save()
        let report = try SpendingDataStore(context: store.context, baseCurrency: "RUB")
            .report(startDate: "", endDate: "", kind: "expense", category: "all", search: query)
        #expect(report.matchingCount == 1 && report.totalExpense == "12")
        #expect(report.titleSearchTerms == [query])
        #expect(report.topTransactions.first?.id == matching.objectID.uriRepresentation().absoluteString)
        #expect(!store.context.hasChanges)
    }

    @Test("Rent totals include every match, not just the five displayed evidence records")
    func rentalTotalsBeyondTopFive() throws {
        let store = try CurrencyTestStore()
        for amount in [10, 20, 30, 40, 50, 60] {
            let transaction = try store.transaction(amount: String(amount), currency: "RUB")
            transaction.title = "Rental \(amount)"
            transaction.tag = TRANS_TAG_TRAVEL
        }
        try store.context.save()
        let report = try SpendingDataStore(context: store.context, baseCurrency: "RUB")
            .report(startDate: "", endDate: "", kind: "expense", category: TRANS_TAG_TRAVEL, search: "аренда")
        #expect(report.matchingCount == 6 && report.totalExpense == "210")
        #expect(report.topTransactions.count == 5)
        #expect(report.topTransactions.map(\.amount) == ["60", "50", "40", "30", "20"])
        #expect(!store.context.hasChanges)
    }

    @Test("An approximate locked snapshot survives an ordinary same-day edit")
    func approximateSameDayEdit() async throws {
        let store = try CurrencyTestStore()
        let transaction = try store.transaction(amount: "100", currency: "USD")
        let snapshot = CurrencyRateSnapshot(date: "2026-09-30", rates: ["USD": 1, "RUB": 90],
            source: "https://rates.example/2026-09-30", requestedDate: "2026-10-01")
        transaction.rateSnapshotData = try JSONEncoder().encode(snapshot)
        try store.context.save()
        let editor = AddExpenseViewModel(expenseObj: transaction, baseCurrency: "RUB")
        editor.title = "Reviewed expense"
        await editor.refreshRate()
        #expect(editor.rateSnapshot == snapshot)
        #expect(editor.rateApproximationNotice == snapshot.approximationNotice)
        await editor.saveTransaction(managedObjectContext: store.context)
        #expect(editor.closePresenter && !editor.showAlert)
        #expect(transaction.lockedRates == snapshot)
        #expect(Money.day(transaction.occuredOn!) == "2026-10-01")
        #expect(try transaction.amount(in: "RUB") == 9_000)
    }

    @Test("A manual target retains inherited approximate rates and their actual provenance")
    func approximateManualTarget() async throws {
        let store = try CurrencyTestStore()
        let transaction = try store.transaction(amount: "100", currency: "USD")
        let inherited = CurrencyRateSnapshot(date: "2026-09-30", rates: ["USD": 1, "RUB": 90],
            source: "https://rates.example/2026-09-30", requestedDate: "2026-10-01")
        transaction.rateSnapshotData = try JSONEncoder().encode(inherited)
        try store.context.save()
        let editor = AddExpenseViewModel(expenseObj: transaction, baseCurrency: "RUB")
        editor.conversionCurrency = "EUR"
        editor.useManualRate = true
        editor.manualRate = "0.9"
        #expect(editor.rateApproximationNotice == inherited.approximationNotice)
        await editor.saveTransaction(managedObjectContext: store.context)
        #expect(editor.closePresenter && !editor.showAlert)
        let saved = try #require(transaction.lockedRates)
        #expect(saved.date == "2026-09-30" && saved.requestedDate == "2026-10-01")
        #expect(saved.isApproximate)
        #expect(saved.approximationNotice == inherited.approximationNotice)
        #expect(saved.source.contains(inherited.source))
        #expect(saved.source.contains("1 USD = 0.9 EUR"))
        #expect(saved.source.contains("entered for 2026-10-01"))
        #expect(try saved.rate(from: "USD", to: "RUB") == 90)
        #expect(try transaction.amount(in: "RUB") == 9_000)
        #expect(try transaction.amount(in: "EUR") == 90)
        #expect(transaction.amountText == "100")
    }

    @Test("Legacy snapshot JSON without requested date remains exact and round-trips")
    func legacySnapshotProvenance() throws {
        let data = Data(#"{"date":"2026-10-01","rates":{"USD":1,"RUB":90},"source":"Fixture"}"#.utf8)
        let snapshot = try JSONDecoder().decode(CurrencyRateSnapshot.self, from: data)
        #expect(snapshot.requestedDate == nil && !snapshot.isApproximate)
        #expect(snapshot.approximationNotice == nil)
        #expect(snapshot.exportSource == "Fixture")
        #expect(try JSONDecoder().decode(CurrencyRateSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
    }

    @Test("Compact labels cannot change totals or stored original amounts")
    func compactSummaryIsDisplayOnly() throws {
        let store = try CurrencyTestStore()
        let expense = try store.transaction(amount: "1234.56", currency: "RUB")
        let income = try store.transaction(amount: "2000", currency: "RUB", type: TRANS_TYPE_INCOME)
        let records = [expense, income]
        let before = try Money.total(records, base: "RUB", balance: true)
        #expect(before == Decimal(string: "765.44"))
        #expect(Money.totalLabel(records, base: "RUB", compact: true) == Money.display(Decimal(string: "3234.56")!, currency: "RUB", compact: true))
        #expect(Money.totalLabel(records, base: "RUB") == Money.format(Decimal(string: "3234.56")!, currency: "RUB"))
        #expect(Money.totalLabel(records, base: "RUB", balance: true, compact: true) == Money.format(before, currency: "RUB"))
        #expect(try Money.total(records, base: "RUB", balance: true) == before)
        #expect(expense.amountText == "1234.56" && income.amountText == "2000")
        let extraExpense = try store.transaction(amount: "2000", currency: "RUB")
        let negativeRecords = records + [extraExpense]
        let negativeNet = try Money.total(negativeRecords, base: "RUB", balance: true)
        #expect(negativeNet == Decimal(string: "-1234.56"))
        #expect(Money.totalLabel(negativeRecords, base: "RUB", balance: true, compact: true) ==
            Money.display(negativeNet, currency: "RUB", compact: true))
        #expect(Money.displayNumber(negativeNet, currency: "RUB", compact: true, locale: Locale(identifier: "en_US_POSIX")) == "-1.2K")
        #expect(try Money.total(negativeRecords, base: "RUB", balance: true) == negativeNet)
        #expect(extraExpense.amountText == "2000" && expense.amountText == "1234.56" && income.amountText == "2000")
        #expect(AmountDisplaySettings.compactKey == "compactSummaryAmounts")
    }

    @Test("An empty legacy ledger cannot select a base its editor cannot save")
    func legacyBaseChange() async throws {
        let store = try CurrencyTestStore(version: "Expenso")
        let previousBase = CurrencySettings.base
        let settings = ExpenseSettingsViewModel()
        let proposedBase = previousBase == "USD" ? "EUR" : "USD"
        await settings.saveCurrency(currency: proposedBase, context: store.context)
        #expect(settings.showAlert)
        #expect(CurrencySettings.base == previousBase)
        #expect(!store.context.hasChanges)
    }

    @Test("Original BAM amount remains unchanged while RUB totals use the saved rate")
    func originalAndBaseAmounts() throws {
        let store = try CurrencyTestStore()
        let transaction = try store.transaction(amount: "100", currency: "BAM",
            rates: ["BAM": 1, "RUB": 50, "EUR": Decimal(string: "0.5")!])
        #expect(transaction.originalCurrency == "BAM")
        #expect(transaction.originalDecimal == 100)
        #expect(try transaction.amount(in: "RUB") == 5_000)
        #expect(try transaction.amount(in: "EUR") == 50)
        #expect(transaction.amountText == "100")
        #expect(transaction.amount == 100)
    }

    @Test("Different currencies are converted before income and expense balances are combined")
    func mixedCurrencyBalance() throws {
        let store = try CurrencyTestStore()
        let foreignExpense = try store.transaction(amount: "100", currency: "BAM", rates: ["BAM": 1, "RUB": 50])
        let localExpense = try store.transaction(amount: "50", currency: "RUB")
        let income = try store.transaction(amount: "200", currency: "RUB", type: TRANS_TYPE_INCOME)
        #expect(try Money.total([foreignExpense, localExpense], base: "RUB") == 5_050)
        #expect(try Money.total([foreignExpense, localExpense, income], base: "RUB", balance: true) == -4_850)
    }

    @Test("Round each transaction before totaling, not the combined foreign amount")
    func perTransactionRounding() throws {
        let store = try CurrencyTestStore()
        let rates: [String: Decimal] = ["BAM": 1, "RUB": Decimal(string: "0.005")!]
        let first = try store.transaction(amount: "1", currency: "BAM", rates: rates)
        let second = try store.transaction(amount: "1", currency: "BAM", rates: rates)
        #expect(try first.amount(in: "RUB") == Decimal(string: "0.01"))
        #expect(try Money.total([first, second], base: "RUB") == Decimal(string: "0.02"))
    }

    @Test("Base rounding respects each currency's minor units", arguments: [
        ("JPY", "1.5", "2"), ("RUB", "1.235", "1.24"), ("KWD", "1.2345", "1.235")
    ])
    func minorUnits(_ currency: String, _ input: String, _ expected: String) throws {
        let value = try #require(Decimal(string: input))
        #expect(Money.rounded(value, currency: currency) == Decimal(string: expected))
    }

    @Test("Missing conversions fail the whole total rather than dropping foreign spending")
    func missingRate() throws {
        let store = try CurrencyTestStore()
        let foreign = try store.transaction(amount: "100", currency: "BAM")
        let local = try store.transaction(amount: "50", currency: "RUB")
        #expect(throws: MoneyError.self) { try Money.total([foreign, local], base: "RUB") }
        #expect(Money.totalLabel([foreign, local], base: "RUB") == "Rates needed")
        #expect(Money.totalLabel([foreign, local], base: "RUB", compact: true) == "Rates needed")
    }

    @Test("A saved snapshot round-trips exactly and is not revalued by another quote")
    func lockedSnapshot() throws {
        let store = try CurrencyTestStore()
        let transaction = try store.transaction(amount: "100", currency: "BAM", rates: ["BAM": 1, "RUB": 50])
        let saved = try #require(transaction.rateSnapshotData)
        let laterQuote = CurrencyRateSnapshot(date: "2026-10-02", rates: ["BAM": 1, "RUB": 60], source: "Other day")
        #expect(try laterQuote.rate(from: "BAM", to: "RUB") == 60)
        #expect(try transaction.amount(in: "RUB") == 5_000)
        #expect(transaction.rateSnapshotData == saved)
        let decoded = try JSONDecoder().decode(CurrencyRateSnapshot.self, from: saved)
        #expect(decoded == transaction.lockedRates)
    }

    @Test("Spending reports provide converted totals with original transaction evidence")
    func spendingReportConversion() throws {
        let store = try CurrencyTestStore()
        _ = try store.transaction(amount: "100", currency: "BAM", rates: ["BAM": 1, "RUB": 50])
        _ = try store.transaction(amount: "50", currency: "RUB")
        let report = try SpendingDataStore(context: store.context, baseCurrency: "RUB")
            .report(startDate: "", endDate: "", kind: "expense", category: "all", search: "")
        #expect(report.currency == "RUB")
        #expect(report.totalExpense == "5050")
        #expect(report.matchingCount == 2)
        let largest = try #require(report.topTransactions.first)
        #expect(largest.amount == "5000")
        #expect(largest.originalAmount == "100")
        #expect(largest.originalCurrency == "BAM")
        #expect(largest.rateDate == "2026-10-01")
        #expect(report.categories.first?.expense == "5050")
    }

    @Test("Reports cannot silently omit a transaction whose rate is missing")
    func spendingReportMissingRate() throws {
        let store = try CurrencyTestStore()
        _ = try store.transaction(amount: "100", currency: "BAM")
        #expect(throws: MoneyError.self) {
            try SpendingDataStore(context: store.context, baseCurrency: "RUB")
                .report(startDate: "", endDate: "", kind: "expense", category: "all", search: "")
        }
    }

    @Test("Decimal point and comma are accepted without binary arithmetic", arguments: ["0.1", "0,1", " 0.1 "])
    func decimalInput(_ text: String) throws {
        #expect(try Money.parse(text) == Decimal(string: "0.1"))
    }

    @Test("Invalid or unsafe input is rejected", arguments: ["NaN", "inf", "-1", "1e5", "1,2,3", "", "1000000001", "0.1234567890"])
    func invalidInput(_ text: String) {
        #expect(throws: MoneyError.self) { try Money.parse(text) }
    }

    @Test("Persisted revisions detect already-saved edits, not just pending context changes")
    func savedRevision() throws {
        let store = try CurrencyTestStore()
        let transaction = try store.transaction(amount: "100", currency: "BAM", rates: ["BAM": 1, "RUB": 50])
        try store.context.save()
        let previous = TransactionRevision(transaction)
        transaction.note = "Edited elsewhere"
        try store.context.save()
        #expect(!store.context.hasChanges)
        #expect(previous != TransactionRevision(transaction))
    }

    @Test("Adding a manual target retains the already locked current-base conversion")
    func manualTargetRecovery() async throws {
        let store = try CurrencyTestStore()
        let transaction = try store.transaction(amount: "100", currency: "USD", rates: ["USD": 1, "RUB": 90])
        try store.context.save()
        let editor = AddExpenseViewModel(expenseObj: transaction, baseCurrency: "RUB")
        editor.conversionCurrency = "EUR"
        editor.useManualRate = true
        editor.manualRate = "0.9"
        await editor.saveTransaction(managedObjectContext: store.context)
        #expect(editor.closePresenter)
        #expect(!editor.showAlert)
        #expect(transaction.originalCurrency == "USD")
        #expect(transaction.originalDecimal == 100)
        #expect(try transaction.amount(in: "RUB") == 9_000)
        #expect(try transaction.amount(in: "EUR") == 90)
    }

    @Test("An editor rejects a persisted concurrent edit instead of overwriting it")
    func editorConcurrentChange() async throws {
        let store = try CurrencyTestStore()
        let transaction = try store.transaction(amount: "100", currency: "BAM", rates: ["BAM": 1, "RUB": 50])
        try store.context.save()
        let editor = AddExpenseViewModel(expenseObj: transaction, baseCurrency: "RUB")
        transaction.note = "Already saved elsewhere"
        try store.context.save()
        editor.useManualRate = true
        editor.manualRate = "50"
        editor.title = "Stale edit"
        await editor.saveTransaction(managedObjectContext: store.context)
        #expect(editor.showAlert)
        #expect(!editor.closePresenter)
        #expect(transaction.title == "Fixture")
        #expect(transaction.note == "Already saved elsewhere")
    }
}

/// These intentional integration fixtures use actual Core Data in isolated stores.
@MainActor
final class CurrencyTestStore {
    let coordinator: NSPersistentStoreCoordinator
    let context: NSManagedObjectContext

    init(version: String = "ExpensoV2") throws {
        let model = try Self.model(version: version)
        coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
    }

    static func model(version: String) throws -> NSManagedObjectModel {
        let directory = try #require(Bundle.main.url(forResource: "Expenso", withExtension: "momd"))
        return try #require(NSManagedObjectModel(contentsOf: directory.appendingPathComponent("\(version).mom")))
    }

    func transaction(amount: String, currency: String, rates: [String: Decimal]? = nil,
                     type: String = TRANS_TYPE_EXPENSE) throws -> ExpenseCD {
        let entity = try #require(coordinator.managedObjectModel.entitiesByName["ExpenseCD"])
        let transaction = ExpenseCD(entity: entity, insertInto: context)
        let decimal = try #require(Decimal(string: amount))
        transaction.amount = NSDecimalNumber(decimal: decimal).doubleValue
        transaction.amountText = amount
        transaction.currencyCode = currency
        transaction.title = "Fixture"
        transaction.tag = TRANS_TAG_FOOD
        transaction.type = type
        transaction.occuredOn = ISO8601DateFormatter().date(from: "2026-10-01T12:00:00Z")
        if let rates {
            transaction.rateSnapshotData = try JSONEncoder().encode(CurrencyRateSnapshot(
                date: "2026-10-01", rates: rates, source: "Fixture"))
        }
        return transaction
    }
}

@Suite("Base-currency review — isolated Core Data integration with mocked rates")
@MainActor
struct CurrencyChangeReviewTests {
    private func withDefaults(_ body: (UserDefaults) async throws -> Void) async throws {
        let name = "CurrencyChangeReviewTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.set("RUB", forKey: CurrencySettings.key)
        defer { defaults.removePersistentDomain(forName: name) }
        try await body(defaults)
    }

    private func fallback(_ requested: String) -> CurrencyRateSnapshot {
        CurrencyRateSnapshot(date: "2026-09-30", rates: ["USD": 1, "RUB": 90, "EUR": Decimal(string: "0.9")!],
            source: "https://rates.example/2026-09-30", requestedDate: requested)
    }

    @Test("Estimated rates are staged without ledger writes, then confirmed with originals intact")
    func confirmAndBackup() async throws {
        try await withDefaults { defaults in
            let store = try CurrencyTestStore()
            let transaction = try store.transaction(amount: "107745.90", currency: "RUB")
            try store.context.save()
            let originalDate = transaction.occuredOn
            var requests: [String] = []
            let settings = ExpenseSettingsViewModel(defaults: defaults) { day in
                requests.append(day)
                return self.fallback(day)
            }
            await settings.saveCurrency(currency: "EUR", context: store.context)
            #expect(settings.currencyChangeReview != nil)
            #expect(!store.context.hasChanges && transaction.rateSnapshotData == nil)
            #expect(defaults.string(forKey: CurrencySettings.key) == "RUB")
            #expect(settings.currency == "RUB")
            settings.confirmCurrencyChange()
            #expect(!settings.showAlert && settings.currencyChangeReview == nil)
            #expect(defaults.string(forKey: CurrencySettings.key) == "EUR")
            #expect(settings.currency == "EUR" && !store.context.hasChanges)
            #expect(transaction.amountText == "107745.90" && transaction.originalCurrency == "RUB")
            #expect(transaction.occuredOn == originalDate)
            let saved = try #require(transaction.lockedRates)
            #expect(saved == fallback("2026-10-01"))
            #expect(requests == ["2026-10-01"])
            let archive = try LedgerBackupService.capture(context: store.context, defaults: defaults)
            let restored = try LedgerBackupCodec.decode(LedgerBackupCodec.encode(archive))
            #expect(restored.records == archive.records)
            #expect(restored.preferences.baseCurrency == "EUR")
            let record = try #require(restored.records.first)
            #expect(record.rateSnapshotData == transaction.rateSnapshotData)
            let restoredRates = try #require(record.rateSnapshotData)
            #expect(try JSONDecoder().decode(CurrencyRateSnapshot.self, from: restoredRates) == saved)
        }
    }

    @Test("Cancel discards estimated plans without changing preferences or the ledger")
    func cancel() async throws {
        try await withDefaults { defaults in
            let store = try CurrencyTestStore()
            let transaction = try store.transaction(amount: "100", currency: "RUB")
            try store.context.save()
            let before = LedgerRecord(transaction)
            let settings = ExpenseSettingsViewModel(defaults: defaults) { self.fallback($0) }
            await settings.saveCurrency(currency: "EUR", context: store.context)
            #expect(settings.currencyChangeReview != nil)
            settings.cancelCurrencyChange()
            settings.confirmCurrencyChange()
            #expect(settings.currencyChangeReview == nil && !settings.showAlert)
            #expect(LedgerRecord(transaction) == before && !store.context.hasChanges)
            #expect(defaults.string(forKey: CurrencySettings.key) == "RUB")
        }
    }

    @Test("Confirmation rejects saved ledger edits and intervening base changes", arguments: [false, true])
    func interveningChange(_ changeBase: Bool) async throws {
        try await withDefaults { defaults in
            let store = try CurrencyTestStore()
            let transaction = try store.transaction(amount: "100", currency: "RUB")
            try store.context.save()
            let settings = ExpenseSettingsViewModel(defaults: defaults) { self.fallback($0) }
            await settings.saveCurrency(currency: "EUR", context: store.context)
            #expect(settings.currencyChangeReview != nil)
            if changeBase { defaults.set("USD", forKey: CurrencySettings.key) }
            else {
                transaction.note = "Saved after review"
                try store.context.save()
            }
            let beforeConfirm = LedgerRecord(transaction)
            settings.confirmCurrencyChange()
            #expect(settings.showAlert && settings.currencyChangeReview == nil)
            #expect(LedgerRecord(transaction) == beforeConfirm && !store.context.hasChanges)
            #expect(defaults.string(forKey: CurrencySettings.key) == (changeBase ? "USD" : "RUB"))
        }
    }

    @Test("Provider failure after another fetched row cannot partially write rates")
    func atomicProviderFailure() async throws {
        try await withDefaults { defaults in
            let store = try CurrencyTestStore()
            let first = try store.transaction(amount: "100", currency: "RUB")
            let second = try store.transaction(amount: "200", currency: "RUB")
            second.occuredOn = ISO8601DateFormatter().date(from: "2026-10-02T12:00:00Z")
            try store.context.save()
            let before = [LedgerRecord(first), LedgerRecord(second)]
            var calls = 0
            let settings = ExpenseSettingsViewModel(defaults: defaults) { day in
                calls += 1
                if calls == 2 { throw MoneyError.missingRate }
                return self.fallback(day)
            }
            await settings.saveCurrency(currency: "EUR", context: store.context)
            #expect(calls == 2 && settings.showAlert && settings.currencyChangeReview == nil)
            #expect([LedgerRecord(first), LedgerRecord(second)] == before)
            #expect(!store.context.hasChanges && defaults.string(forKey: CurrencySettings.key) == "RUB")
        }
    }

    @Test("Existing manual rates are never replaced, even when the requested pair is absent", arguments: [true, false])
    func manualRates(_ includesTarget: Bool) async throws {
        try await withDefaults { defaults in
            let store = try CurrencyTestStore()
            var rates: [String: Decimal] = ["USD": 1, "RUB": 91]
            if includesTarget { rates["EUR"] = Decimal(string: "0.85")! }
            let transaction = try store.transaction(amount: "100", currency: "USD")
            let manual = CurrencyRateSnapshot(date: "2026-10-01", rates: rates, source: "Manual bank rate")
            let data = try JSONEncoder().encode(manual)
            transaction.rateSnapshotData = data
            try store.context.save()
            var calls = 0
            let settings = ExpenseSettingsViewModel(defaults: defaults) { day in
                calls += 1
                return self.fallback(day)
            }
            await settings.saveCurrency(currency: "EUR", context: store.context)
            #expect(calls == 0 && transaction.rateSnapshotData == data)
            #expect(settings.currencyChangeReview == nil && !store.context.hasChanges)
            #expect(settings.showAlert == !includesTarget)
            #expect(defaults.string(forKey: CurrencySettings.key) == (includesTarget ? "EUR" : "RUB"))
        }
    }

    @Test("Transactions on the same requested day share one provider fetch")
    func sameDayFetch() async throws {
        try await withDefaults { defaults in
            let store = try CurrencyTestStore()
            let first = try store.transaction(amount: "100", currency: "RUB")
            let second = try store.transaction(amount: "200", currency: "RUB")
            try store.context.save()
            var calls: [String] = []
            let settings = ExpenseSettingsViewModel(defaults: defaults) { day in
                calls.append(day)
                return self.fallback(day)
            }
            await settings.saveCurrency(currency: "EUR", context: store.context)
            #expect(calls == ["2026-10-01"] && settings.currencyChangeReview != nil)
            #expect(first.rateSnapshotData == nil && second.rateSnapshotData == nil)
            settings.confirmCurrencyChange()
            #expect(calls.count == 1 && !settings.showAlert)
            #expect(first.lockedRates == fallback("2026-10-01"))
            #expect(second.lockedRates == first.lockedRates)
        }
    }

    @Test("Undecodable saved rates are preserved and never replaced by a provider response")
    func invalidSavedRateData() async throws {
        try await withDefaults { defaults in
            let store = try CurrencyTestStore()
            let transaction = try store.transaction(amount: "100", currency: "RUB")
            let invalidData = Data([0xff, 0x00, 0x42])
            transaction.rateSnapshotData = invalidData
            try store.context.save()
            let before = LedgerRecord(transaction)
            var calls = 0
            let settings = ExpenseSettingsViewModel(defaults: defaults) { day in
                calls += 1
                return self.fallback(day)
            }
            await settings.saveCurrency(currency: "EUR", context: store.context)
            #expect(settings.showAlert && settings.currencyChangeReview == nil)
            #expect(calls == 0 && transaction.rateSnapshotData == invalidData)
            #expect(LedgerRecord(transaction) == before && !store.context.hasChanges)
            #expect(settings.currency == "RUB")
            #expect(defaults.string(forKey: CurrencySettings.key) == "RUB")
        }
    }

    @Test("Cancellation after the provider returns aborts before staging or writing rates")
    func cancelledProviderResponse() async throws {
        try await withDefaults { defaults in
            let store = try CurrencyTestStore()
            let transaction = try store.transaction(amount: "100", currency: "RUB")
            try store.context.save()
            let before = LedgerRecord(transaction)
            var calls = 0
            let settings = ExpenseSettingsViewModel(defaults: defaults) { day in
                calls += 1
                // Cancel only the child operation, at the response boundary, without
                // timing sleeps or cancelling the test runner's own task.
                withUnsafeCurrentTask { $0?.cancel() }
                return self.fallback(day)
            }
            let operation = Task { @MainActor in
                await settings.saveCurrency(currency: "EUR", context: store.context)
            }
            await operation.value
            #expect(calls == 1 && operation.isCancelled)
            #expect(settings.currencyChangeReview == nil && !settings.isChangingCurrency)
            #expect(LedgerRecord(transaction) == before && !store.context.hasChanges)
            #expect(transaction.rateSnapshotData == nil && settings.currency == "RUB")
            #expect(defaults.string(forKey: CurrencySettings.key) == "RUB")
        }
    }
}

@Suite("Core Data currency migration — isolated SQLite integration")
@MainActor
struct CurrencyMigrationTests {
    @Test("V1 RUB records survive inferred V2 migration with all original data intact")
    func migrateExistingRUBLedger() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Fixture.sqlite")
        let oldModel = try CurrencyTestStore.model(version: "Expenso")
        let newModel = try CurrencyTestStore.model(version: "ExpensoV2")
        _ = try NSMappingModel.inferredMappingModel(forSourceModel: oldModel, destinationModel: newModel)
        let oldCoordinator = NSPersistentStoreCoordinator(managedObjectModel: oldModel)
        let oldStore = try oldCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
        let oldContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        oldContext.persistentStoreCoordinator = oldCoordinator
        let entity = try #require(oldModel.entitiesByName["ExpenseCD"])
        let record = NSManagedObject(entity: entity, insertInto: oldContext)
        let date = try #require(ISO8601DateFormatter().date(from: "2021-02-01T12:00:00Z"))
        let attachment = Data([0x01, 0x02, 0x03])
        record.setValuesForKeys(["amount": 123.45, "title": "Old RUB transaction", "note": "Keep this note",
                                "tag": TRANS_TAG_FOOD, "type": TRANS_TYPE_EXPENSE,
                                "occuredOn": date, "createdAt": date, "updatedAt": date, "imageAttached": attachment])
        try oldContext.save()
        oldContext.reset()
        try oldCoordinator.remove(oldStore)

        let newCoordinator = NSPersistentStoreCoordinator(managedObjectModel: newModel)
        let newStore = try newCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url,
            options: [NSMigratePersistentStoresAutomaticallyOption: true, NSInferMappingModelAutomaticallyOption: true])
        defer { try? newCoordinator.remove(newStore) }
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = newCoordinator
        let records = try context.fetch(NSFetchRequest<ExpenseCD>(entityName: "ExpenseCD"))
        #expect(records.count == 1)
        let migrated = try #require(records.first)
        #expect(migrated.amount == 123.45)
        #expect(migrated.originalDecimal == Decimal(string: "123.45"))
        #expect(migrated.originalCurrency == "RUB")
        #expect(migrated.currencyCode == nil)
        #expect(migrated.amountText == nil)
        #expect(migrated.rateSnapshotData == nil)
        #expect(migrated.title == "Old RUB transaction")
        #expect(migrated.note == "Keep this note")
        #expect(migrated.tag == TRANS_TAG_FOOD)
        #expect(migrated.type == TRANS_TYPE_EXPENSE)
        #expect(migrated.createdAt == date)
        #expect(migrated.updatedAt == date)
        #expect(migrated.occuredOn == date)
        #expect(migrated.imageAttached == attachment)
        #expect(try Money.total(records, base: "RUB") == Decimal(string: "123.45"))
    }
}
