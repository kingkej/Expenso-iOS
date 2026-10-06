import Foundation
import Testing
@testable import Expenso

/// Mock secure storage; no tests touch the device's actual Keychain.
@MainActor
private final class ChatKeyFixture: OpenRouterKeyStore {
    var value: String?
    var fails = false
    func read() throws -> String? { if fails { throw OpenRouterSettingsError.keychain }; return value }
    func save(_ value: String) throws { if fails { throw OpenRouterSettingsError.keychain }; self.value = value }
    func delete() throws { if fails { throw OpenRouterSettingsError.keychain }; value = nil }
}

@MainActor
private final class ChatSettingsFixture {
    let name = "OpenRouterSpendingTests." + UUID().uuidString
    let defaults: UserDefaults
    let key = ChatKeyFixture()
    let settings: OpenRouterSettings
    init() throws {
        defaults = try #require(UserDefaults(suiteName: name))
        settings = OpenRouterSettings(defaults: defaults, keychain: key)
    }
    func enable() throws {
        try settings.save(key: "sk-or-fixture-only", model: OpenRouterClient.defaultModelID, consent: true, provider: .openRouter)
    }
    func dispose() { defaults.removePersistentDomain(forName: name) }
}

@Suite("Chat configuration — mocked secure storage")
@MainActor
struct OpenRouterSettingsTests {
    @available(iOS 26, *)
    @Test("Opening history is read-only, continuing respects the provider, and deletion stays deleted")
    func savedConversationLifecycle() throws {
        let fixture = try ChatSettingsFixture()
        defer { fixture.dispose() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = SpendingChatHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        let messages = [SpendingChatMessage(role: .user, text: "My food expenses?", reports: []),
                        SpendingChatMessage(role: .assistant, text: "Recorded expenses: 125 RUB.", reports: [])]
        let saved = SavedSpendingConversation(id: UUID(), provider: .onDevice,
            createdAt: Date(), updatedAt: Date(), messages: messages)
        #expect(history.upsert(saved))
        let model = SpendingChatModel(historyStore: history, settings: fixture.settings)
        #expect(model.messages.isEmpty && !model.isGenerating)
        #expect(history.matching("food").count == 1)
        #expect(model.messages.isEmpty && fixture.settings.provider == .onDevice)
        #expect(model.resume(saved))
        #expect(model.messages.map(\.id) == messages.map(\.id) && !model.isGenerating)
        #expect(model.newChat() && model.messages.isEmpty && history.conversations.count == 1)
        try fixture.enable()
        #expect(!model.resume(saved) && model.messages.isEmpty)
        #expect(fixture.settings.provider == .openRouter)
        try fixture.settings.disable(removeKey: false)
        #expect(model.resume(saved))
        #expect(model.deleteConversation(saved.id))
        model.stop()
        #expect(model.newChat() && model.messages.isEmpty && history.conversations.isEmpty)
        #expect(SpendingChatHistoryStore(fileURL: directory.appendingPathComponent("history.json")).conversations.isEmpty)
    }

    @Test("Existing installations default to Apple Intelligence without a key or remote consent")
    func defaultLocal() throws {
        let fixture = try ChatSettingsFixture()
        defer { fixture.dispose() }
        #expect(fixture.settings.provider == .onDevice && !fixture.settings.hasKey && !fixture.settings.allowsRemoteData)
        #expect(fixture.settings.modelID == OpenRouterClient.defaultModelID)
        #expect(throws: OpenRouterSettingsError.self) { try fixture.settings.credentials() }
        try fixture.settings.save(key: "", model: OpenRouterClient.defaultModelID, consent: false, provider: .onDevice)
        #expect(fixture.key.value == nil)
    }

    @Test("Keys can be saved without consent, but remote credentials stay blocked")
    func consentAndSecret() throws {
        let fixture = try ChatSettingsFixture()
        defer { fixture.dispose() }
        try fixture.settings.save(key: "  sk-or-fixture-only\n", model: OpenRouterClient.defaultModelID, consent: false, provider: .openRouter)
        #expect(fixture.key.value == "sk-or-fixture-only")
        #expect(fixture.settings.hasKey && fixture.settings.provider == .openRouter)
        #expect(!fixture.settings.allowsRemoteData)
        #expect(throws: OpenRouterSettingsError.self) { try fixture.settings.credentials() }
        #expect(!fixture.defaults.bool(forKey: OpenRouterSettings.consentKey))
        let revision = fixture.settings.revision
        try fixture.enable()
        #expect(fixture.settings.provider == .openRouter && fixture.settings.hasKey && fixture.settings.allowsRemoteData)
        #expect(revision != fixture.settings.revision)
        let leaked = fixture.defaults.dictionaryRepresentation().values.contains { ($0 as? String) == fixture.key.value }
        #expect(!leaked)
        let credentialsMatch = try fixture.settings.credentials() == fixture.key.value
        #expect(credentialsMatch)
    }

    @available(iOS 26, *)
    @Test("Legacy remote consent preserves credentials but cannot dispatch exploration until renewed")
    func legacyExplorationConsent() async throws {
        let fixture = try ChatSettingsFixture()
        defer { fixture.dispose() }
        fixture.key.value = "sk-or-fixture-only"
        fixture.defaults.set(true, forKey: OpenRouterSettings.consentKey)
        fixture.defaults.set("example/previous-model", forKey: OpenRouterSettings.modelKey)
        fixture.defaults.set(OpenRouterSettings.Provider.openRouter.rawValue, forKey: OpenRouterSettings.providerKey)
        let settings = OpenRouterSettings(defaults: fixture.defaults, keychain: fixture.key)
        #expect(settings.hasKey && settings.allowsRemoteData && !settings.allowsLedgerExploration)
        #expect(settings.modelID == "example/previous-model")
        let ledger = try CurrencyTestStore()
        var calls = 0
        let model = OpenRouterSpendingChatModel(settings: settings,
            store: SpendingDataStore(context: ledger.context, baseCurrency: "RUB")) { _, _, _, _ in
                calls += 1
                return .init(role: "assistant", content: "Ready to help.")
            }
        model.send("Hello")
        await model.generationTask?.value
        #expect(calls == 0 && model.messages.isEmpty && model.unavailableReason != nil)
        #expect(fixture.key.value == "sk-or-fixture-only" && settings.modelID == "example/previous-model")
        try settings.save(key: "", model: settings.modelID, consent: true, provider: .openRouter)
        #expect(settings.allowsLedgerExploration)
        model.send("Hello")
        await model.generationTask?.value
        #expect(calls == 1 && model.messages.last?.role == .assistant)
        #expect(fixture.key.value == "sk-or-fixture-only" && settings.modelID == "example/previous-model")
    }

    @Test("Replacing a key cannot publish settings when secure persistence fails")
    func keychainFailure() throws {
        let fixture = try ChatSettingsFixture()
        defer { fixture.dispose() }
        try fixture.enable()
        fixture.key.fails = true
        let revision = fixture.settings.revision
        #expect(throws: OpenRouterSettingsError.self) {
            try fixture.settings.save(key: "sk-or-replacement", model: "other/model", consent: true, provider: .openRouter)
        }
        #expect(fixture.settings.revision == revision && fixture.settings.modelID == OpenRouterClient.defaultModelID)
        #expect(fixture.defaults.string(forKey: OpenRouterSettings.modelKey) == OpenRouterClient.defaultModelID)
    }

