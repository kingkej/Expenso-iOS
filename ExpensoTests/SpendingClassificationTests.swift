import Foundation
import CoreData
import Testing
@testable import Expenso

@MainActor private final class ClassificationKey: OpenRouterKeyStore {
    var value: String? = "sk-or-test-only"
    func read() throws -> String? { value }
    func save(_ value: String) throws { self.value = value }
    func delete() throws { value = nil }
}

private actor ClassificationRecorder {
    var requests: [[OpenRouterMessage]] = []
    func reply(_ messages: [OpenRouterMessage]) throws -> String {
        requests.append(messages)
        let rows = try JSONSerialization.jsonObject(with: Data((messages.last?.content ?? "[]").utf8)) as! [[String: Any]]
        let items = rows.map { ["id": $0["id"]!, "label": "Pet Care", "confidence": 0.95] as [String: Any] }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["items": items]), as: UTF8.self)
    }
    var count: Int { requests.count }
}

private actor ClassificationRecoveryRecorder {
    let maximumRows: Int
    let failure: OpenRouterError?
    let rejectTitle: String?
    var sizes: [Int] = []
    var requests: [[OpenRouterMessage]] = []
    init(maximumRows: Int, failure: OpenRouterError? = .outputLimit, rejectTitle: String? = nil) {
        self.maximumRows = maximumRows; self.failure = failure; self.rejectTitle = rejectTitle
    }
    func reply(_ messages: [OpenRouterMessage]) throws -> String {
        let rows = try JSONSerialization.jsonObject(with: Data((messages.last?.content ?? "[]").utf8)) as! [[String: Any]]
        sizes.append(rows.count)
        requests.append(messages)
        if rows.count > maximumRows || rows.contains(where: { ($0["title"] as? String) == rejectTitle }) {
            if let failure { throw failure }
            return #"{"items":[]}"#
        }
        let items = rows.map { ["id": $0["id"]!, "label": "Pet Care", "confidence": 0.95] as [String: Any] }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["items": items]), as: UTF8.self)
    }
}

