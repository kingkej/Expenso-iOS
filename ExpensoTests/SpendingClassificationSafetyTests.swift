import Foundation
import CoreData
import Testing
@testable import Expenso

@MainActor private final class SafetyClassificationKey: OpenRouterKeyStore {
    private var value: String? = "sk-or-isolated-test"
    func read() throws -> String? { value }
    func save(_ value: String) throws { self.value = value }
    func delete() throws { value = nil }
}

/// The completion executes a main-actor mutation before returning its response.
/// This deterministic suspension boundary replaces timers, sleeps and live requests.
@MainActor private final class SafetyClassificationCompletion {
    private(set) var batches: [[String]] = []
    var onReply: ((Int) throws -> Void)?

    func reply(_ messages: [OpenRouterMessage]) throws -> String {
        let content = try #require(messages.last?.content)
        let rows = try #require(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [[String: String]])
        batches.append(rows.compactMap { $0["title"] })
        try onReply?(batches.count)
        let items = try rows.map { row -> [String: Any] in
            ["id": try #require(row["id"]), "label": "Accommodation", "confidence": 0.95]
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["items": items]), as: UTF8.self)
    }
}

@MainActor private final class SafetyClassificationFixture {
    let name: String
    let defaults: UserDefaults
    let directory: URL
    let ledger: CurrencyTestStore
    let completion: SafetyClassificationCompletion
    let store: SpendingClassificationStore
    var fileURL: URL { directory.appendingPathComponent("types.json") }

    init(corrupted: Data? = nil, blockedDirectory: Bool = false) throws {
        let name = "SpendingClassificationSafety." + UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = try #require(UserDefaults(suiteName: name))
        let responder = SafetyClassificationCompletion()
        self.name = name
        self.directory = directory
        self.defaults = defaults
        self.completion = responder
        defaults.set(true, forKey: SpendingClassificationStore.enabledKey)
        ledger = try CurrencyTestStore()
        if blockedDirectory {
            try Data("not a directory".utf8).write(to: directory)
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let corrupted { try corrupted.write(to: directory.appendingPathComponent("types.json")) }
        }
        let settings = OpenRouterSettings(defaults: defaults, keychain: SafetyClassificationKey())
        store = SpendingClassificationStore(defaults: defaults,
            fileURL: directory.appendingPathComponent("types.json"), settings: settings,
            completion: { _, _, messages in try await responder.reply(messages) })
    }

    func expense(_ title: String = "Car rental") throws -> ExpenseCD {
        let row = try ledger.transaction(amount: "123.45", currency: "RUB")
        row.title = title
        row.tag = TRANS_TAG_TRAVEL
        try ledger.context.save()
        return row
    }