    @Test("Disabling remote access selects local, blocks credentials and optionally removes the key", arguments: [false, true])
    func disable(_ removeKey: Bool) throws {
        let fixture = try ChatSettingsFixture()
        defer { fixture.dispose() }
        try fixture.enable()
        try fixture.settings.disable(removeKey: removeKey)
        #expect(fixture.settings.provider == .onDevice && !fixture.settings.allowsRemoteData)
        #expect(fixture.settings.hasKey == !removeKey)
        #expect(throws: OpenRouterSettingsError.self) { try fixture.settings.credentials() }
    }
}

@Suite("OpenRouter spending — isolated Core Data integration, mocked AI and Keychain")
@MainActor
struct OpenRouterSpendingTests {
    // Genuine chat tools expose only period and kind. Missing legacy fields must
    // default to an unrestricted ledger read, not require invented categories.
    private let queryArguments = #"{"period":"allTime","startDate":"","endDate":"","kind":"expense"}"#

    private func queryPlan() -> OpenRouterMessage {
        .init(role: "assistant", tool_calls: [.init(id: "query-1", function: .init(name: "query_spending", arguments: queryArguments))])
    }

    private func recentRows(_ context: [String: Any]) throws -> [[String: String]] {
        let columns = try #require(context["columns"] as? [String])
        #expect(columns == ["id", "date", "untrustedTitle", "amount", "kind"])
        let rows = try #require(context["transactions"] as? [[String]])
        return try rows.map { row in
            try #require(row.count == columns.count)
            return Dictionary(uniqueKeysWithValues: zip(columns, row))
        }
    }

