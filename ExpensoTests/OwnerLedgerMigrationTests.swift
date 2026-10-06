import Foundation
import CoreData
import Testing
@testable import Expenso

private final class OwnerCSVFixtureBundleMarker: NSObject { }
private let ownerCSVFixtureURL = Bundle(for: OwnerCSVFixtureBundleMarker.self)
    .url(forResource: "OwnerLedgerVerification", withExtension: "json")

/// Intentional SQLite integration test. Private fixture is supplied only for
/// approved local verification and is never included in the shipping app.
@Suite("Owner CSV ledger — disposable migration")
@MainActor
struct OwnerLedgerMigrationTests {
    private struct Fixture: Decodable {
        let records: [Row]
        struct Row: Decodable {
            let title: String
            let amount: String
            let type: String
            let tag: String
            let date: String
            let note: String
        }
    }

    @Test("All exported RUB transactions survive V1 to V2 unchanged",
          .enabled(if: ownerCSVFixtureURL != nil, "Private CSV fixture is supplied only for approved local verification"))
    func migrateExportedLedger() throws {
        let fixtureURL = try #require(ownerCSVFixtureURL)
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
        let rows = fixture.records
        #expect(!rows.isEmpty)
        let expectedExpenses = rows.filter { $0.type == TRANS_TYPE_EXPENSE }
        let expectedIncomes = rows.filter { $0.type == TRANS_TYPE_INCOME }
        let expectedExpenseTotal = try expectedExpenses.reduce(Decimal.zero) { total, row in
            total + (try #require(Decimal(string: row.amount, locale: Locale(identifier: "en_US_POSIX"))))
        }
        let expectedIncomeTotal = try expectedIncomes.reduce(Decimal.zero) { total, row in
            total + (try #require(Decimal(string: row.amount, locale: Locale(identifier: "en_US_POSIX"))))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("OwnerFixture.sqlite")
        let oldModel = try CurrencyTestStore.model(version: "Expenso")
        let newModel = try CurrencyTestStore.model(version: "ExpensoV2")
        let oldCoordinator = NSPersistentStoreCoordinator(managedObjectModel: oldModel)
        let oldStore = try oldCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
        let oldContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        oldContext.persistentStoreCoordinator = oldCoordinator
        let entity = try #require(oldModel.entitiesByName["ExpenseCD"])
        let dateParser = ISO8601DateFormatter()
        for (index, row) in rows.enumerated() {
            let record = NSManagedObject(entity: entity, insertInto: oldContext)
            let amount = try #require(Double(row.amount))
            let date = try #require(dateParser.date(from: row.date))
            // CSV has no creation/update timestamps. Synthetic, unique timestamps
            // establish a stable row order and also verify these fields migrate.
            let created = Date(timeIntervalSince1970: Double(index))
            record.setValuesForKeys(["title": row.title, "amount": amount, "type": row.type,
                "tag": row.tag, "occuredOn": date, "note": row.note,
                "createdAt": created, "updatedAt": created])
        }
        try oldContext.save()
        oldContext.reset()
        try oldCoordinator.remove(oldStore)

        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: newModel)
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url,
            options: [NSMigratePersistentStoresAutomaticallyOption: true, NSInferMappingModelAutomaticallyOption: true])
        defer { try? coordinator.remove(store) }
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let request = NSFetchRequest<ExpenseCD>(entityName: "ExpenseCD")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        let migrated = try context.fetch(request)
        #expect(migrated.count == rows.count)
        guard migrated.count == rows.count else { return }
        for (index, pair) in zip(rows, migrated).enumerated() {
            let (row, record) = pair
            #expect(record.title == row.title)
            #expect(record.amount == Double(row.amount))
            #expect(record.originalDecimal == Decimal(string: row.amount, locale: Locale(identifier: "en_US_POSIX")))
            #expect(record.type == row.type)
            #expect(record.tag == row.tag)
            #expect(record.occuredOn == dateParser.date(from: row.date))
            #expect(record.note == row.note)
            #expect(record.createdAt == Date(timeIntervalSince1970: Double(index)))
            #expect(record.updatedAt == record.createdAt)
            #expect(record.imageAttached == nil) // CSV does not carry attachments.
            #expect(record.originalCurrency == "RUB")
            #expect(record.currencyCode == nil)
            #expect(record.amountText == nil)
            #expect(record.rateSnapshotData == nil)
        }
        let expenses = migrated.filter { $0.type == TRANS_TYPE_EXPENSE }
        let incomes = migrated.filter { $0.type == TRANS_TYPE_INCOME }
        #expect(expenses.count == expectedExpenses.count)
        #expect(incomes.count == expectedIncomes.count)
        #expect(try Money.total(expenses, base: "RUB") == expectedExpenseTotal)
        #expect(try Money.total(incomes, base: "RUB") == expectedIncomeTotal)
        #expect(try Money.total(migrated, base: "RUB", balance: true) == expectedIncomeTotal - expectedExpenseTotal)
        #expect(!context.hasChanges)
    }
}
