import Foundation

struct ExpenseCategory: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var name: String
    var symbol: String
    var isArchived = false
}

enum CategoryCatalogError: LocalizedError {
    case invalid, duplicateName, noActiveCategory, concurrentEdit
    var errorDescription: String? {
        switch self {
        case .invalid: return "Use a name of 1–40 characters and a supported symbol. Up to 100 categories are supported."
        case .duplicateName: return "A category already uses that name. Choose a different name, including for archived categories."
        case .noActiveCategory: return "Keep at least one category active."
        case .concurrentEdit: return "This category changed while you were editing it. Close and reopen the editor to use the latest version."
        }
    }
}

/// Existing tag strings remain stable identities. Names and symbols are presentation metadata.
/// Archiving only hides a category from new selections; it never rewrites ledger records.
enum CategoryCatalog {
    static let storageKey = "categories.catalog.v1"
    static let defaults: [ExpenseCategory] = [
        .init(id: "transport", name: "Transport", symbol: "tram.fill"),
        .init(id: "food", name: "Food", symbol: "fork.knife"),
        .init(id: "housing", name: "Housing", symbol: "house.fill"),
        .init(id: "insurance", name: "Insurance", symbol: "shield.fill"),
        .init(id: "medical", name: "Medical", symbol: "cross.case.fill"),
        .init(id: "savings", name: "Savings", symbol: "banknote.fill"),
        .init(id: "personal", name: "Personal", symbol: "person.fill"),
        .init(id: "entertainment", name: "Entertainment", symbol: "popcorn.fill"),
        .init(id: "others", name: "Others", symbol: "square.grid.2x2.fill"),
        .init(id: "utilities", name: "Utilities", symbol: "bolt.fill"),
        .init(id: "car", name: "Car", symbol: "car.fill"),
        .init(id: "travel", name: "Travel", symbol: "airplane")
    ]
    static let symbols = defaults.map(\.symbol) + [
        "cart.fill", "bag.fill", "cup.and.saucer.fill", "pawprint.fill", "book.fill",
        "graduationcap.fill", "gift.fill", "heart.fill", "dumbbell.fill", "gamecontroller.fill",
        "music.note", "wifi", "phone.fill", "laptopcomputer", "wrench.fill", "leaf.fill",
        "tshirt.fill", "scissors", "briefcase.fill", "building.2.fill", "creditcard.fill", "tag.fill"
    ]

    static func decode(_ data: Data) -> [ExpenseCategory] {
        guard !data.isEmpty, data.count <= 100_000,
              let items = try? JSONDecoder().decode([ExpenseCategory].self, from: data),
              (try? validate(items)) != nil else { return defaults }
        return items
    }

    static func load(defaults preferences: UserDefaults = .standard) -> [ExpenseCategory] {
        decode(preferences.data(forKey: storageKey) ?? Data())
    }

    static func save(_ items: [ExpenseCategory], defaults preferences: UserDefaults = .standard) throws {
        try validate(items)
        preferences.set(try JSONEncoder().encode(items), forKey: storageKey)
    }

    static func applying(_ updated: ExpenseCategory, replacing original: ExpenseCategory?,
                         in items: [ExpenseCategory]) throws -> [ExpenseCategory] {
        var result = items
        if let original {
            guard original.id == updated.id, let index = result.firstIndex(where: { $0.id == original.id }),
                  result[index] == original else { throw CategoryCatalogError.concurrentEdit }
            result[index] = updated
        } else {
            guard !result.contains(where: { $0.id == updated.id }) else { throw CategoryCatalogError.concurrentEdit }
            result.append(updated)
        }
        try validate(result)
        return result
    }

    static func validate(_ items: [ExpenseCategory]) throws {
        let builtins = Set(defaults.map(\.id))
        guard items.count <= 100, builtins.isSubset(of: Set(items.map(\.id))) else {
            throw CategoryCatalogError.invalid
        }
        var ids = Set<String>()
        var names = Set<String>()
        for item in items {
            let customID = item.id.hasPrefix("custom.") && UUID(uuidString: String(item.id.dropFirst(7))) != nil
            guard (builtins.contains(item.id) || customID), ids.insert(item.id).inserted,
                  !item.name.isEmpty, item.name.count <= 40, item.name.utf8.count <= 160,
                  item.name == item.name.trimmingCharacters(in: .whitespacesAndNewlines),
                  !item.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  symbols.contains(item.symbol) else { throw CategoryCatalogError.invalid }
            let normalized = item.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard names.insert(normalized).inserted else { throw CategoryCatalogError.duplicateName }
        }
        guard items.contains(where: { !$0.isArchived }) else { throw CategoryCatalogError.noActiveCategory }
    }

    static func choices(in items: [ExpenseCategory], preserving id: String? = nil) -> [ExpenseCategory] {
        var choices = items.filter { !$0.isArchived || $0.id == id }
        if let id, !items.contains(where: { $0.id == id }) {
            choices.append(.init(id: id, name: id.isEmpty ? "Uncategorized" : id, symbol: "tag.fill", isArchived: true))
        }
        return choices
    }

    static func title(for id: String) -> String {
        load().first { $0.id == id }?.name ?? (id.isEmpty ? "Uncategorized" : id)
    }

    static func symbol(for id: String) -> String {
        load().first { $0.id == id }?.symbol ?? "tag.fill"
    }
}
