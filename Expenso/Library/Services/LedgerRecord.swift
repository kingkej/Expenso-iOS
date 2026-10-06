import CoreData
import Foundation

/// Value-only snapshot shared by backups and reversible ledger operations.
/// The ID identifies a row within a snapshot, not a merge identity across restores.
struct LedgerRecord: Codable, Equatable, Sendable {
    var id: String
    let createdAt: Date?
    let updatedAt: Date?
    let type: String?
    let title: String?
    let tag: String?
    let occuredOn: Date?
    let note: String?
    let amount: Double
    let imageAttached: Data?
    let currencyCode: String?
    let amountText: String?
    let rateSnapshotData: Data?

    var retainedByteCount: Int {
        (imageAttached?.count ?? 0) + (rateSnapshotData?.count ?? 0)
            + [id, type, title, tag, note, currencyCode, amountText].compactMap { $0 }.reduce(0) { $0 + $1.utf8.count }
    }

    @MainActor
    init(_ record: ExpenseCD) {
        id = record.objectID.uriRepresentation().absoluteString
        createdAt = record.createdAt
        updatedAt = record.updatedAt
        type = record.type
        title = record.title
        tag = record.tag
        occuredOn = record.occuredOn
        note = record.note
        amount = record.amount
        imageAttached = record.imageAttached
        currencyCode = record.supportsCurrencyMetadata ? record.currencyCode : nil
        amountText = record.supportsCurrencyMetadata ? record.amountText : nil
        rateSnapshotData = record.supportsCurrencyMetadata ? record.rateSnapshotData : nil
    }

    @MainActor
    func apply(to record: ExpenseCD) {
        record.createdAt = createdAt
        record.updatedAt = updatedAt
        record.type = type
        record.title = title
        record.tag = tag
        record.occuredOn = occuredOn
        record.note = note
        record.amount = amount
        record.imageAttached = imageAttached
        if record.supportsCurrencyMetadata {
            record.currencyCode = currencyCode
            record.amountText = amountText
            record.rateSnapshotData = rateSnapshotData
        }
    }
}

enum LedgerOperationError: LocalizedError {
    case pendingChanges, unsupportedContext, missingTransaction, invalidCategory, undoConflict, undoTooLarge

    var errorDescription: String? {
        switch self {
        case .pendingChanges: return "Finish or cancel pending edits before changing the ledger."
        case .unsupportedContext: return "This operation requires the app's main ledger context and a single store."
        case .missingTransaction: return "A selected transaction no longer exists. Refresh your selection and try again."
        case .invalidCategory: return "Choose a supported category."
        case .undoConflict: return "A transaction changed after this action. Undo would overwrite that edit, so nothing was changed."
        case .undoTooLarge: return "This selection contains too much receipt data for safe Undo. Choose a smaller batch; nothing was changed."
        }
    }
}

/// A staging child pushes only this operation into a previously clean main context.
/// The main context performs the single persistent save; no remote merge is needed.
@MainActor
enum LedgerStoreTransaction {
    static func insert(in context: NSManagedObjectContext) throws -> ExpenseCD {
        guard let entity = NSEntityDescription.entity(forEntityName: "ExpenseCD", in: context) else {
            throw LedgerOperationError.unsupportedContext
        }
        return ExpenseCD(entity: entity, insertInto: context)
    }

    static func workspace(for context: NSManagedObjectContext) throws -> NSManagedObjectContext {
        guard context.concurrencyType == .mainQueueConcurrencyType,
              let coordinator = context.persistentStoreCoordinator,
              coordinator.persistentStores.count == 1 else { throw LedgerOperationError.unsupportedContext }
        guard !context.hasChanges else { throw LedgerOperationError.pendingChanges }
        let workspace = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        workspace.parent = context
        workspace.mergePolicy = NSErrorMergePolicy
        return workspace
    }

    static func save(_ workspace: NSManagedObjectContext, mergingInto context: NSManagedObjectContext) throws {
        guard workspace.hasChanges else { return }
        guard workspace.parent === context, !context.hasChanges else { throw LedgerOperationError.pendingChanges }
        try workspace.obtainPermanentIDs(for: Array(workspace.insertedObjects))
        // No suspension between the clean-parent guard and commit. Child save only
        // stages changes in memory; the parent save is the one atomic store write.
        do {
            try workspace.save()
            try context.save()
        } catch {
            workspace.rollback()
            // The guard guarantees the parent had no user edits before staging.
            // Roll back only the current operation, never an existing editor draft.
            context.rollback()
            throw error
        }
    }

    static func records(in context: NSManagedObjectContext) throws -> [ExpenseCD] {
        let request = NSFetchRequest<ExpenseCD>(entityName: "ExpenseCD")
        request.fetchBatchSize = 100
        return try context.fetch(request).filter { !$0.isDeleted }
    }
}
