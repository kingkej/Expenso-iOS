import Foundation
import Testing
@testable import Expenso

/// Intentional filesystem integration tests, each with a private temporary directory.
@Suite("Local spending chat history")
@MainActor
struct SpendingChatHistoryTests {
    private func withFile(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("archive/history.json"))
    }

    private func conversation(provider: OpenRouterSettings.Provider = .onDevice,
                              updated: TimeInterval = 100,
                              messages: [SpendingChatMessage]? = nil) -> SavedSpendingConversation {
        SavedSpendingConversation(id: UUID(), provider: provider,
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: updated),
            messages: messages ?? [.init(role: .user, text: "Café spending?", reports: []),
                                  .init(role: .assistant, text: "Your taxi spending was 12 RUB.", reports: [])])
    }

    private func report() -> SpendingReport {
        SpendingReport(rangeLabel: "All time", timeZone: "Europe/Moscow", startDate: "", endDate: "",
            kind: "expense", category: "all", titleSearch: "rent", titleSearchTerms: ["rent", "rental"],
            currency: "RUB", candidateCount: 6, matchingCount: 6, incomeCount: 0, expenseCount: 6,
            skippedOtherKindCount: 0, excludedUnknownTypeCount: 0, excludedInvalidAmountCount: 0,
            totalIncome: "0", totalExpense: "210", netBalance: "-210", categories: [], topTransactions: [])
    }

    @Test("Messages, evidence IDs, provider and exact reports round-trip")
    func roundTrip() throws {
        try withFile { url in
            let evidence = SpendingEvidence(report: report())
            let message = SpendingChatMessage(role: .assistant, text: "Rental evidence", reports: [evidence])
            let saved = conversation(provider: .openRouter, messages: [
                .init(role: .user, text: "How much rent?", reports: []), message])
            let store = SpendingChatHistoryStore(fileURL: url)
            #expect(store.upsert(saved))
            let reloaded = SpendingChatHistoryStore(fileURL: url)
            let result = try #require(reloaded.conversations.first)
            #expect(result.id == saved.id && result.provider == .openRouter)
            #expect(result.createdAt == saved.createdAt && result.updatedAt == saved.updatedAt)
            #expect(result.messages.map(\.id) == saved.messages.map(\.id))
            #expect(result.messages.last?.reports.first?.id == evidence.id)
            let restoredReport = try #require(result.messages.last?.reports.first?.report)
            #expect(try restoredReport.json() == evidence.report.json())
            #expect(result.title == "How much rent?" && result.preview == "Rental evidence")
            #expect(reloaded.errorMessage == nil)
            #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
            #expect(try url.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        }
    }

    @Test("Ordering, updates, title and answer searches, and deletion")
    func orderingSearchDelete() throws {
        try withFile { url in
            let store = SpendingChatHistoryStore(fileURL: url)
            var older = conversation(updated: 10)
            let newer = conversation(updated: 20, messages: [.init(role: .user, text: "Rent", reports: [])])
            #expect(store.upsert(newer) && store.upsert(older))
            #expect(store.conversations.map(\.id) == [newer.id, older.id])
            #expect(store.matching("  CAFE ").map(\.id) == [older.id])
            #expect(store.matching("TAXI").map(\.id) == [older.id])
            #expect(store.matching(" ").count == 2)
            older.updatedAt = Date(timeIntervalSince1970: 30)
            #expect(store.upsert(older) && store.conversations.count == 2)
            #expect(store.conversations.first?.id == older.id)
            #expect(store.delete(id: older.id))
            #expect(SpendingChatHistoryStore(fileURL: url).conversations.map(\.id) == [newer.id])
        }
    }

    @Test("Malformed, unsupported and oversized archives remain untouched and block edits", arguments: ["malformed", "version", "oversized", "duplicate", "conversationLimit"])
    func invalidArchive(_ kind: String) throws {
        try withFile { url in
            let original = conversation()
            let seed = SpendingChatHistoryStore(fileURL: url)
            #expect(seed.upsert(original))
            var bytes = try Data(contentsOf: url)
            if kind == "malformed" { bytes = Data("not JSON".utf8) }
            if kind == "oversized" { bytes = Data(repeating: 0, count: 20 * 1_024 * 1_024 + 1) }
            if kind == "version" || kind == "duplicate" || kind == "conversationLimit" {
                var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                if kind == "version" { object["version"] = 2 }
                else if kind == "duplicate" {
                    let items = try #require(object["conversations"] as? [Any])
                    object["conversations"] = items + items
                } else {
                    var items: [[String: Any]] = []
                    let template = try #require((object["conversations"] as? [[String: Any]])?.first)
                    for _ in 0...500 {
                        var item = template
                        item["id"] = UUID().uuidString
                        items.append(item)
                    }
                    object["conversations"] = items
                }
                bytes = try JSONSerialization.data(withJSONObject: object)
            }
            try bytes.write(to: url)
            seed.reload()
            #expect(seed.conversations.first?.id == original.id)
            #expect(seed.errorMessage != nil)
            #expect(!seed.upsert(conversation()) && !seed.delete(id: original.id))
            #expect(try Data(contentsOf: url) == bytes)
            let blocked = SpendingChatHistoryStore(fileURL: url)
            #expect(blocked.conversations.isEmpty && blocked.errorMessage != nil)
            #expect(!blocked.upsert(conversation()))
            // Explicit repair followed by reload is the only way to unblock writes.
            try FileManager.default.removeItem(at: url)
            blocked.reload()
            #expect(blocked.errorMessage == nil && blocked.upsert(conversation()))
        }
    }

    @Test("Unreadable archive location fails closed without replacing it")
    func unreadable() throws {
        try withFile { url in
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let store = SpendingChatHistoryStore(fileURL: url)
            #expect(store.errorMessage != nil && !store.upsert(conversation()))
            var directory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue)
        }
    }

    @Test("Invalid candidates leave the saved file and published conversations unchanged", arguments: ["text", "messages", "reports", "duplicateMessage", "encodedBytes"])
    func candidateLimits(_ kind: String) throws {
        try withFile { url in
            let store = SpendingChatHistoryStore(fileURL: url)
            let original = conversation()
            #expect(store.upsert(original))
            let bytes = try Data(contentsOf: url)
            var candidate = conversation()
            switch kind {
            case "text": candidate.messages = [.init(role: .user, text: String(repeating: "я", count: 8_001), reports: [])]
            case "messages": candidate.messages = (0...1_000).map { .init(role: .user, text: String($0), reports: []) }
            case "reports": candidate.messages = [.init(role: .assistant, text: "Evidence", reports: (0..<4).map { _ in .init(report: report()) })]
            case "encodedBytes":
                var oversizedReport = report()
                oversizedReport.dataUsageNotice = String(repeating: "a", count: 11 * 1_024 * 1_024)
                candidate.messages = [.init(role: .assistant, text: "Evidence", reports: [
                    .init(report: oversizedReport), .init(report: oversizedReport)])]
            default:
                let message = SpendingChatMessage(role: .user, text: "Repeated", reports: [])
                candidate.messages = [message, message]
            }
            #expect(!store.upsert(candidate))
            #expect(store.conversations.map(\.id) == [original.id] && store.errorMessage != nil)
            #expect(try Data(contentsOf: url) == bytes)
        }
    }

    @Test("A write failure does not publish a candidate or damage the previous archive")
    func writeFailure() throws {
        try withFile { url in
            let store = SpendingChatHistoryStore(fileURL: url)
            let original = conversation()
            #expect(store.upsert(original))
            let bytes = try Data(contentsOf: url)
            let directory = url.deletingLastPathComponent()
            let preserved = directory.appendingPathExtension("preserved")
            try FileManager.default.moveItem(at: directory, to: preserved)
            // A regular file blocking the parent path deterministically prevents a write.
            try Data("blocked".utf8).write(to: directory)
            #expect(!store.upsert(conversation(updated: 200)))
            #expect(store.conversations.map(\.id) == [original.id] && store.errorMessage != nil)
            #expect(try Data(contentsOf: preserved.appendingPathComponent("history.json")) == bytes)
        }
    }
}
