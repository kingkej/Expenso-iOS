import Combine
import CoreData
import Foundation

/// One app-owned undo boundary. Undo survives navigation, not an app restart.
@MainActor
final class LedgerMutationService: ObservableObject {
    @Published private(set) var undoDescription: String?
    @Published private(set) var restoreGeneration = 0
    var hasUndo: Bool { !undoEntries.isEmpty }

    private struct CategoryChange {
        let id: NSManagedObjectID
        let before: LedgerRecord
        let after: LedgerRecord
    }
    private enum UndoAction {
        case deletion([LedgerRecord])
        case category([CategoryChange])
    }
    private struct UndoEntry {
        let coordinator: NSPersistentStoreCoordinator
        let description: String
        let action: UndoAction
        var retainedByteCount: Int {
            switch action {
            case .deletion(let records): return records.reduce(0) { $0 + $1.retainedByteCount }
            case .category(let changes): return changes.reduce(0) { $0 + $1.before.retainedByteCount + $1.after.retainedByteCount }
            }
        }
    }
    private let undoByteLimit: Int
    private let categoryDefaults: UserDefaults
    private var undoEntries: [UndoEntry] = []
    init(undoByteLimit: Int = 64 * 1024 * 1024, categoryDefaults: UserDefaults = .standard) {
        self.undoByteLimit = max(0, undoByteLimit)
        self.categoryDefaults = categoryDefaults
    }

    func delete(ids: Set<NSManagedObjectID>, context: NSManagedObjectContext) throws {
        guard !ids.isEmpty else { return }
        let workspace = try LedgerStoreTransaction.workspace(for: context)
        let records = try selected(ids, in: workspace)
        let snapshots = records.map(LedgerRecord.init)
        guard snapshots.reduce(0, { $0 + $1.retainedByteCount }) <= undoByteLimit else {
            throw LedgerOperationError.undoTooLarge
        }
        for record in records { workspace.delete(record) }
        try LedgerStoreTransaction.save(workspace, mergingInto: context)
        push(UndoEntry(coordinator: context.persistentStoreCoordinator!,
            description: "Deleted \(records.count) transaction\(records.count == 1 ? "" : "s")",
            action: .deletion(snapshots)))
    }

    func recategorize(ids: Set<NSManagedObjectID>, category: String, context: NSManagedObjectContext) throws {
        guard CategoryCatalog.load(defaults: categoryDefaults).contains(where: { $0.id == category && !$0.isArchived }) else {
            throw LedgerOperationError.invalidCategory
        }
        guard !ids.isEmpty else { return }
        let workspace = try LedgerStoreTransaction.workspace(for: context)
        let records = try selected(ids, in: workspace).filter { $0.tag != category }
        guard !records.isEmpty else { return }
        var changes: [CategoryChange] = []
        for record in records {
            let before = LedgerRecord(record)
            record.tag = category
            record.updatedAt = Date()
            changes.append(CategoryChange(id: record.objectID, before: before, after: LedgerRecord(record)))
        }
        guard changes.reduce(0, { $0 + $1.before.retainedByteCount + $1.after.retainedByteCount }) <= undoByteLimit else {
            throw LedgerOperationError.undoTooLarge
        }
        try LedgerStoreTransaction.save(workspace, mergingInto: context)
        push(UndoEntry(coordinator: context.persistentStoreCoordinator!,
            description: "Updated category for \(records.count) transaction\(records.count == 1 ? "" : "s")",
            action: .category(changes)))
    }

    func undo(context: NSManagedObjectContext) throws {
        guard let entry = undoEntries.last else { return }
        let workspace = try LedgerStoreTransaction.workspace(for: context)
        guard context.persistentStoreCoordinator === entry.coordinator else {
            throw LedgerOperationError.unsupportedContext
        }
        var recreated: [(LedgerRecord, ExpenseCD)] = []
        switch entry.action {
        case .deletion(let records):
            for snapshot in records {
                let record = try LedgerStoreTransaction.insert(in: workspace)
                snapshot.apply(to: record)
                recreated.append((snapshot, record))
            }
        case .category(let changes):
            // Validate every row first: do not partially undo a batch.
            let records = try changes.map { change -> ExpenseCD in
                guard let record = try? workspace.existingObject(with: change.id) as? ExpenseCD,
                      !record.isDeleted, LedgerRecord(record) == change.after else {
                    throw LedgerOperationError.undoConflict
                }
                return record
            }
            for (record, change) in zip(records, changes) {
                record.tag = change.before.tag
                record.updatedAt = change.before.updatedAt
            }
        }
        try LedgerStoreTransaction.save(workspace, mergingInto: context)
        undoEntries.removeLast()
        // Core Data allocates new IDs when a committed deletion is recreated.
        // Rebind earlier undo entries so "change category → delete → undo twice" works.
        let replacements = Dictionary(uniqueKeysWithValues: recreated.map { ($0.0.id, $0.1.objectID) })
        if !replacements.isEmpty {
            undoEntries = undoEntries.map { entry in
                let action: UndoAction
                switch entry.action {
                case .deletion(let records):
                    action = .deletion(records.map { rebound($0, replacements: replacements) })
                case .category(let changes):
                    action = .category(changes.map { change in
                        CategoryChange(id: replacements[change.before.id] ?? change.id,
                            before: rebound(change.before, replacements: replacements),
                            after: rebound(change.after, replacements: replacements))
                    })
                }
                return UndoEntry(coordinator: entry.coordinator, description: entry.description, action: action)
            }
        }
        undoDescription = undoEntries.last?.description
    }

    func didRestoreLedger() {
        undoEntries.removeAll()
        undoDescription = nil
        restoreGeneration += 1 // Rebuild presentation/chat state after a whole-ledger replacement.
    }

    func discardUndo() {
        undoEntries.removeAll()
        undoDescription = nil
    }

    private func selected(_ ids: Set<NSManagedObjectID>, in context: NSManagedObjectContext) throws -> [ExpenseCD] {
        try ids.map { id in
            guard !id.isTemporaryID, id.entity.name == "ExpenseCD",
                  let record = try? context.existingObject(with: id) as? ExpenseCD,
                  !record.isDeleted else { throw LedgerOperationError.missingTransaction }
            return record
        }
    }

    private func push(_ entry: UndoEntry) {
        undoEntries.append(entry)
        // Both action count and retained attachment/text bytes are bounded.
        while undoEntries.count > 10 || undoEntries.reduce(0, { $0 + $1.retainedByteCount }) > undoByteLimit {
            undoEntries.removeFirst()
        }
        undoDescription = entry.description
    }

    private func rebound(_ snapshot: LedgerRecord, replacements: [String: NSManagedObjectID]) -> LedgerRecord {
        var updated = snapshot
        if let id = replacements[snapshot.id] { updated.id = id.uriRepresentation().absoluteString }
        return updated
    }
}