/// Isolated in-memory ledger integration; AI and secure storage are mocked.
@MainActor private final class ClassificationFixture {
    let name = "ClassificationTests." + UUID().uuidString
    let defaults: UserDefaults
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let ledger: CurrencyTestStore
    let settings: OpenRouterSettings
    let recorder = ClassificationRecorder()
    let store: SpendingClassificationStore
    init(enabled: Bool = true, completion: SpendingClassificationStore.Completion? = nil) throws {
        defaults = try #require(UserDefaults(suiteName: name))
        defaults.set(enabled, forKey: SpendingClassificationStore.enabledKey)
        ledger = try CurrencyTestStore()
        settings = OpenRouterSettings(defaults: defaults, keychain: ClassificationKey())
        let recorder = self.recorder
        store = SpendingClassificationStore(defaults: defaults, fileURL: directory.appendingPathComponent("types.json"),
            settings: settings, completion: completion ?? { _, _, messages in try await recorder.reply(messages) })
    }
    func expense(_ title: String = "ветеринар", category: String = TRANS_TAG_FOOD) throws -> ExpenseCD {
        let row = try ledger.transaction(amount: "123.45", currency: "RUB")
        row.title = title; row.tag = category
        try ledger.context.save()
        return row
    }
    func dispose() {
        store.cancel(); defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite("Dynamic spending types — mocked AI, isolated ledger") @MainActor
struct SpendingClassificationTests {
    @Test func optInRequired() async throws {
        let f = try ClassificationFixture(enabled: false); defer { f.dispose() }
        _ = try f.expense()
        await f.store.update(context: f.ledger.context)
        #expect(await f.recorder.count == 0)
        #expect(f.store.entries.isEmpty)
    }

    @Test func dynamicLabelsAndPrivacy() async throws {
        let f = try ClassificationFixture(); defer { f.dispose() }
        let row = try f.expense()
        await f.store.update(context: f.ledger.context)
        #expect(f.store.label(for: row) == "Pet Care")
        #expect(row.amountText == "123.45" && row.tag == TRANS_TAG_FOOD && !f.ledger.context.hasChanges)
        let requests = await f.recorder.requests
        let payload = try #require(requests.first?.last?.content)
        #expect(!payload.contains("123.45") && !payload.contains(row.objectID.uriRepresentation().absoluteString))
        let rows = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [[String: Any]])
        #expect(Set(rows[0].keys) == ["id", "title", "category"])
        let reloaded = SpendingClassificationStore(defaults: f.defaults, fileURL: f.directory.appendingPathComponent("types.json"), settings: f.settings)
        #expect(reloaded.label(for: row) == "Pet Care")
    }

    @Test func dailyIncrementalAndStaleLabels() async throws {
        let f = try ClassificationFixture(); defer { f.dispose() }
        let row = try f.expense()
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        await f.store.update(context: f.ledger.context, automatic: true, now: day)
        row.title = "Updated"; try f.ledger.context.save()
        #expect(f.store.label(for: row) == nil)
        await f.store.update(context: f.ledger.context, automatic: true, now: day)
        #expect(await f.recorder.count == 1)
        await f.store.update(context: f.ledger.context, automatic: true, now: day.addingTimeInterval(86_400))
        #expect(await f.recorder.count == 2)
        await f.store.update(context: f.ledger.context)
        #expect(await f.recorder.count == 2)
    }

    @Test func manualAndUnclassifiedPreserved() async throws {
        let f = try ClassificationFixture(); defer { f.dispose() }
        let row = try f.expense()
        try f.store.setManual(label: "Private Purpose", for: row)
        row.title = "Edited"; try f.ledger.context.save()
        _ = try f.expense("Second")
        await f.store.update(context: f.ledger.context)
        #expect(f.store.label(for: row) == "Private Purpose")
        let requests = await f.recorder.requests
        #expect(requests.allSatisfy { !$0.map { $0.content ?? "" }.joined().contains("Private Purpose") })
        try f.store.setManual(label: nil, for: row)
        await f.store.update(context: f.ledger.context)
        #expect(await f.recorder.count == 1)
        #expect(f.store.label(for: row) == nil)
        #expect(f.store.entries[row.objectID.uriRepresentation().absoluteString]?.manual == true)
    }

    @Test func boundedBatches() async throws {
        let f = try ClassificationFixture(); defer { f.dispose() }
        for index in 0..<21 { _ = try f.expense("Expense \(index)") }
        await f.store.update(context: f.ledger.context)
        #expect(await f.recorder.count == 2)
        #expect(f.store.entries.count == 21 && f.store.completedCount == 21)
    }

    @Test func strictResponseAndConfidence() throws {
        let input = ClassificationInput(id: "local-id", fingerprint: "hash", title: "ремонт", category: "Housing")
        let result = try SpendingClassificationStore.decode(#"{"items":[{"id":"0","label":"New Dynamic Type","confidence":0.4}]}"#, inputs: [input], existingLabels: [])
        #expect(result.keys.contains("local-id") && result["local-id"]! == nil)
        for invalid in [#"{"items":[]}"#, #"{"items":[{"id":"1","label":"A","confidence":1}]}"#,
                        #"{"items":[{"id":"0","label":"A","confidence":2}]}"#,
                        #"{"items":[{"id":"0","label":"all","confidence":1}]}"#] {
            #expect(throws: ClassificationError.self) { try SpendingClassificationStore.decode(invalid, inputs: [input], existingLabels: []) }
        }
        let canonical = try SpendingClassificationStore.decode(#"{"items":[{"id":"0","label":"pet care","confidence":1}]}"#, inputs: [input], existingLabels: ["Pet Care"])
        #expect(canonical["local-id"]! == "Pet Care")
    }

    @Test func invalidBatchIsNotSaved() async throws {
        let f = try ClassificationFixture(completion: { _, _, _ in #"{"items":[]}"# }); defer { f.dispose() }
        _ = try f.expense()
        await f.store.update(context: f.ledger.context)
        #expect(f.store.entries.isEmpty && f.store.errorMessage != nil && f.store.lastCompletedAt == nil)
    }

    @Test(arguments: [true, false]) func smallerBatchesRecover(_ truncated: Bool) async throws {
        let recorder = ClassificationRecoveryRecorder(maximumRows: 5, failure: truncated ? .outputLimit : nil)
        let f = try ClassificationFixture(completion: { _, _, messages in try await recorder.reply(messages) })
        defer { f.dispose() }
        for index in 0..<20 { _ = try f.expense("Expense \(index)") }
        await f.store.update(context: f.ledger.context)
        #expect(await recorder.sizes == [20, 10, 5, 5, 10, 5, 5])
        #expect(f.store.entries.count == 20 && f.store.completedCount == 20)
        #expect(f.store.errorMessage == nil && f.store.lastCompletedAt != nil)
    }

    @Test func failedItemDoesNotBlockValidSibling() async throws {
        let recorder = ClassificationRecoveryRecorder(maximumRows: 1, failure: nil, rejectTitle: "Fail")
        let f = try ClassificationFixture(completion: { _, _, messages in try await recorder.reply(messages) })
        defer { f.dispose() }
        _ = try f.expense("Good"); _ = try f.expense("Fail")
        await f.store.update(context: f.ledger.context)
        #expect(await recorder.sizes == [2, 1, 1])
        #expect(f.store.entries.count == 1 && f.store.completedCount == 1 && f.store.lastCompletedAt == nil)
        #expect(f.store.errorMessage?.contains("1 could not be classified") == true)
    }

    @Test func failedItemDoesNotBlockLaterBatches() async throws {
        let recorder = ClassificationRecoveryRecorder(maximumRows: 20, failure: nil, rejectTitle: "Fail")
        let f = try ClassificationFixture(completion: { _, _, messages in try await recorder.reply(messages) })
        defer { f.dispose() }
        let failed = try f.expense("Fail")
        failed.occuredOn = Date(timeIntervalSince1970: 2_000_000_000)
        for index in 0..<20 {
            let good = try f.expense("Good \(index)")
            good.occuredOn = Date(timeIntervalSince1970: 1_000_000_000 + Double(index))
        }
        try f.ledger.context.save()
        await f.store.update(context: f.ledger.context)
        #expect(f.store.entries.count == 20 && f.store.completedCount == 20)
        #expect(f.store.errorMessage?.contains("1 could not be classified") == true)
        #expect(f.store.lastCompletedAt == nil)
        #expect(await recorder.sizes.last == 1)
    }

    @Test func validationDiagnosticsAreSpecificAndSanitized() throws {
        let input = ClassificationInput(id: "private-id", fingerprint: "hash", title: "private title", category: "Housing")
        for (raw, expected) in [
            (#"{"items":[{"id":0,"label":"A","confidence":1}]}"#, "unexpected type for id"),
            (#"{"items":[{"id":"0","label":"private label","confidence":2}]}"#, "confidence must be between 0 and 1"),
            (#"{"other":"private contents"}"#, "missing items")
        ] {
            do {
                _ = try SpendingClassificationStore.decode(raw, inputs: [input], existingLabels: [])
                Issue.record("Invalid response must not be used")
            } catch {
                #expect(error.localizedDescription.contains(expected))
                #expect(!error.localizedDescription.contains("private"))
            }
        }
    }

    @Test func exhaustedOutputBudgetHasClassificationError() async throws {
        let recorder = ClassificationRecoveryRecorder(maximumRows: 0)
        let f = try ClassificationFixture(completion: { _, _, messages in try await recorder.reply(messages) })
        defer { f.dispose() }
        for index in 0..<20 { _ = try f.expense("Expense \(index)") }
        await f.store.update(context: f.ledger.context)
        #expect(await recorder.sizes.count == 39)
        #expect(f.store.entries.isEmpty)
        #expect(f.store.errorMessage?.contains("20 could not be classified") == true)
        #expect(f.store.errorMessage?.contains("response length limit") == true)
    }

    @Test func recoveryDoesNotUploadManualCanonicalLabel() async throws {
        let recorder = ClassificationRecoveryRecorder(maximumRows: 5)
        let f = try ClassificationFixture(completion: { _, _, messages in try await recorder.reply(messages) })
        defer { f.dispose() }
        let manual = try f.expense("Private")
        try f.store.setManual(label: "PET CARE", for: manual)
        var pending: [ExpenseCD] = []
        for index in 0..<21 { pending.append(try f.expense("Expense \(index)")) }
        await f.store.update(context: f.ledger.context)
        let requests = await recorder.requests
        #expect(requests.count == 8)
        #expect(requests.allSatisfy { !$0.map { $0.content ?? "" }.joined().contains("PET CARE") })
        #expect(pending.allSatisfy { f.store.label(for: $0) == "Pet Care" })
        #expect(f.store.label(for: manual) == "PET CARE")
    }

    @Test(arguments: [OpenRouterError.authentication, .credits, .rateLimited, .network, .incomplete])
    func terminalFailuresAreNotRetried(_ error: OpenRouterError) async throws {
        let recorder = ClassificationRecoveryRecorder(maximumRows: 0, failure: error)
        let f = try ClassificationFixture(completion: { _, _, messages in try await recorder.reply(messages) })
        defer { f.dispose() }
        _ = try f.expense(); _ = try f.expense("Second")
        await f.store.update(context: f.ledger.context)
        #expect(await recorder.sizes == [2])
        #expect(f.store.entries.isEmpty && f.store.errorMessage != nil)
    }

    @Test func queuedCancellationMakesNoRequest() async throws {
        let f = try ClassificationFixture(); defer { f.dispose() }
        _ = try f.expense()
        f.store.runNow(context: f.ledger.context)
        f.store.runNow(context: f.ledger.context)
        f.store.cancel()
        for _ in 0..<5 { await Task.yield() }
        #expect(await f.recorder.count == 0)
    }

    @Test func categoryAndTypeIntersection() throws {
        let f = try ClassificationFixture(); defer { f.dispose() }
        let travel = try f.expense("аренда", category: TRANS_TAG_TRAVEL)
        let housing = try f.expense("аренда", category: TRANS_TAG_HOUSING)
        try f.store.setManual(label: "Accommodation", for: travel)
        try f.store.setManual(label: "Accommodation", for: housing)
        let data = SpendingDataStore(context: f.ledger.context, baseCurrency: "RUB", categoryDefaults: f.defaults, classifications: f.store)
        let report = try data.report(startDate: "", endDate: "", kind: TRANS_TYPE_EXPENSE, category: TRANS_TAG_TRAVEL, search: "", spendingType: "Accommodation")
        #expect(report.matchingCount == 1 && report.totalExpense == "123.45")
        #expect(report.spendingTypes?.first?.label == "Accommodation")
        for all in ["", "all", "All", "ALL"] {
            let allReport = try data.report(startDate: "", endDate: "", kind: "expense", category: "all", search: "", spendingType: all)
            #expect(allReport.matchingCount == 2 && allReport.spendingType == nil)
            #expect(allReport.spendingTypes?.first?.count == 2)
            #expect(allReport.spendingTypes?.first?.expense == "246.9")
        }
        #expect(throws: SpendingReportError.self) { try data.report(startDate: "", endDate: "", kind: "expense", category: "all", search: "", spendingType: "Invented") }
        let encoded = try JSONEncoder().encode(report)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "spendingType"); legacy.removeValue(forKey: "spendingTypes")
        let old = try JSONDecoder().decode(SpendingReport.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.spendingTypes == nil && old.matchingCount == 1)
    }
}