    func dispose() {
        store.cancel()
        completion.onReply = nil
        defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Intentional isolated Core Data + filesystem integration; completion/key storage are mocked.
@Suite("Spending classification in-flight and persistence safety")
@MainActor
struct SpendingClassificationSafetyTests {
    @Test("A saved title change or deletion discards the response for the old ledger row", arguments: [false, true])
    func staleLedger(_ delete: Bool) async throws {
        let f = try SafetyClassificationFixture()
        defer { f.dispose() }
        let row = try f.expense()
        let id = row.objectID.uriRepresentation().absoluteString
        f.completion.onReply = { _ in
            if delete { f.ledger.context.delete(row) }
            else { row.title = "Updated train ticket" }
            try f.ledger.context.save()
        }
        await f.store.update(context: f.ledger.context)
        #expect(f.completion.batches.count == 1)
        #expect(f.store.entries[id] == nil && f.store.entries.isEmpty)
        #expect(!f.ledger.context.hasChanges)
        if !delete { #expect(row.title == "Updated train ticket" && f.store.label(for: row) == nil) }
    }

    @Test("Manual correction during completion wins over the stale AI suggestion", arguments: ["Private Purpose", nil] as [String?])
    func manualWins(_ label: String?) async throws {
        let f = try SafetyClassificationFixture()
        defer { f.dispose() }
        let row = try f.expense()
        let id = row.objectID.uriRepresentation().absoluteString
        f.completion.onReply = { _ in try f.store.setManual(label: label, for: row) }
        await f.store.update(context: f.ledger.context)
        let entry = try #require(f.store.entries[id])
        #expect(entry.manual && entry.label == label)
        #expect(f.store.label(for: row) == label && !f.ledger.context.hasChanges)
        f.completion.onReply = nil
        await f.store.update(context: f.ledger.context)
        #expect(f.completion.batches.count == 1)
        f.store.reload()
        #expect(f.store.entries[id]?.manual == true && f.store.entries[id]?.label == label)
    }

    @Test("Disabling during completion prevents response publication")
    func disableDiscards() async throws {
        let f = try SafetyClassificationFixture()
        defer { f.dispose() }
        _ = try f.expense()
        f.completion.onReply = { _ in f.store.disable() }
        await f.store.update(context: f.ledger.context)
        #expect(f.completion.batches.count == 1)
        #expect(!f.store.enabled && !f.store.isRunning && f.store.entries.isEmpty)
        #expect(f.store.lastCompletedAt == nil)
        #expect(!f.defaults.bool(forKey: SpendingClassificationStore.enabledKey))
        #expect(!FileManager.default.fileExists(atPath: f.fileURL.path))
    }

    @Test("Cancellation keeps the first completed batch and retry sends only remaining rows")
    func completedBatchSurvivesCancellation() async throws {
        let f = try SafetyClassificationFixture()
        defer { f.dispose() }
        for index in 0..<21 { _ = try f.expense("Rental \(index)") }
        f.completion.onReply = { call in if call == 2 { f.store.cancel() } }
        await f.store.update(context: f.ledger.context)
        #expect(f.completion.batches.map(\.count) == [20, 1])
        #expect(f.store.entries.count == 20 && f.store.completedCount == 20)
        #expect(!f.store.isRunning && f.store.lastCompletedAt == nil)
        f.store.reload()
        #expect(f.store.entries.count == 20)
        f.completion.onReply = nil
        await f.store.update(context: f.ledger.context)
        #expect(f.completion.batches.map(\.count) == [20, 1, 1])
        #expect(f.completion.batches[1] == f.completion.batches[2])
        #expect(f.store.entries.count == 21 && f.store.completedCount == 1)
        #expect(f.store.lastCompletedAt != nil && !f.ledger.context.hasChanges)
    }

    @Test("An existing corrupted archive is preserved without any remote request")
    func corruptedArchive() async throws {
        let original = Data("corrupted original sidecar".utf8)
        let f = try SafetyClassificationFixture(corrupted: original)
        defer { f.dispose() }
        let row = try f.expense()
        await f.store.update(context: f.ledger.context)
        #expect(f.completion.batches.isEmpty && f.store.entries.isEmpty)
        #expect(f.store.errorMessage != nil)
        #expect(try Data(contentsOf: f.fileURL) == original)
        #expect(throws: ClassificationError.self) { try f.store.setManual(label: "Manual", for: row) }
        #expect(try Data(contentsOf: f.fileURL) == original)
    }

    @Test("A sidecar write failure never publishes an unsaved classification")
    func unwritableArchive() async throws {
        let f = try SafetyClassificationFixture(blockedDirectory: true)
        defer { f.dispose() }
        let row = try f.expense()
        let blocker = try Data(contentsOf: f.directory)
        await f.store.update(context: f.ledger.context)
        #expect(f.completion.batches.count == 1)
        #expect(f.store.entries.isEmpty && f.store.label(for: row) == nil)
        #expect(f.store.errorMessage != nil && f.store.lastCompletedAt == nil)
        #expect(f.store.completedCount == 0 && !f.store.isRunning)
        #expect(try Data(contentsOf: f.directory) == blocker)
        #expect(!f.ledger.context.hasChanges && row.amountText == "123.45" && row.tag == TRANS_TAG_TRAVEL)
    }
}
