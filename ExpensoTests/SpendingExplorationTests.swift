import CoreData
import Foundation
import Testing
@testable import Expenso

@MainActor
private final class ExplorationKeyFixture: OpenRouterKeyStore {
    private var value: String?
    func read() throws -> String? { value }
    func save(_ value: String) throws { self.value = value }
    func delete() throws { value = nil }
}

/// Integration tests use an isolated in-memory ledger and disposable metadata, never AI or the real ledger.
@Suite("Read-only conversational ledger exploration")
@MainActor
struct SpendingExplorationTests {
    private func fixture() throws -> (CurrencyTestStore, SpendingDataStore, UserDefaults, String) {
        let ledger = try CurrencyTestStore()
        let name = "SpendingExplorationTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        let settings = OpenRouterSettings(defaults: defaults, keychain: ExplorationKeyFixture())
        let metadata = SpendingClassificationStore(defaults: defaults, fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("types.json"),
            settings: settings, completion: { _, _, _ in throw OpenRouterError.malformed })
        return (ledger, SpendingDataStore(context: ledger.context, baseCurrency: "RUB",
            categoryDefaults: defaults, classifications: metadata), defaults, name)
    }

    private func page(_ store: SpendingDataStore, offset: Int = 0, limit: Int = 40,
                      category: String = "all", search: String = "") throws -> SpendingTransactionPage {
        try store.listTransactions(startDate: "", endDate: "", kind: "all", category: category,
            search: search, offset: offset, limit: limit)
    }

    @Test("Estimated conversions disclose only rates contributing to the requested total")
    func estimatedConversionDisclosure() throws {
        let (ledger, store, defaults, name) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let rates: [String: Decimal] = ["USD": 1, "RUB": 80]
        let estimatedSnapshot = CurrencyRateSnapshot(date: "2026-09-30", rates: rates,
            source: "Mock published table", requestedDate: "2026-10-01")
        func addEstimated(_ title: String, currency: String = "USD", type: String = TRANS_TYPE_EXPENSE) throws -> ExpenseCD {
            let row = try ledger.transaction(amount: "10", currency: currency, type: type)
            row.title = title
            row.rateSnapshotData = try JSONEncoder().encode(estimatedSnapshot)
            return row
        }
        _ = try addEstimated("Estimated expense")
        _ = try addEstimated("Estimated income", type: TRANS_TYPE_INCOME)
        _ = try addEstimated("Same currency", currency: "RUB")
        _ = try addEstimated("Unknown kind", type: "corrupt")
        let invalid = try addEstimated("Invalid amount")
        invalid.amountText = "invalid"
        let exact = try ledger.transaction(amount: "10", currency: "USD", rates: rates)
        exact.title = "Exact expense"
        try ledger.context.save()

        let report = try store.report(startDate: "", endDate: "", kind: "expense", category: "all", search: "")
        #expect(report.matchingCount == 3 && report.totalExpense == "1610")
        #expect(report.estimatedConversionCount == 1)
        #expect(report.excludedUnknownTypeCount == 1 && report.excludedInvalidAmountCount == 1)
        #expect(report.dataUsageNotice.contains("1 estimated conversions"))
        let result = try page(store)
        #expect(result.estimatedConversionCount == 2)
        let estimated = try #require(result.transactions.first { $0.untrustedTitle == "Estimated expense" })
        #expect(estimated.usesEstimatedConversion == true && estimated.rateDate == "2026-09-30")
        #expect(estimated.requestedRateDate == "2026-10-01")
        #expect(result.transactions.first { $0.untrustedTitle == "Same currency" }?.usesEstimatedConversion == false)
        #expect(result.transactions.first { $0.untrustedTitle == "Exact expense" }?.usesEstimatedConversion == false)
        let selected = try store.reportSelected(ids: [estimated.id])
        #expect(selected.estimatedConversionCount == 1 && selected.selectionCount == 1)
        #expect(selected.topTransactions.first?.usesEstimatedConversion == true)
        #expect(selected.topTransactions.first?.requestedRateDate == "2026-10-01")
        let exactOnly = try store.report(startDate: "", endDate: "", kind: "expense", category: "all", search: "Exact expense")
        #expect(exactOnly.estimatedConversionCount == 0 && !exactOnly.dataUsageNotice.contains("estimated conversions"))
    }

