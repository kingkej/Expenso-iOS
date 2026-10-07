import CoreData
import Foundation
import Testing
@testable import Expenso

@MainActor
private struct BackupTestPreferences {
    let name = "Expenso.BackupTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    init() throws {
        defaults = try #require(UserDefaults(suiteName: name))
        defaults.set("RUB", forKey: CurrencySettings.key)
        defaults.set(AppAccent.teal.rawValue, forKey: AppAccent.storageKey)
    }
    func cleanup() { defaults.removePersistentDomain(forName: name) }
}

@Suite("Complete backups — isolated Core Data integration")
@MainActor
struct LedgerBackupTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func fixture(_ store: CurrencyTestStore) throws -> ExpenseCD {
        let record = try store.transaction(amount: "123.456789", currency: "BAM", rates: ["BAM": 1, "RUB": 48])
        record.title = "Receipt \"fixture\" 🧾"
        record.note = "First line\nSecond line"
        record.imageAttached = Data([0, 1, 2, 0xff])
        record.createdAt = Date(timeIntervalSinceReferenceDate: 12345.123456789)
        record.updatedAt = Date(timeIntervalSinceReferenceDate: 22345.987654321)
        record.paymentMethod = PaymentMethod.card.rawValue
        return record
    }

    @Test("Archive encoding preserves every field, signed legacy amounts, optional metadata and raw bytes")
    func losslessArchive() throws {
        let store = try CurrencyTestStore()
        let preferences = try BackupTestPreferences()
        defer { preferences.cleanup() }
        _ = try fixture(store)
        let legacy = try LedgerStoreTransaction.insert(in: store.context)
        legacy.amount = -15.125 // Archival snapshots preserve pre-redesign input; forms still reject it.
        legacy.title = nil
        legacy.tag = "Unknown old tag"
        legacy.type = "Unknown old type"
        legacy.rateSnapshotData = Data([0xff, 0x00]) // Preserve malformed old bytes, never silently repair.
        legacy.paymentMethod = "Unknown future method"
        try store.context.save()
        let payload = try LedgerBackupService.capture(context: store.context, defaults: preferences.defaults)
        let decoded = try LedgerBackupCodec.decode(LedgerBackupCodec.encode(payload))
        #expect(decoded == payload)
        #expect(decoded.records.count == 2)
        #expect(decoded.records.contains { $0.amount == -15.125 && $0.currencyCode == nil && $0.amountText == nil })
    }

    @Test("Whole-ledger replacement restores originals/images/rates and first creates a complete recovery file")
    func restoreRoundTrip() async throws {
        let source = try CurrencyTestStore()
        let target = try CurrencyTestStore()
        let preferences = try BackupTestPreferences()
        defer { preferences.cleanup() }
        _ = try fixture(source)
        try source.context.save()
        let payload = try LedgerBackupService.capture(context: source.context, defaults: preferences.defaults)
        let previousRecord = try target.transaction(amount: "55", currency: "RUB")
        previousRecord.paymentMethod = PaymentMethod.crypto.rawValue
        try target.context.save()
        let before = try LedgerBackupService.capture(context: target.context, defaults: preferences.defaults)
        preferences.defaults.set(true, forKey: UD_USE_BIOMETRIC)
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recovery = try await LedgerBackupService.restore(payload, context: target.context,
            defaults: preferences.defaults, recoveryDirectory: root)
        let previous = try LedgerBackupCodec.decode(Data(contentsOf: recovery))
        #expect(previous.records == before.records)
        #expect(previous.preferences == before.preferences)
        let restored = try #require(LedgerStoreTransaction.records(in: target.context).first)
        var snapshot = LedgerRecord(restored)
        snapshot.id = try #require(payload.records.first).id // Replacement deliberately allocates new object IDs.
        #expect(snapshot == payload.records.first)
        #expect(try restored.amount(in: "RUB") == Decimal(string: "5925.93"))
        #expect(preferences.defaults.bool(forKey: UD_USE_BIOMETRIC))
        #expect(preferences.defaults.string(forKey: AppAccent.storageKey) == AppAccent.teal.rawValue)
        #expect(!target.context.hasChanges)
        // Restoring again replaces rather than appends/duplicates the same archive.
        let secondRecovery = try await LedgerBackupService.restore(payload, context: target.context,
            defaults: preferences.defaults, recoveryDirectory: root)
        #expect(try LedgerStoreTransaction.records(in: target.context).count == 1)
        #expect(!FileManager.default.fileExists(atPath: recovery.path))
        #expect(try LedgerBackupService.latestRecovery(defaults: preferences.defaults, recoveryDirectory: root) == secondRecovery)
        #expect(try LedgerBackupCodec.decode(Data(contentsOf: secondRecovery)).records.count == 1)
    }

    @Test("An edit saved while recovery is preparing prevents replacement")
    func interveningEdit() async throws {
        let store = try CurrencyTestStore()
        let preferences = try BackupTestPreferences()
        defer { preferences.cleanup() }
        let record = try store.transaction(amount: "10", currency: "RUB")
        try store.context.save()
        let payload = try LedgerBackupService.capture(context: store.context, defaults: preferences.defaults)
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        // Intentional Core Data integration with mocked recovery IO as the suspension boundary.
        do {
            try await LedgerBackupService.restore(payload, context: store.context, defaults: preferences.defaults,
                recoveryDirectory: root, recoveryWriter: { before, directory in
                    let recovery = try await LedgerBackupIO.shared.writeRecovery(before, directory: directory)
                    record.note = "A saved intervening edit"
                    try store.context.save()
                    return recovery
                })
            Issue.record("Restore should reject an intervening saved edit")
        } catch LedgerBackupError.ledgerChanged { }
        #expect(record.note == "A saved intervening edit")
        #expect(try LedgerStoreTransaction.records(in: store.context).count == 1)
        #expect(!store.context.hasChanges)
        #expect(try LedgerBackupService.latestRecovery(defaults: preferences.defaults, recoveryDirectory: root) != nil)
    }

    @Test("Cancellation after recovery preparation leaves the current ledger intact")
    func cancelledRestore() async throws {
        let store = try CurrencyTestStore()
        let preferences = try BackupTestPreferences()
        defer { preferences.cleanup() }
        _ = try store.transaction(amount: "10", currency: "RUB")
        try store.context.save()
        let payload = try LedgerBackupService.capture(context: store.context, defaults: preferences.defaults)
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Task { @MainActor in
            try await LedgerBackupService.restore(payload, context: store.context, defaults: preferences.defaults,
                recoveryDirectory: root, recoveryWriter: { before, directory in
                    let recovery = try await LedgerBackupIO.shared.writeRecovery(before, directory: directory)
                    withUnsafeCurrentTask { $0?.cancel() }
                    return recovery
                })
        }
        do { _ = try await task.value; Issue.record("Restore should honor cancellation before writing") }
        catch is CancellationError { }
        #expect(try LedgerBackupService.capture(context: store.context, defaults: preferences.defaults).records == payload.records)
        #expect(!store.context.hasChanges)
        #expect(try LedgerBackupService.latestRecovery(defaults: preferences.defaults, recoveryDirectory: root) != nil)
    }

    @Test("A failed recovery write preserves the previous reachable archive")
    func previousRecoverySurvivesWriteFailure() async throws {
        let store = try CurrencyTestStore()
        let preferences = try BackupTestPreferences()
        defer { preferences.cleanup() }
        _ = try fixture(store)
        try store.context.save()
        let before = try LedgerBackupService.capture(context: store.context, defaults: preferences.defaults)
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = try await LedgerBackupIO.shared.writeRecovery(before, directory: root)
        preferences.defaults.set(previous.lastPathComponent, forKey: LedgerBackupService.recoveryFilenameKey)
        do {
            try await LedgerBackupService.restore(before, context: store.context, defaults: preferences.defaults,
                recoveryDirectory: root, recoveryWriter: { _, _ in throw CocoaError(.fileWriteNoPermission) })
            Issue.record("A failed recovery write must stop restore")
        } catch { }
        #expect(try LedgerBackupService.latestRecovery(defaults: preferences.defaults, recoveryDirectory: root) == previous)
        #expect(try LedgerBackupCodec.decode(Data(contentsOf: previous)) == before)
        #expect(try LedgerBackupService.capture(context: store.context, defaults: preferences.defaults).records == before.records)
    }

    @Test("Recovery pruning preserves unrelated files and symlinks", arguments: [false, true])
    func recoveryPrunesOnlyManagedFiles(_ symlink: Bool) async throws {
        let store = try CurrencyTestStore()
        let preferences = try BackupTestPreferences()
        defer { preferences.cleanup() }
        let payload = try LedgerBackupService.capture(context: store.context, defaults: preferences.defaults)
        let root = directory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let unrelated = root.appendingPathComponent("Unrelated.expenso")
        let bytes = Data("Keep this file".utf8)
        try bytes.write(to: unrelated)
        let old = root.appendingPathComponent(symlink ? "Recovery-\(UUID().uuidString).expenso" : "Recovery-personal.expenso")
        if symlink {
            try FileManager.default.createSymbolicLink(at: old, withDestinationURL: unrelated)
        } else { try bytes.write(to: old) }
        preferences.defaults.set(old.lastPathComponent, forKey: LedgerBackupService.recoveryFilenameKey)
        let recovery = try await LedgerBackupService.restore(payload, context: store.context,
            defaults: preferences.defaults, recoveryDirectory: root)
        #expect(try Data(contentsOf: old) == bytes)
        #expect(try Data(contentsOf: unrelated) == bytes)
        #expect(try LedgerBackupService.latestRecovery(defaults: preferences.defaults, recoveryDirectory: root) == recovery)
    }

    @Test("An injected writer cannot publish an archive outside the recovery directory")
    func recoveryWriterOutsideDirectory() async throws {
        let store = try CurrencyTestStore()
        let preferences = try BackupTestPreferences()
        defer { preferences.cleanup() }
        let payload = try LedgerBackupService.capture(context: store.context, defaults: preferences.defaults)
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = try await LedgerBackupIO.shared.writeRecovery(payload, directory: root)
        preferences.defaults.set(previous.lastPathComponent, forKey: LedgerBackupService.recoveryFilenameKey)
        let outside = try await LedgerBackupIO.shared.writeRecovery(payload, directory: root.appendingPathComponent("Other"))
        do {
            try await LedgerBackupService.restore(payload, context: store.context, defaults: preferences.defaults,
                recoveryDirectory: root, recoveryWriter: { _, _ in outside })
            Issue.record("An outside recovery file must not be published")
        } catch LedgerBackupError.invalidFile { }
        #expect(try LedgerBackupService.latestRecovery(defaults: preferences.defaults, recoveryDirectory: root) == previous)
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test("Malformed/future archives and duplicate snapshot IDs fail before writing")
    func invalidArchives() throws {
        let store = try CurrencyTestStore()
        let preferences = try BackupTestPreferences()
        defer { preferences.cleanup() }
        _ = try fixture(store)
        try store.context.save()
        let payload = try LedgerBackupService.capture(context: store.context, defaults: preferences.defaults)
        #expect(throws: LedgerBackupError.self) { try LedgerBackupCodec.decode(Data("CSV,not,backup".utf8)) }
        let future = LedgerBackupPayload(format: payload.format, version: payload.version + 1,
            createdAt: payload.createdAt, preferences: payload.preferences, records: payload.records)
        #expect(throws: LedgerBackupError.self) { try LedgerBackupCodec.encode(future) }
        let duplicate = LedgerBackupPayload(format: payload.format, version: payload.version,
            createdAt: payload.createdAt, preferences: payload.preferences, records: payload.records + payload.records)
        #expect(throws: LedgerBackupError.self) { try LedgerBackupCodec.encode(duplicate) }
    }

    @Test("A changed payload fails the checksum even if it still decodes as a valid ledger")
    func corruption() throws {
        let store = try CurrencyTestStore()
        let preferences = try BackupTestPreferences()
        defer { preferences.cleanup() }
        _ = try fixture(store)
        try store.context.save()
        let payload = try LedgerBackupService.capture(context: store.context, defaults: preferences.defaults)
        let data = try LedgerBackupCodec.encode(payload)
        var envelope = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var alteredPayload = try #require(envelope["payload"] as? [String: Any])
        var records = try #require(alteredPayload["records"] as? [[String: Any]])
        records[0]["title"] = "Changed without recomputing checksum"
        alteredPayload["records"] = records
        envelope["payload"] = alteredPayload
        let tampered = try JSONSerialization.data(withJSONObject: envelope)
        #expect(throws: LedgerBackupError.self) { try LedgerBackupCodec.decode(tampered) }
        #expect(try LedgerStoreTransaction.records(in: store.context).first?.title == "Receipt \"fixture\" 🧾")
    }

    @Test("Pending editor changes prevent restore and are never rolled back")
    func pendingEdits() async throws {
        let store = try CurrencyTestStore()
        let preferences = try BackupTestPreferences()
        defer { preferences.cleanup() }
        let record = try fixture(store)
        try store.context.save()
        let payload = try LedgerBackupService.capture(context: store.context, defaults: preferences.defaults)
        record.note = "Unsaved user work"
        let root = directory()
        do {
            try await LedgerBackupService.restore(payload, context: store.context,
                defaults: preferences.defaults, recoveryDirectory: root)
            Issue.record("Restore should reject pending work")
        } catch { #expect(error is LedgerOperationError) }
        #expect(record.note == "Unsaved user work")
        #expect(store.context.hasChanges)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("Failure to write a recovery file prevents all ledger and preference changes")
    func recoveryWriteFailure() async throws {
        let store = try CurrencyTestStore()
        let preferences = try BackupTestPreferences()
        defer { preferences.cleanup() }
        _ = try fixture(store)
        try store.context.save()
        let before = try LedgerBackupService.capture(context: store.context, defaults: preferences.defaults)
        let empty = LedgerBackupPayload(format: before.format, version: before.version,
            createdAt: before.createdAt, preferences: before.preferences, records: [])
        let notADirectory = directory()
        try Data([1]).write(to: notADirectory)
        defer { try? FileManager.default.removeItem(at: notADirectory) }
        do {
            try await LedgerBackupService.restore(empty, context: store.context,
                defaults: preferences.defaults, recoveryDirectory: notADirectory)
            Issue.record("Restore must not proceed without recovery")
        } catch { }
        let after = try LedgerBackupService.capture(context: store.context, defaults: preferences.defaults)
        #expect(after.records == before.records)
        #expect(after.preferences == before.preferences)
        #expect(!store.context.hasChanges)
    }

    @Test("A read-only SQLite save failure leaves original rows intact — atomic persistence integration")
    func atomicSaveFailure() async throws {
        let root = directory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: try CurrencyTestStore.model(version: "ExpensoV2"))
        let url = root.appendingPathComponent("ReadOnly.sqlite")
        let originalStore = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let record = try LedgerStoreTransaction.insert(in: context)
        record.title = "Existing SQLite row"
        record.amount = 42
        record.type = TRANS_TYPE_EXPENSE
        try context.save()
        context.reset()
        try coordinator.remove(originalStore)
        let readOnly = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url,
            options: [NSReadOnlyPersistentStoreOption: true])
        defer { try? coordinator.remove(readOnly) }
        let preferences = try BackupTestPreferences()
        defer { preferences.cleanup() }
        let before = try LedgerBackupService.capture(context: context, defaults: preferences.defaults)
        let empty = LedgerBackupPayload(format: before.format, version: before.version,
            createdAt: before.createdAt, preferences: before.preferences, records: [])
        do {
            try await LedgerBackupService.restore(empty, context: context,
                defaults: preferences.defaults, recoveryDirectory: root.appendingPathComponent("Recovery"))
            Issue.record("Read-only store must fail its save")
        } catch { }
        #expect(try LedgerStoreTransaction.records(in: context).count == 1)
        #expect(try LedgerStoreTransaction.records(in: context).first?.title == "Existing SQLite row")
        #expect(!context.hasChanges)
        let recovery = try #require(try LedgerBackupService.latestRecovery(defaults: preferences.defaults,
            recoveryDirectory: root.appendingPathComponent("Recovery")))
        #expect(try LedgerBackupCodec.decode(Data(contentsOf: recovery)).records == before.records)
    }
}