    @available(iOS 26, *)
    @Test("Upfront recent context includes cross-category purposes with usable opaque IDs, without notes or automatic reports")
    func recentContextEvidenceAndPrivacy() async throws {
        let fixture = try ChatSettingsFixture()
        defer { fixture.dispose() }
        try fixture.enable()
        let ledger = try CurrencyTestStore()
        let rent = try ledger.transaction(amount: "59500", currency: "RUB")
        rent.title = "аренда велигама"; rent.tag = "travel"; rent.occuredOn = Date()
        rent.note = "NEVER SEND PRIVATE LEASE NOTE"
        let repair = try ledger.transaction(amount: "700", currency: "RUB")
        repair.title = "ремонт ванной"; repair.tag = "housing"; repair.occuredOn = Date()
        let utilities = try ledger.transaction(amount: "300", currency: "RUB")
        utilities.title = "коммунальные услуги"; utilities.tag = "housing"; utilities.occuredOn = Date()
        let old = try ledger.transaction(amount: "100", currency: "RUB")
        old.title = "OLD ROW OUTSIDE RECENT CONTEXT"
        old.occuredOn = Calendar.current.date(byAdding: .day, value: -70, to: Date())
        let undated = try ledger.transaction(amount: "10", currency: "RUB")
        undated.title = "UNDATED ROW OUTSIDE RECENT CONTEXT"; undated.occuredOn = nil
        try ledger.context.save()
        let originals = [rent, repair, utilities, old, undated].map(LedgerRecord.init)
        var calls = 0
        var model: OpenRouterSpendingChatModel!
        model = OpenRouterSpendingChatModel(settings: fixture.settings,
            store: SpendingDataStore(context: ledger.context, baseCurrency: "RUB")) { _, _, messages, tools in
                #expect(tools)
                calls += 1
                if calls == 1 {
                    #expect(model.currentReports.isEmpty)
                    let system = try #require(messages.first?.content)
                    #expect(system.contains("аренда велигама") && system.contains("ремонт ванной") && system.contains("коммунальные услуги"))
                    #expect(!system.contains("NEVER SEND PRIVATE LEASE NOTE") && !system.contains("x-coredata"))
                    #expect(!system.contains("OLD ROW OUTSIDE RECENT CONTEXT") && !system.contains("UNDATED ROW OUTSIDE RECENT CONTEXT"))
                    #expect(!system.contains("Previous query filters") && !system.contains("sk-or-fixture-only"))
                    let marker = try #require(system.range(of: "Recent transaction context: "))
                    let json = String(system[marker.upperBound...]).components(separatedBy: "\n")[0]
                    let context = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
                    #expect(context["complete"] as? Bool == true && context["nextOffset"] == nil)
                    #expect(context["totalMatchingCount"] as? Int == 3)
                    #expect(context["category"] == nil && context["kind"] as? String == "all")
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.dateFormat = "yyyy-MM-dd"
                    formatter.timeZone = .current
                    let startText = try #require(context["startDate"] as? String)
                    let endText = try #require(context["endDate"] as? String)
                    let start = try #require(formatter.date(from: startText))
                    let end = try #require(formatter.date(from: endText))
                    #expect(Calendar.current.date(byAdding: .month, value: -1, to: end) == start)
                    let rows = try recentRows(context)
                    #expect(rows.count == 3)
                    let match = try #require(rows.first(where: { $0["untrustedTitle"] == "аренда велигама" }))
                    let token = try #require(match["id"])
                    #expect(Set(match.keys) == Set(["id", "untrustedTitle", "date", "kind", "amount"]))
                    #expect(match["amount"] == "59500")
                    #expect(!token.contains("x-coredata"))
                    let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["ids": [token]]), as: UTF8.self)
                    return .init(role: "assistant", tool_calls: [.init(id: "recent-rent",
                        function: .init(name: "query_selected_transactions", arguments: arguments))])
                }
                let payload = try #require(messages.last?.content)
                #expect(payload.contains(#""totalExpense":"59500""#))
                return .init(role: "assistant", content: "The selected Travel rent record totals 59,500 RUB.")
            }
        model.send("How much did I spend on rent?")
        await model.generationTask?.value
        #expect(calls == 2 && model.messages.last?.role == .assistant)
        #expect(model.messages.last?.reports.count == 1 && model.currentReports.first?.report.totalExpense == "59500")
        #expect([rent, repair, utilities, old, undated].map(LedgerRecord.init) == originals && !ledger.context.hasChanges)
    }

    @available(iOS 26, *)
    @Test("Recent context remains bounded and discloses where uninspected evidence continues", arguments: [false, true])
    func recentContextBounds(_ longTitles: Bool) async throws {
        let fixture = try ChatSettingsFixture()
        defer { fixture.dispose() }
        try fixture.enable()
        let ledger = try CurrencyTestStore()
        for index in 0..<150 {
            let row = try ledger.transaction(amount: "1", currency: "RUB")
            row.title = longTitles ? String(repeating: "🏠", count: 120) + " \(index)" : "Purchase \(index)"
            row.occuredOn = Date()
        }
        try ledger.context.save()
        var calls = 0
        let model = OpenRouterSpendingChatModel(settings: fixture.settings,
            store: SpendingDataStore(context: ledger.context, baseCurrency: "RUB")) { _, _, messages, _ in
                calls += 1
                let system = try #require(messages.first?.content)
                let marker = try #require(system.range(of: "Recent transaction context: "))
                let json = String(system[marker.upperBound...]).components(separatedBy: "\n")[0]
                let context = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
                let rows = try recentRows(context)
                #expect(!rows.isEmpty && rows.count <= 120 && json.utf8.count <= 48_000)
                #expect(context["complete"] as? Bool == false && context["totalMatchingCount"] as? Int == 150)
                #expect(context["nextOffset"] as? Int == rows.count)
                if longTitles { #expect(rows.count < 120) }
                else { #expect(rows.count == 120) }
                return .init(role: "assistant", content: "I can inspect the remaining records if needed.")
            }
        model.send("Hello")
        await model.generationTask?.value
        #expect(calls == 1 && model.messages.last?.reports.isEmpty == true)
        #expect(model.currentReports.isEmpty && !ledger.context.hasChanges)
    }

    @available(iOS 26, *)
    @Test("A complete recent preview discloses excluded invalid amounts and unknown types")
    func recentContextExclusionsAreDisclosed() async throws {
        let fixture = try ChatSettingsFixture()
        defer { fixture.dispose() }
        try fixture.enable()
        let ledger = try CurrencyTestStore()
        let valid = try ledger.transaction(amount: "125", currency: "RUB")
        valid.title = "Eligible purchase"; valid.occuredOn = Date()
        let unknown = try ledger.transaction(amount: "50", currency: "RUB", type: "unsupported-type")
        unknown.title = "Excluded unknown kind"; unknown.occuredOn = Date()
        let invalid = try ledger.transaction(amount: "20", currency: "RUB")
        invalid.title = "Excluded invalid amount"; invalid.amountText = "not-a-number"; invalid.occuredOn = Date()
        try ledger.context.save()
        let originals = [valid, unknown, invalid].map(LedgerRecord.init)
        var calls = 0
        let model = OpenRouterSpendingChatModel(settings: fixture.settings,
            store: SpendingDataStore(context: ledger.context, baseCurrency: "RUB")) { _, _, messages, _ in
                calls += 1
                let system = try #require(messages.first?.content)
                let marker = try #require(system.range(of: "Recent transaction context: "))
                let json = String(system[marker.upperBound...]).components(separatedBy: "\n")[0]
                let context = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
                let rows = try recentRows(context)
                #expect(rows.count == 1 && rows.first?["untrustedTitle"] == "Eligible purchase")
                #expect(context["totalMatchingCount"] as? Int == 1)
                // Complete is coverage of eligible evidence, not a claim that every ledger
                // row was valid or was displayed. Both exclusions must remain explicit.
                #expect(context["complete"] as? Bool == true && context["nextOffset"] == nil)
                #expect(context["excludedUnknownTypeCount"] as? Int == 1)
                #expect(context["excludedInvalidAmountCount"] as? Int == 1)
                #expect(!json.contains("Excluded unknown kind") && !json.contains("Excluded invalid amount"))
                return .init(role: "assistant", content: "Some recent records could not be included in the preview.")
            }
        model.send("Hello")
        await model.generationTask?.value
        #expect(calls == 1 && model.messages.last?.role == .assistant)
        #expect(model.currentReports.isEmpty && model.messages.last?.reports.isEmpty == true)
        #expect([valid, unknown, invalid].map(LedgerRecord.init) == originals && !ledger.context.hasChanges)
    }

    @available(iOS 26, *)
    @Test("The model inspects overall totals and multilingual rows before totaling its semantic selection")
    func iterativeSemanticInvestigation() async throws {
        let fixture = try ChatSettingsFixture()
        defer { fixture.dispose() }
        try fixture.enable()
        let ledger = try CurrencyTestStore()
        let rent = try ledger.transaction(amount: "59500", currency: "RUB")
        rent.title = "аренда велигама 18.10 - 12.11"; rent.tag = "travel"; rent.occuredOn = Date()
        let other = try ledger.transaction(amount: "7230", currency: "RUB")
        other.title = "автобус"; other.tag = "travel"; other.occuredOn = Date()
        let housing = try ledger.transaction(amount: "1000", currency: "RUB")
        housing.title = "коммунальные услуги"; housing.tag = "housing"; housing.occuredOn = Date()
        try ledger.context.save()
        let originals = [rent, other, housing].map(LedgerRecord.init)
        var requests: [[OpenRouterMessage]] = []
        let model = OpenRouterSpendingChatModel(settings: fixture.settings,
            store: SpendingDataStore(context: ledger.context, baseCurrency: "RUB")) { _, _, messages, tools in
                #expect(tools) // Automatic tools remain available, not forced, on every round.
                requests.append(messages)
                switch requests.count {
                case 1:
                    return .init(role: "assistant", tool_calls: [.init(id: "overall",
                        function: .init(name: "query_spending", arguments: #"{"period":"thisMonth","startDate":"","endDate":"","kind":"expense"}"#))])
                case 2:
                    let payload = try #require(messages.last?.content)
                    let report = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
                    #expect(report["totalExpense"] as? String == "67730")
                    #expect(report["matchingCount"] as? Int == 3)
                    #expect(report["categoryTotals"] == nil && report["topTransactions"] == nil)
                    #expect(report["category"] == nil && report["titleSearchTerms"] == nil)
                    return .init(role: "assistant", tool_calls: [.init(id: "inspect",
                        function: .init(name: "list_spending_transactions", arguments: #"{"period":"thisMonth","startDate":"","endDate":"","kind":"expense","offset":0,"limit":40}"#))])
                case 3:
                    let payload = try #require(messages.last?.content)
                    let page = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
                    let rows = try #require(page["transactions"] as? [[String: Any]])
                    #expect(page["totalMatchingCount"] as? Int == 3 && page["nextOffset"] == nil)
                    let matching = try #require(rows.first(where: { ($0["untrustedTitle"] as? String)?.hasPrefix("аренда") == true }))
                    let token = try #require(matching["id"] as? String)
                    #expect(!token.contains("x-coredata"))
                    let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["ids": [token]]), as: UTF8.self)
                    return .init(role: "assistant", tool_calls: [.init(id: "selected",
                        function: .init(name: "query_selected_transactions", arguments: arguments))])
                default:
                    let payload = try #require(messages.last?.content)
                    let report = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
                    #expect(report["totalExpense"] as? String == "59500")
                    #expect(report["selectionCount"] as? Int == 1)
                    return .init(role: "assistant", content: "The inspected rent transaction totals 59,500 RUB, recorded under Travel.")
                }
            }
        model.send("скок за месяц на снятие жилье я слил")
        await model.generationTask?.value
        #expect(requests.count == 4 && !model.isGenerating)
        let answer = try #require(model.messages.last)
        #expect(answer.role == .assistant && answer.reports.count == 2)
        #expect(answer.reports.last?.report.totalExpense == "59500")
        #expect(answer.reports.last?.report.selectionCount == 1)
        #expect([rent, other, housing].map(LedgerRecord.init) == originals && !ledger.context.hasChanges)
    }

    @available(iOS 26, *)
    @Test("General conversation can finish naturally without a ledger query")
    func naturalConversation() async throws {
        let fixture = try ChatSettingsFixture()
        defer { fixture.dispose() }
        try fixture.enable()
        let ledger = try CurrencyTestStore()
        var calls = 0
        let model = OpenRouterSpendingChatModel(settings: fixture.settings,
            store: SpendingDataStore(context: ledger.context, baseCurrency: "RUB")) { _, _, _, tools in
                #expect(tools)
                calls += 1
                return .init(role: "assistant", content: "Hi! I can help you explore your recorded spending.")
            }
        model.send("Hi, what can you do?")
        await model.generationTask?.value
        #expect(calls == 1 && model.currentReports.isEmpty)
        #expect(model.messages.last?.role == .assistant && model.messages.last?.reports.isEmpty == true)
    }

    @available(iOS 26, *)
    @Test("Paged evidence has distinct opaque IDs and an exact verified subtotal across pages")
    func selectedAcrossPages() async throws {
        let fixture = try ChatSettingsFixture()
        defer { fixture.dispose() }
        try fixture.enable()
        let ledger = try CurrencyTestStore()
        for index in 0..<45 {
            let row = try ledger.transaction(amount: "1", currency: "RUB")
            row.title = "Rental \(index)"
            row.tag = index.isMultiple(of: 2) ? "travel" : "housing"
        }
        try ledger.context.save()
        var tokens: [String] = []
        var calls = 0
        let model = OpenRouterSpendingChatModel(settings: fixture.settings,
            store: SpendingDataStore(context: ledger.context, baseCurrency: "RUB")) { _, _, messages, tools in
                #expect(tools)
                calls += 1
                if calls == 2 || calls == 3 {
                    let payload = try #require(messages.last?.content)
                    let page = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
                    let rows = try #require(page["transactions"] as? [[String: Any]])
                    #expect(page["totalMatchingCount"] as? Int == 45)
                    #expect(rows.count == (calls == 2 ? 40 : 5))
                    tokens += try rows.map { try #require($0["id"] as? String) }
                    #expect(Set(tokens).count == tokens.count && tokens.allSatisfy { !$0.contains("x-coredata") })
                    if calls == 2 { #expect(page["nextOffset"] as? Int == 40) }
                    else {
                        #expect(page["nextOffset"] == nil)
                        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["ids": tokens]), as: UTF8.self)
                        return .init(role: "assistant", tool_calls: [.init(id: "selected-pages",
                            function: .init(name: "query_selected_transactions", arguments: arguments))])
                    }
                }
                if calls <= 2 {
                    let arguments: [String: Any] = ["period": "allTime", "startDate": "", "endDate": "",
                        "kind": "expense", "offset": calls == 1 ? 0 : 40, "limit": 40]
                    return .init(role: "assistant", tool_calls: [.init(id: "page-\(calls)",
                        function: .init(name: "list_spending_transactions", arguments: String(decoding:
                            try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)))])
                }
                let payload = try #require(messages.last?.content)
                #expect(payload.contains(#""totalExpense":"45""#) && payload.contains(#""selectionCount":45"#))
                return .init(role: "assistant", content: "All 45 inspected rental records total 45 RUB.")
            }
        model.send("Total my rental records across categories")
        await model.generationTask?.value
        #expect(calls == 4 && model.messages.last?.role == .assistant)
        #expect(model.messages.last?.reports.count == 1 && model.currentReports.first?.report.totalExpense == "45")
        #expect(!ledger.context.hasChanges)
    }

    @available(iOS 26, *)
    @Test("Explicitly unfinished pages block selected totals retryably until the scope is finished")
    func unfinishedPagingGuard() throws {
        let ledger = try CurrencyTestStore()
        for index in 0..<45 {
            let row = try ledger.transaction(amount: "1", currency: "RUB")
            row.title = "Rental \(index)"; row.occuredOn = Date()
        }
        try ledger.context.save()
        let collector = SpendingQueryCollector(store: SpendingDataStore(context: ledger.context, baseCurrency: "RUB"))
        let arguments = SpendingQueryTool.Arguments(period: "allTime", startDate: "", endDate: "",
            kind: "expense", category: "all", search: "")

        collector.beginTurn()
        let previewJSON = collector.recentContext()
        let preview = try #require(JSONSerialization.jsonObject(with: Data(previewJSON.utf8)) as? [String: Any])
        #expect(preview["complete"] as? Bool == true)
        let previewRows = try recentRows(preview)
        #expect(previewRows.count == 45 && collector.reports.isEmpty)
        let previewID = try #require(previewRows.first?["id"])
        #expect(collector.selected([previewID]).contains(#""totalExpense":"1""#))

        collector.beginTurn()
        let firstJSON = collector.list(arguments, offset: 0, limit: 40)
        let first = try #require(JSONSerialization.jsonObject(with: Data(firstJSON.utf8)) as? [String: Any])
        #expect(first["nextOffset"] as? Int == 40 && first["totalMatchingCount"] as? Int == 45)
        let firstRows = try #require(first["transactions"] as? [[String: Any]])
        #expect(firstRows.count == 40)
        var ids = try firstRows.map { try #require($0["id"] as? String) }
        let blocked = collector.selected(ids)
        #expect(blocked.contains("Finish the transaction pages") && blocked.contains(#"\"offset\":40"#))
        #expect(collector.queryFailure == nil && collector.reports.isEmpty)

        let lastJSON = collector.list(arguments, offset: 40, limit: 40)
        let last = try #require(JSONSerialization.jsonObject(with: Data(lastJSON.utf8)) as? [String: Any])
        #expect(last["nextOffset"] == nil && last["totalMatchingCount"] as? Int == 45)
        let lastRows = try #require(last["transactions"] as? [[String: Any]])
        #expect(lastRows.count == 5)
        ids += try lastRows.map { try #require($0["id"] as? String) }
        #expect(Set(ids).count == 45)
        let completed = collector.selected(ids)
        #expect(completed.contains(#""totalExpense":"45""#) && completed.contains(#""selectionCount":45"#))
        #expect(collector.queryFailure == nil && collector.reports.count == 1)

        // A pending scope from the previous question must not poison a new turn.
        _ = collector.list(arguments, offset: 0, limit: 40)
        collector.beginTurn()
        let freshJSON = collector.recentContext()
        let fresh = try #require(JSONSerialization.jsonObject(with: Data(freshJSON.utf8)) as? [String: Any])
        let freshRows = try recentRows(fresh)
        let freshID = try #require(freshRows.first?["id"])
        #expect(freshID != previewID && !ids.contains(freshID))
        #expect(collector.selected([freshID]).contains(#""totalExpense":"1""#))
        #expect(collector.queryFailure == nil && collector.reports.count == 1 && !ledger.context.hasChanges)
    }

    @available(iOS 26, *)
    @Test("A terminal page cannot bypass unread middle pages before a selected total", arguments: [80, 100])
    func skippedMiddlePages(_ terminalOffset: Int) throws {
        let ledger = try CurrencyTestStore()
        for index in 0..<100 {
            let row = try ledger.transaction(amount: "1", currency: "RUB")
            row.title = "Rental \(index)"
        }
        try ledger.context.save()
        let collector = SpendingQueryCollector(store: SpendingDataStore(context: ledger.context, baseCurrency: "RUB"))
        let arguments = SpendingQueryTool.Arguments(period: "allTime", startDate: "", endDate: "",
            kind: "expense", category: "all", search: "")
        collector.beginTurn()
        let firstJSON = collector.list(arguments, offset: 0, limit: 40)
        let first = try #require(JSONSerialization.jsonObject(with: Data(firstJSON.utf8)) as? [String: Any])
        let firstRows = try #require(first["transactions"] as? [[String: Any]])
        let ids = try firstRows.map { try #require($0["id"] as? String) }
        #expect(ids.count == 40 && first["nextOffset"] as? Int == 40)

        let terminalJSON = collector.list(arguments, offset: terminalOffset, limit: 40)
        let terminal = try #require(JSONSerialization.jsonObject(with: Data(terminalJSON.utf8)) as? [String: Any])
        #expect(terminal["nextOffset"] == nil && terminal["totalMatchingCount"] as? Int == 100)
        let terminalRows = try #require(terminal["transactions"] as? [[String: Any]])
        #expect(terminalRows.count == (terminalOffset == 80 ? 20 : 0))
        let blockedJSON = collector.selected(ids)
        let blocked = try #require(JSONSerialization.jsonObject(with: Data(blockedJSON.utf8)) as? [String: Any])
        let error = try #require(blocked["error"] as? String)
        #expect(error.contains("Finish the transaction pages") && error.contains(#""offset":40"#))
        #expect(collector.queryFailure == nil && collector.reports.isEmpty)

        _ = collector.list(arguments, offset: 40, limit: 40)
        if terminalOffset == 100 {
            #expect(collector.selected(ids).contains("Finish the transaction pages"))
            _ = collector.list(arguments, offset: 80, limit: 40)
        }
        let verified = collector.selected(ids)
        #expect(verified.contains(#""totalExpense":"40""#) && verified.contains(#""selectionCount":40"#))
        #expect(collector.queryFailure == nil && collector.reports.count == 1 && !ledger.context.hasChanges)
    }

    @available(iOS 26, *)
    @Test("A stale selection invalidates old page coverage before reinspection")
    func staleSelectionResetsPageCoverage() throws {
        let ledger = try CurrencyTestStore()
        for index in 0..<100 {
            let row = try ledger.transaction(amount: "1", currency: "RUB")
            row.title = "Rental \(index)"
        }
        try ledger.context.save()
        let collector = SpendingQueryCollector(store: SpendingDataStore(context: ledger.context, baseCurrency: "RUB"))
        let arguments = SpendingQueryTool.Arguments(period: "allTime", startDate: "", endDate: "",
            kind: "expense", category: "all", search: "")
        collector.beginTurn()
        var oldIDs: [String] = []
        for offset in [0, 40, 80] {
            let json = collector.list(arguments, offset: offset, limit: 40)
            let page = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            let rows = try #require(page["transactions"] as? [[String: Any]])
            oldIDs += try rows.map { try #require($0["id"] as? String) }
        }
        #expect(oldIDs.count == 100 && Set(oldIDs).count == 100)
        let inserted = try ledger.transaction(amount: "2", currency: "RUB")
        inserted.title = "New rental after inspection"
        try ledger.context.save()
        let staleJSON = collector.selected(oldIDs)
        let stale = try #require(JSONSerialization.jsonObject(with: Data(staleJSON.utf8)) as? [String: Any])
        #expect(stale["error"] != nil && stale["totalExpense"] == nil)
        #expect(collector.queryFailure == nil && collector.reports.isEmpty)

        let firstJSON = collector.list(arguments, offset: 0, limit: 40)
        let first = try #require(JSONSerialization.jsonObject(with: Data(firstJSON.utf8)) as? [String: Any])
        #expect(first["totalMatchingCount"] as? Int == 101 && first["nextOffset"] as? Int == 40)
        let firstRows = try #require(first["transactions"] as? [[String: Any]])
        let freshIDs = try firstRows.map { try #require($0["id"] as? String) }
        #expect(freshIDs.count == 40 && Set(freshIDs).isDisjoint(with: Set(oldIDs)))
        let blockedJSON = collector.selected(freshIDs)
        let blocked = try #require(JSONSerialization.jsonObject(with: Data(blockedJSON.utf8)) as? [String: Any])
        let error = try #require(blocked["error"] as? String)
        #expect(error.contains("Finish the transaction pages") && error.contains(#""offset":40"#))
        #expect(!error.contains(#""offset":100"#))
        #expect(collector.queryFailure == nil && collector.reports.isEmpty && !ledger.context.hasChanges)
    }

    @available(iOS 26, *)
    @Test("Invalid filters return tool feedback that the model can correct")
    func invalidFilterRecovery() async throws {
        let fixture = try ChatSettingsFixture()
        defer { fixture.dispose() }
        try fixture.enable()
        let ledger = try CurrencyTestStore()
        _ = try ledger.transaction(amount: "125", currency: "RUB")
        var calls = 0
        let model = OpenRouterSpendingChatModel(settings: fixture.settings,
            store: SpendingDataStore(context: ledger.context, baseCurrency: "RUB")) { _, _, messages, tools in
                #expect(tools)
                calls += 1
                if calls == 1 {
                    return .init(role: "assistant", tool_calls: [.init(id: "bad-filter",
                        function: .init(name: "query_spending", arguments: #"{"period":"custom","startDate":"not-date","endDate":"2026-10-05","kind":"expense"}"#))])
                }
                if calls == 2 {
                    let error = try #require(messages.last?.content)
                    #expect(error.contains("error"))
                    return queryPlan()
                }
                let payload = try #require(messages.last?.content)
                #expect(payload.contains(#""totalExpense":"125""#))
                return .init(role: "assistant", content: "Recorded expenses: 125 RUB.")
            }
        model.send("My expenses?")
        await model.generationTask?.value
        #expect(calls == 3 && model.messages.last?.role == .assistant)
        #expect(model.messages.last?.reports.count == 1 && model.currentReports.first?.report.totalExpense == "125")
    }

    @available(iOS 26, *)
    @Test("An investigation can finish after the former twelve-round cutoff")
    func longerInvestigationCompletes() async throws {
        let fixture = try ChatSettingsFixture()
        defer { fixture.dispose() }
        try fixture.enable()
        let ledger = try CurrencyTestStore()
        var calls = 0
        let model = OpenRouterSpendingChatModel(settings: fixture.settings,
            store: SpendingDataStore(context: ledger.context, baseCurrency: "RUB")) { _, _, _, _ in
                calls += 1
                if calls == 14 { return .init(role: "assistant", content: "Investigation finished.") }
                return .init(role: "assistant", tool_calls: [.init(id: "catalogue-\(calls)",
                    function: .init(name: "get_spending_catalogue", arguments: "{}"))])
            }
        model.send("Review my renovation spending since 2025")
        await model.generationTask?.value
        #expect(calls == 14 && !model.isGenerating)
        #expect(model.messages.last?.role == .assistant && model.messages.last?.text == "Investigation finished.")
    }

    @available(iOS 26, *)
    @Test("An unfinished investigation is bounded to thirty-two model rounds")
    func investigationRoundLimit() async throws {
        let fixture = try ChatSettingsFixture()
        defer { fixture.dispose() }
        try fixture.enable()
        let ledger = try CurrencyTestStore()
        var calls = 0
        let model = OpenRouterSpendingChatModel(settings: fixture.settings,
            store: SpendingDataStore(context: ledger.context, baseCurrency: "RUB")) { _, _, _, tools in
                #expect(tools)
                calls += 1
                return .init(role: "assistant", tool_calls: [.init(id: "catalogue-\(calls)",
                    function: .init(name: "get_spending_catalogue", arguments: "{}"))])
            }
        model.send("Explore everything")
        await model.generationTask?.value
        #expect(calls == SpendingInvestigationLimits.modelRounds && !model.isGenerating && model.currentReports.isEmpty)
        #expect(model.messages.last?.role == .notice)
        #expect(model.messages.last?.text.contains("limit") == true)
    }

    @available(iOS 26, *)
    @Test("The model discovers dynamic saved types and chooses explicit category scope", arguments: [false, true])
    func dynamicTypeInvestigation(_ restrictHousing: Bool) async throws {
        let fixture = try ChatSettingsFixture()
        defer { fixture.dispose() }
        try fixture.enable()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let types = SpendingClassificationStore(defaults: fixture.defaults,
            fileURL: directory.appendingPathComponent("types.json"), settings: fixture.settings)
        let ledger = try CurrencyTestStore()
        let travel = try ledger.transaction(amount: "59500", currency: "RUB")
        travel.title = "Велигама"; travel.tag = "travel"
        let housing = try ledger.transaction(amount: "1000", currency: "RUB")
        housing.title = "Apartment"; housing.tag = "housing"
        try ledger.context.save()
        try types.setManual(label: "Transient stay", for: travel)
        try types.setManual(label: "Transient stay", for: housing)
        var calls = 0
        let model = OpenRouterSpendingChatModel(settings: fixture.settings,
            store: SpendingDataStore(context: ledger.context, baseCurrency: "RUB", classifications: types)) { _, _, messages, tools in
                #expect(tools)
                calls += 1
                if calls == 1 {
                    return .init(role: "assistant", tool_calls: [.init(id: "discover",
                        function: .init(name: "get_spending_catalogue", arguments: "{}"))])
                }
                if calls == 2 {
                    let payload = try #require(messages.last?.content)
                    #expect(payload.contains("Transient stay"))
                    return .init(role: "assistant", tool_calls: [.init(id: "inspect-types",
                        function: .init(name: "list_spending_transactions", arguments: #"{"period":"allTime","startDate":"","endDate":"","kind":"expense","offset":0,"limit":40}"#))])
                }
                if calls == 3 {
                    let payload = try #require(messages.last?.content)
                    let page = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
                    let rows = try #require(page["transactions"] as? [[String: Any]])
                    #expect(rows.count == 2 && page["totalMatchingCount"] as? Int == 2)
                    // The model, not a title/type/category filter, chooses the
                    // intended subset from the evidence it has actually read.
                    let matching = rows.filter {
                        $0["spendingType"] as? String == "Transient stay"
                            && (!restrictHousing || $0["category"] as? String == "housing")
                    }
                    let tokens = try matching.map { try #require($0["id"] as? String) }
                    #expect(tokens.count == (restrictHousing ? 1 : 2))
                    let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["ids": tokens]), as: UTF8.self)
                    return .init(role: "assistant", tool_calls: [.init(id: "by-selection",
                        function: .init(name: "query_selected_transactions", arguments: arguments))])
                }
                let payload = try #require(messages.last?.content)
                #expect(payload.contains(restrictHousing ? #""totalExpense":"1000""# : #""totalExpense":"60500""#))
                return .init(role: "assistant", content: "Verified saved-type matches.")
            }
        model.send(restrictHousing ? "Transient stays within Housing?" : "How much for transient stays?")
        await model.generationTask?.value
        let report = try #require(model.messages.last?.reports.first?.report)
        #expect(calls == 4 && report.selectionCount == (restrictHousing ? 1 : 2))
        #expect(report.totalExpense == (restrictHousing ? "1000" : "60500"))
    }

    @available(iOS 26, *)
    @Test("Iterative answers use fresh local totals and redact internal IDs, notes and receipt data")
    func verifiedReport() async throws {
        let fixture = try ChatSettingsFixture()
        defer { fixture.dispose() }
        try fixture.enable()
        let store = try CurrencyTestStore()
        let transaction = try store.transaction(amount: "125", currency: "RUB")
        transaction.title = "Lunch"
        transaction.note = "NEVER SEND THIS NOTE"
        try store.context.save()
        let original = LedgerRecord(transaction)
        var requests: [[OpenRouterMessage]] = []
        let model = OpenRouterSpendingChatModel(settings: fixture.settings,
            store: SpendingDataStore(context: store.context, baseCurrency: "RUB")) { _, _, messages, tools in
                requests.append(messages)
                #expect(tools)
                return messages.last?.role == "tool" ? .init(role: "assistant", content: "Recorded expenses: 125 RUB.") : queryPlan()
            }
        model.send("What did I spend?")
        await model.generationTask?.value
        #expect(requests.count == 2 && !model.isGenerating)
        let answer = try #require(model.messages.last)
        #expect(answer.role == .assistant && answer.reports.count == 1)
        #expect(answer.reports.first?.report.totalExpense == "125")
        let payload = try #require(requests.last?.last?.content)
        let report = try #require(try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        #expect(report["totalExpense"] as? String == "125")
        #expect(report["topTransactions"] == nil && report["categoryTotals"] == nil)
        #expect(report["category"] == nil && report["titleSearchTerms"] == nil && report["spendingTypes"] == nil)
        let transmitted = requests.flatMap { $0 }.compactMap(\.content).joined(separator: "\n")
        #expect(!transmitted.contains("NEVER SEND THIS NOTE") && !transmitted.contains("x-coredata"))
        #expect(LedgerRecord(transaction) == original && !store.context.hasChanges)
    }

    @available(iOS 26, *)
    @Test("The model selects multilingual evidence again on follow-up without stale query-filter injection")
    func crossLanguageFollowUp() async throws {
        let fixture = try ChatSettingsFixture()
        defer { fixture.dispose() }
        try fixture.enable()
        let store = try CurrencyTestStore()
        let rent = try store.transaction(amount: "59500", currency: "RUB")
        rent.title = "аренда велигама 18.10 - 12.11"
        rent.tag = "travel"
        rent.occuredOn = Date()
        let other = try store.transaction(amount: "7230", currency: "RUB")
        other.title = "автобус"
        other.tag = "travel"
        other.occuredOn = Date()
        try store.context.save()
        var planningRequests: [[OpenRouterMessage]] = []
        var selectedTokens: [String] = []
        let model = OpenRouterSpendingChatModel(settings: fixture.settings,
            store: SpendingDataStore(context: store.context, baseCurrency: "RUB")) { _, _, messages, tools in
                #expect(tools)
                if messages.last?.role != "tool" {
                    planningRequests.append(messages)
                    let system = try #require(messages.first?.content)
                    let marker = try #require(system.range(of: "Recent transaction context: "))
                    let json = String(system[marker.upperBound...]).components(separatedBy: "\n")[0]
                    let context = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
                    let rows = try recentRows(context)
                    let matching = try #require(rows.first { $0["untrustedTitle"]?.hasPrefix("аренда") == true })
                    let token = try #require(matching["id"])
                    selectedTokens.append(token)
                    let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["ids": [token]]), as: UTF8.self)
                    return .init(role: "assistant", tool_calls: [.init(id: "rent-query",
                        function: .init(name: "query_selected_transactions", arguments: arguments))])
                }
                let payload = try #require(messages.last?.content)
                #expect(payload.contains(#""totalExpense":"59500""#) && payload.contains(#""selectionCount":1"#))
                return .init(role: "assistant", content: "Rent-labeled Travel expenses: 59,500 RUB.")
            }
        model.send("How much of Travel was rent?")
        await model.generationTask?.value
        #expect(model.messages.last?.reports.first?.report.totalExpense == "59500")
        model.send("Yes, in that category, not Housing")
        await model.generationTask?.value
        #expect(planningRequests.count == 2)
        #expect(selectedTokens.count == 2 && Set(selectedTokens).count == 2)
        let followUp = try #require(planningRequests.last)
        let system = try #require(followUp.first?.content)
        #expect(!system.contains("Previous query filters") && !system.contains("Previous query scope"))
        #expect(followUp.contains { $0.role == "user" && $0.content == "How much of Travel was rent?" })
        #expect(followUp.last?.content == "Yes, in that category, not Housing")
    }

    @available(iOS 26, *)
    @Test("Concurrent continuations preserve both chats, and another window cannot revive deleted history")
    func historyAcrossWindows() async throws {
        let fixture = try ChatSettingsFixture()
        defer { fixture.dispose() }
        try fixture.enable()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = SpendingChatHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        let store = try CurrencyTestStore()
        _ = try store.transaction(amount: "125", currency: "RUB")
        let saved = SavedSpendingConversation(id: UUID(), provider: .openRouter,
            createdAt: Date(), updatedAt: Date(), messages: [.init(role: .user, text: "Earlier question", reports: [])])
        #expect(history.upsert(saved))
        var calls = 0
        func engine() -> OpenRouterSpendingChatModel {
            OpenRouterSpendingChatModel(settings: fixture.settings,
                store: SpendingDataStore(context: store.context, baseCurrency: "RUB")) { _, _, messages, tools in
                    calls += 1
                    #expect(tools)
                    return messages.last?.role == "tool" ? .init(role: "assistant", content: "Recorded expenses: 125 RUB.") : queryPlan()
                }
        }
        let firstEngine = engine(), secondEngine = engine(), thirdEngine = engine()
        let first = SpendingChatModel(historyStore: history, settings: fixture.settings, remoteEngine: firstEngine)
        let second = SpendingChatModel(historyStore: history, settings: fixture.settings, remoteEngine: secondEngine)
        #expect(first.resume(saved) && second.resume(saved) && calls == 0)
        first.send("First window question")
        await firstEngine.generationTask?.value
        second.send("Second window question")
        await secondEngine.generationTask?.value
        #expect(history.conversations.count == 2 && calls == 4)
        let original = try #require(history.conversations.first(where: { $0.id == saved.id }))
        let fork = try #require(history.conversations.first(where: { $0.id != saved.id }))
        #expect(original.messages.contains { $0.text == "First window question" })
        #expect(!original.messages.contains { $0.text == "Second window question" })
        #expect(fork.messages.contains { $0.text == "Second window question" })
        let third = SpendingChatModel(historyStore: history, settings: fixture.settings, remoteEngine: thirdEngine)
        #expect(third.resume(fork))
        #expect(second.deleteConversation(fork.id))
        let previousCalls = calls
        third.send("Should not be sent after deletion")
        await thirdEngine.generationTask?.value
        #expect(calls == previousCalls && third.messages.isEmpty)
        #expect(history.conversations.map(\.id) == [saved.id])
        #expect(third.newChat() && history.conversations.count == 1)
    }

    @available(iOS 26, *)
    @Test("Deleting unrelated history preserves an in-flight answer and follow-up context", arguments: [false, true])
    func unrelatedHistoryDeletion(_ failsToSave: Bool) async throws {
        let fixture = try ChatSettingsFixture()
        defer { fixture.dispose() }
        try fixture.enable()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("archive")
        let preserved = directory.appendingPathComponent("preserved")
        let file = archive.appendingPathComponent("history.json")
        let history = SpendingChatHistoryStore(fileURL: file)
        let unrelated = SavedSpendingConversation(id: UUID(), provider: .openRouter,
            createdAt: Date(), updatedAt: Date(), messages: [.init(role: .user, text: "Older chat", reports: [])])
        #expect(history.upsert(unrelated))
        let ledger = try CurrencyTestStore()
        let classifications = SpendingClassificationStore(defaults: fixture.defaults,
            fileURL: directory.appendingPathComponent("types.json"), settings: fixture.settings,
            completion: { _, _, _ in throw OpenRouterError.malformed })
        var calls = 0
        var model: SpendingChatModel!
        let engine = OpenRouterSpendingChatModel(settings: fixture.settings,
            store: SpendingDataStore(context: ledger.context, baseCurrency: "RUB",
                categoryDefaults: fixture.defaults, classifications: classifications)) { _, _, messages, _ in
                calls += 1
                if calls == 1 {
                    let messageIDs = model.messages.map(\.id)
                    #expect(model.isGenerating)
                    if failsToSave {
                        try FileManager.default.moveItem(at: archive, to: preserved)
                        try Data("blocked".utf8).write(to: archive)
                    }
                    #expect(model.deleteConversation(unrelated.id) == !failsToSave)
                    #expect(model.isGenerating && model.messages.map(\.id) == messageIDs)
                    #expect(history.conversations.contains { $0.id == unrelated.id } == failsToSave)
                    if failsToSave {
                        #expect(history.errorMessage != nil)
                        try FileManager.default.removeItem(at: archive)
                        try FileManager.default.moveItem(at: preserved, to: archive)
                    }
                    return .init(role: "assistant", content: "First answer")
                }
                #expect(messages.contains { $0.role == "user" && $0.content == "First question" })
                #expect(messages.contains { $0.role == "assistant" && $0.content == "First answer" })
                return .init(role: "assistant", content: "Follow-up answer")
            }
        model = SpendingChatModel(historyStore: history, settings: fixture.settings, remoteEngine: engine)
        model.send("First question")
        await engine.generationTask?.value
        #expect(model.messages.last?.text == "First answer" && !model.isGenerating)
        let activeID = try #require(history.conversations.first { $0.id != unrelated.id }?.id)
        model.send("Follow-up question")
        await engine.generationTask?.value
        #expect(calls == 2 && model.messages.last?.text == "Follow-up answer")
        #expect(!model.messages.contains { $0.role == .notice })
        let reloaded = SpendingChatHistoryStore(fileURL: file)
        #expect(reloaded.errorMessage == nil)
        #expect(reloaded.conversations.first { $0.id == activeID }?.messages.map(\.id) == model.messages.map(\.id))
        #expect(reloaded.conversations.contains { $0.id == unrelated.id } == failsToSave)
    }

    @available(iOS 26, *)
    @Test("A late answer cannot resurrect history deleted during an in-flight request")
    func deletionDuringAnswer() async throws {
        let fixture = try ChatSettingsFixture()
        defer { fixture.dispose() }
        try fixture.enable()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = SpendingChatHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        let saved = SavedSpendingConversation(id: UUID(), provider: .openRouter,
            createdAt: Date(), updatedAt: Date(), messages: [.init(role: .user, text: "Original question", reports: [])])
        #expect(history.upsert(saved))
        let store = try CurrencyTestStore()
        _ = try store.transaction(amount: "125", currency: "RUB")
        let engine = OpenRouterSpendingChatModel(settings: fixture.settings,
            store: SpendingDataStore(context: store.context, baseCurrency: "RUB")) { _, _, messages, tools in
                #expect(tools)
                if messages.last?.role != "tool" { #expect(history.delete(id: saved.id)); return queryPlan() }
                return .init(role: "assistant", content: "Recorded expenses: 125 RUB.")
            }
        let model = SpendingChatModel(historyStore: history, settings: fixture.settings, remoteEngine: engine)
        #expect(model.resume(saved))
        model.send("New question")
        await engine.generationTask?.value
        #expect(history.conversations.isEmpty)
        #expect(model.historyNotice != nil)
        #expect(model.newChat() && model.messages.isEmpty && history.conversations.isEmpty)
    }

    @available(iOS 26, *)
    @Test("Failed answer saves remain visible and retry must persist them before New Chat clears the window")
    func retryUnsavedAnswer() async throws {
        let fixture = try ChatSettingsFixture()
        defer { fixture.dispose() }
        try fixture.enable()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("archive")
        let preserved = directory.appendingPathComponent("preserved")
        let file = archive.appendingPathComponent("history.json")
        let history = SpendingChatHistoryStore(fileURL: file)
        let store = try CurrencyTestStore()
        _ = try store.transaction(amount: "125", currency: "RUB")
        let engine = OpenRouterSpendingChatModel(settings: fixture.settings,
            store: SpendingDataStore(context: store.context, baseCurrency: "RUB")) { _, _, messages, tools in
                #expect(tools)
                if messages.last?.role != "tool" { return queryPlan() }
                try FileManager.default.moveItem(at: archive, to: preserved)
                try Data("blocked".utf8).write(to: archive)
                return .init(role: "assistant", content: "Recorded expenses: 125 RUB.")
            }
        let model = SpendingChatModel(historyStore: history, settings: fixture.settings, remoteEngine: engine)
        model.send("My expenses?")
        await engine.generationTask?.value
        #expect(model.messages.last?.role == .assistant && history.errorMessage != nil)
        #expect(history.conversations.first?.messages.count == 1)
        #expect(!model.newChat() && model.messages.last?.role == .assistant)
        try FileManager.default.removeItem(at: archive)
        try FileManager.default.moveItem(at: preserved, to: archive)
        model.retryHistorySave()
        #expect(history.errorMessage == nil && history.conversations.first?.messages.last?.role == .assistant)
        #expect(model.newChat() && model.messages.isEmpty)
        let reloaded = SpendingChatHistoryStore(fileURL: file)
        #expect(reloaded.conversations.first?.messages.last?.text == "Recorded expenses: 125 RUB.")
        #expect(reloaded.conversations.first?.messages.last?.reports.first?.report.totalExpense == "125")
    }

    @available(iOS 26, *)
    @Test("Stopping or changing settings during planning prevents query/final requests", arguments: [false, true])
    func stalePlanning(_ stop: Bool) async throws {
        let fixture = try ChatSettingsFixture()
        defer { fixture.dispose() }
        try fixture.enable()
        let store = try CurrencyTestStore()
        var calls = 0
        var model: OpenRouterSpendingChatModel!
        model = OpenRouterSpendingChatModel(settings: fixture.settings,
            store: SpendingDataStore(context: store.context, baseCurrency: "RUB")) { _, _, _, _ in
                calls += 1
                if stop { model.stop() } else { try fixture.settings.disable(removeKey: false) }
                return queryPlan() // Simulates a late response after cancellation/privacy changes.
            }
        model.send("My expenses?")
        let task = model.generationTask
        await task?.value
        #expect(calls == 1 && !model.isGenerating && model.currentReports.isEmpty)
        #expect(!model.messages.contains { $0.role == .assistant })
    }

    @available(iOS 26, *)
    @Test("Revoking remote access before the generation task starts dispatches no AI request")
    func revokeBeforeDispatch() async throws {
        let fixture = try ChatSettingsFixture()
        defer { fixture.dispose() }
        try fixture.enable()
        let store = try CurrencyTestStore()
        var calls = 0
        let model = OpenRouterSpendingChatModel(settings: fixture.settings,
            store: SpendingDataStore(context: store.context, baseCurrency: "RUB")) { _, _, _, _ in
                calls += 1
                return queryPlan()
            }
        model.send("My expenses?")
        let task = model.generationTask
        try fixture.settings.disable(removeKey: false)
        await task?.value
        #expect(calls == 0 && !model.isGenerating && model.currentReports.isEmpty)
    }

    @available(iOS 26, *)
    @Test("New Chat removes previous remote conversation from subsequent requests")
    func clearContext() async throws {
        let fixture = try ChatSettingsFixture()
        defer { fixture.dispose() }
        try fixture.enable()
        let store = try CurrencyTestStore()
        var requests: [[OpenRouterMessage]] = []
        let model = OpenRouterSpendingChatModel(settings: fixture.settings,
            store: SpendingDataStore(context: store.context, baseCurrency: "RUB")) { _, _, messages, _ in
                requests.append(messages)
                return .init(role: "assistant", tool_calls: [.init(id: "clarify", function:
                    .init(name: "clarify_spending_question", arguments: #"{"question":"Which month?"}"#))])
            }
        model.send("First private question")
        await model.generationTask?.value
        model.newChat()
        #expect(model.messages.isEmpty)
        model.send("Second question")
        await model.generationTask?.value
        #expect(requests.count == 2)
        #expect(requests.last?.count == 2)
        #expect(requests.last?.last?.content == "Second question")
    }

    @available(iOS 26, *)
    @Test("A privacy change during final generation discards the late answer")
    func staleFinal() async throws {
        let fixture = try ChatSettingsFixture()
        defer { fixture.dispose() }
        try fixture.enable()
        let store = try CurrencyTestStore()
        _ = try store.transaction(amount: "125", currency: "RUB")
        var calls = 0
        let model = OpenRouterSpendingChatModel(settings: fixture.settings,
            store: SpendingDataStore(context: store.context, baseCurrency: "RUB")) { _, _, messages, tools in
                calls += 1
                #expect(tools)
                if messages.last?.role != "tool" { return queryPlan() }
                try fixture.settings.disable(removeKey: true)
                return .init(role: "assistant", content: "Late answer")
            }
        model.send("My expenses?")
        await model.generationTask?.value
        #expect(calls == 2 && !model.isGenerating)
        #expect(!model.messages.contains { $0.role == .assistant })
    }

    @available(iOS 26, *)
    @Test("Clarification executes no ledger query and needs only one AI request")
    func clarification() async throws {
        let fixture = try ChatSettingsFixture()
        defer { fixture.dispose() }
        try fixture.enable()
        let store = try CurrencyTestStore()
        var calls = 0
        let model = OpenRouterSpendingChatModel(settings: fixture.settings,
            store: SpendingDataStore(context: store.context, baseCurrency: "RUB")) { _, _, _, _ in
                calls += 1
                return .init(role: "assistant", tool_calls: [.init(id: "clarify", function:
                    .init(name: "clarify_spending_question", arguments: #"{"question":"Which month?"}"#))])
            }
        model.send("Was it more?")
        await model.generationTask?.value
        #expect(calls == 1 && model.currentReports.isEmpty)
        #expect(model.messages.last?.role == .clarification && model.messages.last?.text == "Which month?")
    }

    @available(iOS 26, *)
    @Test("A thousand supplied tokens fit the expanded selection contract; larger selections are rejected")
    func expandedSelectionPlan() throws {
        let ids = (0..<1_000).map { "tx_" + String(format: "%012d", $0) }
        func reply(_ tokens: [String]) throws -> OpenRouterMessage {
            let arguments = String(decoding: try JSONEncoder().encode(["ids": tokens]), as: UTF8.self)
            return .init(role: "assistant", tool_calls: [.init(id: "selection",
                function: .init(name: "query_selected_transactions", arguments: arguments))])
        }
        let message = try reply(ids)
        #expect(try #require(message.tool_calls?.first).function.arguments.utf8.count > 8_000)
        guard case .tools(let calls) = try OpenRouterSpendingPlan.decode(message),
              case .selected(let selected) = calls.first?.action else {
            Issue.record("Expanded selection was not decoded")
            return
        }
        #expect(selected == ids)
        #expect(throws: (any Error).self) { try OpenRouterSpendingPlan.decode(reply(ids + ["tx_extra"])) }
    }

    @available(iOS 26, *)
    @Test("Invalid or mixed plans are rejected before any tool executes", arguments: ["mixed", "duplicate", "tooMany", "unknown", "malformed"])
    func invalidPlan(_ scenario: String) throws {
        let query = OpenRouterToolCall(id: "one", function: .init(name: "query_spending", arguments: queryArguments))
        let clarification = OpenRouterToolCall(id: "two", function: .init(name: "clarify_spending_question", arguments: #"{"question":"Which month?"}"#))
        let calls: [OpenRouterToolCall]
        switch scenario {
        case "mixed": calls = [query, clarification]
        case "duplicate": calls = [query, query]
        case "tooMany": calls = [query, clarification, query, clarification]
        case "unknown": calls = [.init(id: "one", function: .init(name: "delete_transaction", arguments: "{}"))]
        default: calls = [.init(id: "one", function: .init(name: "query_spending", arguments: "{}"))]
        }
        #expect(throws: (any Error).self) { try OpenRouterSpendingPlan.decode(.init(role: "assistant", tool_calls: calls)) }
    }
}