    @Test("Earlier chat archives decode without estimated-conversion metadata")
    func legacyEstimatedMetadata() throws {
        let (ledger, store, defaults, name) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        _ = try ledger.transaction(amount: "10", currency: "RUB")
        try ledger.context.save()
        let report = try store.report(startDate: "", endDate: "", kind: "expense", category: "all", search: "")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        object.removeValue(forKey: "estimatedConversionCount")
        var transactions = try #require(object["topTransactions"] as? [[String: Any]])
        for index in transactions.indices {
            transactions[index].removeValue(forKey: "usesEstimatedConversion")
            transactions[index].removeValue(forKey: "requestedRateDate")
        }
        object["topTransactions"] = transactions
        let decoded = try JSONDecoder().decode(SpendingReport.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.estimatedConversionCount == nil && decoded.totalExpense == "10")
        #expect(decoded.topTransactions.first?.usesEstimatedConversion == nil)
        #expect(decoded.topTransactions.first?.requestedRateDate == nil)
    }

    @Test("Paging is stable for equal dates and returns only opaque turn-local tokens")
    func pagingAndPrivacy() throws {
        let (ledger, store, defaults, name) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        for index in 0..<45 {
            let row = try ledger.transaction(amount: "10", currency: "RUB")
            row.title = "Receipt \(index)"
            row.note = "PRIVATE-NOTE"
        }
        try ledger.context.save()
        let first = try page(store)
        let second = try page(store, offset: try #require(first.nextOffset))
        #expect(first.transactions.count == 40 && second.transactions.count == 5)
        #expect(first.totalMatchingCount == 45 && second.nextOffset == nil)
        #expect(Set(first.transactions.map(\.id)).isDisjoint(with: Set(second.transactions.map(\.id))))
        #expect(try page(store).transactions.map(\.id) == first.transactions.map(\.id))
        let json = String(decoding: try JSONEncoder().encode(first), as: UTF8.self)
        #expect(!json.contains("PRIVATE-NOTE") && !json.contains("x-coredata") && !json.contains("objectID"))
        #expect(!ledger.context.hasChanges)
        store.resetExploration()
        #expect(throws: SpendingReportError.self) { try store.reportSelected(ids: [first.transactions[0].id]) }
    }

    @Test("Semantic selections total exact originals across categories without rewriting records")
    func exactSelectedSubset() throws {
        let (ledger, store, defaults, name) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let travel = try ledger.transaction(amount: "59500.25", currency: "RUB")
        travel.title = "аренда велигама"; travel.tag = "travel"
        let housing = try ledger.transaction(amount: "1000.10", currency: "RUB")
        housing.title = "Rental flat"; housing.tag = "housing"
        let utility = try ledger.transaction(amount: "700", currency: "RUB")
        utility.title = "Electricity"; utility.tag = "housing"
        try ledger.context.save()
        let rows = try page(store).transactions.filter { $0.untrustedTitle != "Electricity" }
        let report = try store.reportSelected(ids: rows.map(\.id))
        #expect(report.totalExpense == "60500.35" && report.matchingCount == 2 && report.selectionCount == 2)
        #expect(Set(report.categories.map(\.category)) == ["travel", "housing"])
        #expect(!report.topTransactions.contains { $0.id.contains("x-coredata") })
        #expect(!ledger.context.hasChanges && travel.tag == "travel" && housing.tag == "housing")
        #expect(throws: SpendingReportError.self) { try store.reportSelected(ids: [rows[0].id, rows[0].id]) }
        #expect(throws: SpendingReportError.self) { try store.reportSelected(ids: [rows[0].id, "unknown"]) }
    }

    @Test("Changed or deleted selections fail atomically instead of producing misleading partial totals", arguments: ["amount", "title", "deleted"])
    func staleSelection(_ change: String) throws {
        let (ledger, store, defaults, name) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let changed = try ledger.transaction(amount: "10", currency: "RUB")
        changed.title = String(repeating: "a", count: 120)
        _ = try ledger.transaction(amount: "20", currency: "RUB")
        try ledger.context.save()
        let ids = try page(store).transactions.map(\.id)
        switch change {
        case "amount": changed.amountText = "99"
        case "title": changed.title = String(repeating: "a", count: 120) + "suffix edit"
        default: ledger.context.delete(changed)
        }
        #expect(throws: SpendingReportError.self) { try store.reportSelected(ids: ids) }
    }

    @Test("Larger pages can select more than two hundred transactions with exact totals")
    func largerInvestigation() throws {
        let (ledger, store, defaults, name) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        for _ in 0..<250 { _ = try ledger.transaction(amount: "1", currency: "RUB") }
        var ids: [String] = []
        var offset = 0
        repeat {
            let result = try page(store, offset: offset, limit: 100)
            ids += result.transactions.map(\.id)
            guard let next = result.nextOffset else { break }
            offset = next
        } while true
        let report = try store.reportSelected(ids: ids)
        #expect(ids.count == 250 && report.selectionCount == 250 && report.totalExpense == "250")
    }

    @Test("Catalogue uses injected category names and paging validates exact filters")
    func catalogueAndValidation() throws {
        let (_, store, defaults, name) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        var categories = CategoryCatalog.defaults
        categories[0].name = "My transport"; categories[0].isArchived = true
        try CategoryCatalog.save(categories, defaults: defaults)
        let catalogue = try store.catalogue()
        #expect(catalogue.categories.first?.name == "My transport")
        #expect(catalogue.categories.first?.isArchived == true && catalogue.currency == "RUB")
        #expect(throws: SpendingReportError.self) { try page(store, limit: SpendingInvestigationLimits.pageSize + 1) }
        #expect(throws: SpendingReportError.self) { try page(store, offset: -1) }
        #expect(throws: SpendingReportError.self) { try page(store, category: "made up") }
        #expect(throws: SpendingReportError.self) { try store.reportSelected(ids: []) }
    }

    @Test("Ledger changes between pages invalidate earlier tokens and require restarting", arguments: ["insert", "delete", "date", "unselectedTitle"])
    func changedPagingScope(_ change: String) throws {
        let (ledger, store, defaults, name) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let first = try ledger.transaction(amount: "10", currency: "RUB")
        first.title = "Selected rent"; first.occuredOn = Date(timeIntervalSince1970: 100)
        let other = try ledger.transaction(amount: "20", currency: "RUB")
        other.title = "Bus"; other.occuredOn = Date(timeIntervalSince1970: 50)
        try ledger.context.save()
        let initial = try page(store, limit: 1)
        let token = try #require(initial.transactions.first?.id)
        switch change {
        case "insert":
            let added = try ledger.transaction(amount: "30", currency: "RUB")
            added.occuredOn = Date(timeIntervalSince1970: 150)
        case "delete": ledger.context.delete(other)
        case "date": other.occuredOn = Date(timeIntervalSince1970: 200)
        default: other.title = "Previously unselected rent"
        }
        #expect(throws: SpendingReportError.self) { try page(store, offset: 1, limit: 1) }
        #expect(throws: SpendingReportError.self) { try store.reportSelected(ids: [token]) }
        #expect(throws: SpendingReportError.self) { try page(store, offset: 1, limit: 1) }
        let restarted = try page(store, limit: 1)
        #expect(restarted.transactions.first?.id != token)
        #expect(restarted.totalMatchingCount == (change == "delete" ? 1 : change == "insert" ? 3 : 2))
    }

    @Test("Unselected ledger changes after exploration prevent stale semantic totals")
    func changedUnselectedRow() throws {
        let (ledger, store, defaults, name) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let rent = try ledger.transaction(amount: "10", currency: "RUB")
        rent.title = "Rent"
        let bus = try ledger.transaction(amount: "20", currency: "RUB")
        bus.title = "Bus"
        try ledger.context.save()
        let tokens = try page(store).transactions.filter { $0.untrustedTitle == "Rent" }.map(\.id)
        bus.title = "Actually rent"
        #expect(throws: SpendingReportError.self) { try store.reportSelected(ids: tokens) }
    }
}
