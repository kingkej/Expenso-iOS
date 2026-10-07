import CoreData
import CryptoKit
import Foundation
import Testing
@testable import Expenso

@Suite("Payment methods — isolated storage integration")
@MainActor
struct PaymentMethodStorageTests {
    @Test("Saving and reloading preserves supported, unspecified, and unknown raw methods",
          arguments: [nil, "card", "crypto", "cash", "future-method"] as [String?])
    func saveReload(_ raw: String?) throws {
        let store = try CurrencyTestStore()
        let transaction = try store.transaction(amount: "0.85", currency: "BAM")
        transaction.paymentMethod = raw
        try store.context.save()
        let id = transaction.objectID
        store.context.reset()
        let reloaded = try #require(store.context.existingObject(with: id) as? ExpenseCD)
        #expect(reloaded.paymentMethod == raw)
        #expect(reloaded.paymentMethodValue == raw.flatMap(PaymentMethod.init(rawValue:)))
        #expect(LedgerRecord(reloaded).paymentMethod == raw)
        #expect(TransactionRevision(reloaded).paymentMethod == raw)
    }

    @Test("Legacy model access safely returns an unspecified method", arguments: ["Expenso", "ExpensoV2"])
    func legacyAccess(_ version: String) throws {
        let store = try CurrencyTestStore(version: version)
        let transaction = try LedgerStoreTransaction.insert(in: store.context)
        transaction.amount = 12
        #expect(!transaction.supportsPaymentMethod)
        #expect(transaction.paymentMethodValue == nil)
        #expect(LedgerRecord(transaction).paymentMethod == nil)
        #expect(TransactionRevision(transaction).paymentMethod == nil)
    }

    @Test("Payment changes are part of revision and undo conflicts")
    func paymentConflicts() throws {
        let store = try CurrencyTestStore()
        let transaction = try store.transaction(amount: "12", currency: "RUB")
        transaction.paymentMethod = "card"
        try store.context.save()
        let revision = TransactionRevision(transaction)
        let mutations = LedgerMutationService()
        try mutations.recategorize(ids: [transaction.objectID], category: TRANS_TAG_TRAVEL, context: store.context)
        transaction.paymentMethod = "cash"
        try store.context.save()
        #expect(TransactionRevision(transaction) != revision)
        do {
            try mutations.undo(context: store.context)
            Issue.record("Undo must retain the subsequent payment-method edit")
        } catch LedgerOperationError.undoConflict { }
        #expect(transaction.paymentMethod == "cash")
        #expect(transaction.tag == TRANS_TAG_TRAVEL)
    }

