import CoreData
import CryptoKit
import Foundation
import Testing
@testable import Expenso

@Suite("Personal categories — isolated preferences and ledger integration")
@MainActor
struct CategoryCatalogTests {
    private func custom() -> ExpenseCategory {
        .init(id: "custom." + UUID().uuidString.lowercased(), name: "Coffee", symbol: "cup.and.saucer.fill")
    }

    @Test("Renaming, ordering and archiving preserve identity and survive reload")
    func persistence() throws {
        let suite = "Expenso.Categories.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        var items = CategoryCatalog.defaults
        let id = items[0].id
        items[0].name = "Public Transport"
        items[0].symbol = "car.fill"
        items[0].isArchived = true
        items.insert(custom(), at: 0)
        try CategoryCatalog.save(items, defaults: preferences)
        #expect(CategoryCatalog.load(defaults: preferences) == items)
        #expect(items[1].id == id)
        #expect(!CategoryCatalog.choices(in: items).contains { $0.id == id })
        #expect(CategoryCatalog.choices(in: items, preserving: id).contains { $0.id == id })
        let legacy = CategoryCatalog.choices(in: items, preserving: "legacy").last
        #expect(legacy?.id == "legacy")
        #expect(legacy?.isArchived == true)
    }

    @Test("Duplicate names, invalid metadata, missing built-ins and archiving everything fail")
    func validation() throws {
        var items = CategoryCatalog.defaults + [custom()]
        items[items.count - 1].name = "FóOD"
        #expect(throws: CategoryCatalogError.self) { try CategoryCatalog.validate(items) }
        items = CategoryCatalog.defaults
        items[0].name = "\nBad"
        #expect(throws: CategoryCatalogError.self) { try CategoryCatalog.validate(items) }
        items = CategoryCatalog.defaults
        items[0].symbol = "not.a.symbol"
        #expect(throws: CategoryCatalogError.self) { try CategoryCatalog.validate(items) }
        #expect(throws: CategoryCatalogError.self) { try CategoryCatalog.validate(Array(CategoryCatalog.defaults.dropFirst())) }
        items = CategoryCatalog.defaults.map { var item = $0; item.isArchived = true; return item }
        #expect(throws: CategoryCatalogError.self) { try CategoryCatalog.validate(items) }
        #expect(CategoryCatalog.decode(Data("invalid".utf8)) == CategoryCatalog.defaults)
    }

