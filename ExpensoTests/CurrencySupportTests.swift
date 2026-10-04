import Foundation
import CoreData
import Testing
@testable import Expenso

@Suite("Currency calculations")
@MainActor
struct CurrencySupportTests {
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