    @Test("V1 and V2 SQLite stores migrate to V3 without changing existing fields",
          arguments: ["Expenso", "ExpensoV2"])
    func migrateToV3(_ version: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("PaymentMigration.sqlite")
        let oldModel = try CurrencyTestStore.model(version: version)
        let oldCoordinator = NSPersistentStoreCoordinator(managedObjectModel: oldModel)
        let oldStore = try oldCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
        let oldContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        oldContext.persistentStoreCoordinator = oldCoordinator
        let transaction = try LedgerStoreTransaction.insert(in: oldContext)
        let date = Date(timeIntervalSinceReferenceDate: 12345.125)
        transaction.amount = 12.345
        transaction.title = "Legacy transaction"
        transaction.note = "Keep this note"
        transaction.type = TRANS_TYPE_EXPENSE
        transaction.tag = TRANS_TAG_FOOD
        transaction.createdAt = date
        transaction.updatedAt = date
        transaction.occuredOn = date
        transaction.imageAttached = Data([0, 1, 0xff])
        if transaction.supportsCurrencyMetadata {
            transaction.currencyCode = "BAM"
            transaction.amountText = "12.345"
            transaction.rateSnapshotData = Data([0x01, 0xff])
        }
        try oldContext.save()
        let before = LedgerRecord(transaction)
        oldContext.reset()
        try oldCoordinator.remove(oldStore)

        let model = try CurrencyTestStore.model(version: "ExpensoV3")
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let migratedStore = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url,
            options: [NSMigratePersistentStoresAutomaticallyOption: true, NSInferMappingModelAutomaticallyOption: true])
        defer { try? coordinator.remove(migratedStore) }
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let records = try LedgerStoreTransaction.records(in: context)
        #expect(records.count == 1)
        let migrated = try #require(records.first)
        #expect(migrated.supportsPaymentMethod)
        #expect(migrated.paymentMethod == nil)
        var after = LedgerRecord(migrated)
        after.id = before.id
        #expect(after == before)
    }

    @Test("Nonempty v1 and v2 archives without the new field keep their original checksum", arguments: [1, 2])
    func legacyArchiveChecksums(_ version: Int) async throws {
        // Independent dictionaries describe the old archive shape, avoiding today's LedgerRecord encoder.
        var preferences: [String: Any] = ["baseCurrency": "RUB", "accent": "original"]
        if version == 2 {
            preferences["categories"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CategoryCatalog.defaults))
        }
        let payload: [String: Any] = ["format": "ExpensoLedgerBackup", "version": version,
            "createdAt": 0, "preferences": preferences,
            "records": [["id": "legacy-row", "amount": 12.5, "title": "Legacy", "type": "EXPENSE"]]]
        let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let archive = try JSONSerialization.data(withJSONObject: ["payload": payload, "sha256": hash], options: [.sortedKeys])
        let decoded = try LedgerBackupCodec.decode(archive)
        #expect(decoded.version == version)
        #expect(decoded.records.count == 1)
        #expect(decoded.records.first?.paymentMethod == nil)
        #expect(decoded.records.first?.amount == 12.5)
        let store = try CurrencyTestStore()
        let existing = try store.transaction(amount: "99", currency: "RUB")
        existing.paymentMethod = "cash"
        try store.context.save()
        let defaultsName = "Expenso.LegacyPaymentRestore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: directory)
        }
        let recovery = try await LedgerBackupService.restore(decoded, context: store.context,
            defaults: defaults, recoveryDirectory: directory)
        let restored = try #require(LedgerStoreTransaction.records(in: store.context).first)
        #expect(restored.paymentMethod == nil)
        #expect(restored.amount == 12.5)
        #expect(try LedgerBackupCodec.decode(Data(contentsOf: recovery)).records.first?.paymentMethod == "cash")
    }

    @Test("Restoring a method into V2 rejects before writing recovery or changing rows")
    func rejectLossyRestore() async throws {
        let source = try CurrencyTestStore()
        let sourceRecord = try source.transaction(amount: "5", currency: "RUB")
        sourceRecord.paymentMethod = "future-method"
        try source.context.save()
        let target = try CurrencyTestStore(version: "ExpensoV2")
        _ = try target.transaction(amount: "10", currency: "RUB")
        try target.context.save()
        let defaultsName = "Expenso.PaymentRestore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let payload = try LedgerBackupService.capture(context: source.context, defaults: defaults)
        let before = try LedgerBackupService.capture(context: target.context, defaults: defaults)
        var wroteRecovery = false
        do {
            try await LedgerBackupService.restore(payload, context: target.context, defaults: defaults,
                recoveryWriter: { _, directory in
                    wroteRecovery = true
                    return directory.appendingPathComponent("Unexpected.expenso")
                })
            Issue.record("A V2 store cannot preserve payment metadata")
        } catch LedgerBackupError.schemaMismatch { }
        #expect(!wroteRecovery)
        #expect(try LedgerBackupService.capture(context: target.context, defaults: defaults).records == before.records)
        #expect(!target.context.hasChanges)
    }

    @Test("CSV appends a payment column, including blank values and escaped neighboring notes")
    func csvPaymentColumn() {
        let viewModel = ExpenseSettingsViewModel()
        let card = ExpenseCSVModel()
        card.title = "Imported"
        card.note = "Receipt, \"card\""
        card.paymentMethod = "Card"
        let unspecified = ExpenseCSVModel()
        unspecified.title = "Manual"
        viewModel.csvModelArr = [card, unspecified]
        let output = viewModel.csvContents().split(separator: "\n", omittingEmptySubsequences: false)
        #expect(output[0].hasSuffix(",Payment Method"))
        #expect(output[1].hasSuffix(",\"Receipt, \"\"card\"\"\",\"Card\""))
        #expect(output[2].hasSuffix(",\"\",\"\""))
    }
}