    @Test("Custom and archived categories retain exact report totals and reversible reassignment")
    func ledgerIntegration() throws {
        let suite = "Expenso.Categories.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        var coffee = custom()
        try CategoryCatalog.save(CategoryCatalog.defaults + [coffee], defaults: preferences)
        let store = try CurrencyTestStore()
        let transaction = try store.transaction(amount: "12.345", currency: "BAM", rates: ["BAM": 1, "RUB": 50])
        try store.context.save()
        let original = LedgerRecord(transaction)
        let mutations = LedgerMutationService(categoryDefaults: preferences)
        try mutations.recategorize(ids: [transaction.objectID], category: coffee.id, context: store.context)
        #expect(transaction.tag == coffee.id)
        #expect(transaction.rateSnapshotData == original.rateSnapshotData)
        let reports = SpendingDataStore(context: store.context, baseCurrency: "RUB", categoryDefaults: preferences)
        coffee.name = "Cafés"
        coffee.isArchived = true
        try CategoryCatalog.save(CategoryCatalog.defaults + [coffee], defaults: preferences)
        let report = try reports.report(startDate: "", endDate: "", kind: "all", category: coffee.id, search: "")
        #expect(report.totalExpense == "617.25")
        #expect(report.matchingCount == 1)
        #expect(report.categories.first?.category == coffee.id)
        #expect(throws: LedgerOperationError.self) {
            try mutations.recategorize(ids: [transaction.objectID], category: coffee.id, context: store.context)
        }
        try mutations.undo(context: store.context)
        #expect(LedgerRecord(transaction) == original)
    }

    @Test("Complete backups restore custom metadata and recover previous category settings")
    func backupIntegration() async throws {
        let suite = "Expenso.Categories.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = try CurrencyTestStore()
        let coffee = custom()
        let originalCatalog = CategoryCatalog.defaults + [coffee]
        try CategoryCatalog.save(originalCatalog, defaults: preferences)
        let transaction = try store.transaction(amount: "10", currency: "RUB")
        transaction.tag = coffee.id
        try store.context.save()
        let payload = try LedgerBackupCodec.decode(LedgerBackupCodec.encode(
            LedgerBackupService.capture(context: store.context, defaults: preferences)))
        #expect(payload.version == 2)
        try CategoryCatalog.save(CategoryCatalog.defaults, defaults: preferences)
        let recovery = try await LedgerBackupService.restore(payload, context: store.context,
            defaults: preferences, recoveryDirectory: directory)
        #expect(CategoryCatalog.load(defaults: preferences) == originalCatalog)
        #expect(try LedgerStoreTransaction.records(in: store.context).first?.tag == coffee.id)
        let previous = try LedgerBackupCodec.decode(Data(contentsOf: recovery))
        #expect(previous.preferences.categories == CategoryCatalog.defaults)
    }

    @Test("Original v1 JSON without category metadata still passes its original checksum")
    func originalV1Compatibility() throws {
        // A literal independent fixture verifies compatibility, rather than encoding with today's model.
        let payloadJSON = "{\"createdAt\":0,\"format\":\"ExpensoLedgerBackup\",\"preferences\":{\"accent\":\"original\",\"baseCurrency\":\"RUB\"},\"records\":[],\"version\":1}"
        let hash = SHA256.hash(data: Data(payloadJSON.utf8)).map { String(format: "%02x", $0) }.joined()
        let archive = Data("{\"payload\":\(payloadJSON),\"sha256\":\"\(hash)\"}".utf8)
        let decoded = try LedgerBackupCodec.decode(archive)
        #expect(decoded.version == 1)
        #expect(decoded.preferences.categories == nil)
        #expect(decoded.records.isEmpty)
    }

    @Test("A stale editor cannot overwrite a concurrent archive; unrelated ordering is retained")
    func concurrentEdit() throws {
        let original = CategoryCatalog.defaults[0]
        var rename = original
        rename.name = "Public Transport"
        var latest = CategoryCatalog.defaults
        latest[0].isArchived = true
        #expect(throws: CategoryCatalogError.self) {
            try CategoryCatalog.applying(rename, replacing: original, in: latest)
        }
        latest = Array(CategoryCatalog.defaults.reversed())
        let merged = try CategoryCatalog.applying(rename, replacing: original, in: latest)
        #expect(merged.last?.name == "Public Transport")
        #expect(merged.map(\.id) == latest.map(\.id))
    }

    @Test("Transaction editors preserve archived and legacy tags but reject newly assigning archived tags")
    func editorCategories() async throws {
        let suite = "Expenso.Categories.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        var items = CategoryCatalog.defaults
        items[0].isArchived = true
        try CategoryCatalog.save(items, defaults: preferences)
        let store = try CurrencyTestStore()
        for tag in [items[0].id, "legacy-tag"] {
            let transaction = try store.transaction(amount: "10", currency: "RUB")
            transaction.tag = tag
            try store.context.save()
            let editor = AddExpenseViewModel(expenseObj: transaction, baseCurrency: "RUB", categoryDefaults: preferences)
            editor.note = "Edited note"
            await editor.saveTransaction(managedObjectContext: store.context)
            #expect(!editor.showAlert)
            #expect(transaction.tag == tag)
            #expect(transaction.note == "Edited note")
        }
        let editor = AddExpenseViewModel(baseCurrency: "RUB", categoryDefaults: preferences)
        #expect(editor.selectedTag == items[1].id)
        editor.title = "New expense"
        editor.amount = "10"
        editor.selectedTag = items[0].id
        await editor.saveTransaction(managedObjectContext: store.context)
        #expect(editor.showAlert)
        #expect(try LedgerStoreTransaction.records(in: store.context).count == 2)
    }

    @Test("Restoring v1 resets categories to built-ins and its recovery contains the previous catalog")
    func restoreV1() async throws {
        let suite = "Expenso.Categories.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = try CurrencyTestStore()
        let previous = CategoryCatalog.defaults + [custom()]
        try CategoryCatalog.save(previous, defaults: preferences)
        var settings = LedgerBackupPreferences(defaults: preferences)
        settings.categories = nil
        let payload = LedgerBackupPayload(format: LedgerBackupCodec.format, version: 1,
            createdAt: Date(), preferences: settings, records: [])
        let recovery = try await LedgerBackupService.restore(payload, context: store.context,
            defaults: preferences, recoveryDirectory: directory)
        #expect(CategoryCatalog.load(defaults: preferences) == CategoryCatalog.defaults)
        #expect(try LedgerBackupCodec.decode(Data(contentsOf: recovery)).preferences.categories == previous)
    }
}
