import Foundation
import Observation

struct SavedSpendingConversation: Codable, Identifiable {
    let id: UUID
    let provider: OpenRouterSettings.Provider
    let createdAt: Date
    var updatedAt: Date
    var messages: [SpendingChatMessage]

    var title: String {
        let text = messages.first(where: { $0.role == .user })?.text
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "Spending conversation" : String(text.prefix(80))
    }

    var preview: String { String((messages.last?.text ?? "").prefix(120)) }
}

/// Local, deliberately bounded storage. A damaged archive is never implicitly replaced.
@MainActor @Observable
final class SpendingChatHistoryStore {
    static let shared = SpendingChatHistoryStore()
    private(set) var conversations: [SavedSpendingConversation] = []
    private(set) var errorMessage: String?
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var loadFailed = false
    private static let byteLimit = 20 * 1_024 * 1_024

    private struct Envelope: Codable {
        let version: Int
        let conversations: [SavedSpendingConversation]
    }

    private enum ArchiveError: Error { case invalid, oversized }

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask)[0].appendingPathComponent("ChatHistory", isDirectory: true)
            .appendingPathComponent("history.json")
        reload()
    }

    func reload() {
        do {
            var loaded: [SavedSpendingConversation] = []
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forReadingFrom: fileURL)
                defer { try? handle.close() }
                // Read one extra byte to enforce the bound even if the file grows after opening.
                var data = Data()
                while let chunk = try handle.read(upToCount: min(64 * 1_024, Self.byteLimit + 1 - data.count)), !chunk.isEmpty {
                    data.append(chunk)
                    guard data.count <= Self.byteLimit else { throw ArchiveError.oversized }
                }
                let envelope = try JSONDecoder().decode(Envelope.self, from: data)
                guard envelope.version == 1 else { throw ArchiveError.invalid }
                try Self.validate(envelope.conversations)
                loaded = envelope.conversations
            }
            conversations = Self.sorted(loaded)
            loadFailed = false
            errorMessage = nil
        } catch {
            loadFailed = true
            errorMessage = "Saved chat history could not be read. The original file has been preserved. Reload it before making changes."
        }
    }

    @discardableResult
    func upsert(_ conversation: SavedSpendingConversation) -> Bool {
        var candidate = conversations.filter { $0.id != conversation.id }
        candidate.append(conversation)
        return persist(candidate)
    }

    @discardableResult
    func delete(id: UUID) -> Bool {
        persist(conversations.filter { $0.id != id })
    }

    func matching(_ search: String) -> [SavedSpendingConversation] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return conversations }
        return conversations.filter { conversation in
            conversation.title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || conversation.messages.contains {
                    $0.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                }
        }
    }

    private func persist(_ candidate: [SavedSpendingConversation]) -> Bool {
        guard !loadFailed else {
            errorMessage = "Saved chat history is unavailable. Reload it successfully before making changes."
            return false
        }
        do {
            try Self.validate(candidate)
            let ordered = Self.sorted(candidate)
            let data = try JSONEncoder().encode(Envelope(version: 1, conversations: ordered))
            guard data.count <= Self.byteLimit else { throw ArchiveError.oversized }
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var excludedDirectory = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excludedDirectory.setResourceValues(values)
            let temporary = directory.appendingPathComponent(".history-\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: temporary) }
            // Set protection and backup metadata before committing the replacement.
            try data.write(to: temporary, options: [.completeFileProtectionUntilFirstUserAuthentication])
            var excludedFile = temporary
            try excludedFile.setResourceValues(values)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary,
                    options: [.usingNewMetadataOnly])
            } else {
                try FileManager.default.moveItem(at: temporary, to: fileURL)
            }
            conversations = ordered
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Chat history could not be saved. Your previously saved conversations have not been changed."
            return false
        }
    }

    private static func sorted(_ values: [SavedSpendingConversation]) -> [SavedSpendingConversation] {
        values.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt
        }
    }

    private static func validate(_ values: [SavedSpendingConversation]) throws {
        guard values.count <= 500, Set(values.map(\.id)).count == values.count else { throw ArchiveError.invalid }
        for conversation in values {
            guard conversation.createdAt.timeIntervalSinceReferenceDate.isFinite,
                  conversation.updatedAt.timeIntervalSinceReferenceDate.isFinite,
                  conversation.messages.count <= 1_000,
                  Set(conversation.messages.map(\.id)).count == conversation.messages.count else { throw ArchiveError.invalid }
            for message in conversation.messages {
                guard message.text.utf8.count <= 16_000, message.reports.count <= 3,
                      Set(message.reports.map(\.id)).count == message.reports.count else { throw ArchiveError.invalid }
            }
        }
    }
}
