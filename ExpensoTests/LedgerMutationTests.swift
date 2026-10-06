import CoreData
import Foundation
import Testing
@testable import Expenso

@Suite("Reversible ledger operations — isolated Core Data integration")
@MainActor
struct LedgerMutationTests {
    @Test("Delete and undo preserve notes, dates, exact currency metadata and attachment bytes")
    func deletionUndo() throws {
        let store = try CurrencyTestStore()
        let record = try store.transaction(amount: "12.345", currency: "BAM", rates: ["BAM": 1, "RUB": 50])
        record.note = "Keep me"
        record.imageAttached = Data([1, 0, 0xff])
        record.createdAt = Date(timeIntervalSinceReferenceDate: 0.123456)
        record.updatedAt = nil
        try store.context.save()
        let before = LedgerRecord(record)
        let mutations = LedgerMutationService()
        try mutations.delete(ids: [record.objectID], context: store.context)
        #expect(!store.context.hasChanges)
        #expect(try LedgerStoreTransaction.records(in: store.context).isEmpty)
        #expect(mutations.hasUndo)
        try mutations.undo(context: store.context)
        let restored = try #require(LedgerStoreTransaction.records(in: store.context).first)
        var after = LedgerRecord(restored)
        after.id = before.id
        #expect(after == before)
        #expect(!mutations.hasUndo)
        #expect(!store.context.hasChanges)
    }

    @Test("Bulk recategorization touches only category/update date and its undo restores them")
    func categoryUndo() throws {
        let store = try CurrencyTestStore()
        let first = try store.transaction(amount: "10", currency: "BAM", rates: ["BAM": 1, "RUB": 50])
        let second = try store.transaction(amount: "20", currency: "RUB")
        first.updatedAt = nil
        try store.context.save()
        let before = LedgerRecord(first)
        let mutations = LedgerMutationService()
        try mutations.recategorize(ids: [first.objectID, second.objectID], category: TRANS_TAG_TRAVEL, context: store.context)
        #expect(first.tag == TRANS_TAG_TRAVEL)
        #expect(second.tag == TRANS_TAG_TRAVEL)
        #expect(first.rateSnapshotData == before.rateSnapshotData)
        #expect(first.amountText == before.amountText)
        #expect(first.currencyCode == before.currencyCode)
        try mutations.undo(context: store.context)
        #expect(LedgerRecord(first) == before)
        #expect(second.tag == TRANS_TAG_FOOD)
    }

    @Test("Undo does not overwrite a subsequently saved edit")
    func undoConflict() throws {
        let store = try CurrencyTestStore()
        let record = try store.transaction(amount: "10", currency: "RUB")
        try store.context.save()
        let mutations = LedgerMutationService()
        try mutations.recategorize(ids: [record.objectID], category: TRANS_TAG_TRAVEL, context: store.context)
        record.note = "New edit after recategorization"
        try store.context.save()
        #expect(throws: LedgerOperationError.self) { try mutations.undo(context: store.context) }
        #expect(record.note == "New edit after recategorization")
        #expect(record.tag == TRANS_TAG_TRAVEL)
        #expect(mutations.hasUndo)
        #expect(!store.context.hasChanges)
    }

    @Test("Undoing deletion rebinds earlier category actions to recreated Core Data IDs")
    func chainedUndo() throws {
        let store = try CurrencyTestStore()
        let record = try store.transaction(amount: "10", currency: "RUB")
        try store.context.save()
        let before = LedgerRecord(record)
        let mutations = LedgerMutationService()
        try mutations.recategorize(ids: [record.objectID], category: TRANS_TAG_TRAVEL, context: store.context)
        try mutations.delete(ids: [record.objectID], context: store.context)
        try mutations.undo(context: store.context)
        #expect(try LedgerStoreTransaction.records(in: store.context).first?.tag == TRANS_TAG_TRAVEL)
        try mutations.undo(context: store.context)
        var restored = LedgerRecord(try #require(LedgerStoreTransaction.records(in: store.context).first))
        restored.id = before.id
        #expect(restored == before)
        #expect(!mutations.hasUndo)
    }

    @Test("Pending edits are preserved; unknown categories do not mutate anything")
    func rejectedOperations() throws {
        let store = try CurrencyTestStore()
        let record = try store.transaction(amount: "10", currency: "RUB")
        try store.context.save()
        let mutations = LedgerMutationService()
        #expect(throws: LedgerOperationError.self) {
            try mutations.recategorize(ids: [record.objectID], category: "not-supported", context: store.context)
        }
        record.note = "Pending edit"
        #expect(throws: LedgerOperationError.self) { try mutations.delete(ids: [record.objectID], context: store.context) }
        #expect(record.note == "Pending edit")
        #expect(!record.isDeleted)
        #expect(!mutations.hasUndo)
    }

    @Test("Oversized Undo refuses a mutation before saving")
    func undoMemoryLimit() throws {
        let store = try CurrencyTestStore()
        let record = try store.transaction(amount: "10", currency: "RUB")
        record.imageAttached = Data(repeating: 1, count: 1024)
        try store.context.save()
        let before = LedgerRecord(record)
        let mutations = LedgerMutationService(undoByteLimit: 100)
        #expect(throws: LedgerOperationError.self) {
            try mutations.delete(ids: [record.objectID], context: store.context)
        }
        #expect(throws: LedgerOperationError.self) {
            try mutations.recategorize(ids: [record.objectID], category: TRANS_TAG_TRAVEL, context: store.context)
        }
        #expect(LedgerRecord(record) == before)
        #expect(!mutations.hasUndo)
        #expect(!store.context.hasChanges)
    }

    @Test("Undo expires older entries when the byte budget is exhausted")
    func undoByteEviction() throws {
        let store = try CurrencyTestStore()
        let first = try store.transaction(amount: "10", currency: "RUB")
        let second = try store.transaction(amount: "20", currency: "RUB")
        first.imageAttached = Data(repeating: 1, count: 1024)
        second.imageAttached = Data(repeating: 2, count: 1024)
        try store.context.save()
        let budget = max(LedgerRecord(first).retainedByteCount, LedgerRecord(second).retainedByteCount) + 16
        let mutations = LedgerMutationService(undoByteLimit: budget)
        try mutations.delete(ids: [first.objectID], context: store.context)
        try mutations.delete(ids: [second.objectID], context: store.context)
        try mutations.undo(context: store.context)
        #expect(!mutations.hasUndo)
        #expect(try LedgerStoreTransaction.records(in: store.context).map(\.amountText) == ["20"])
    }

    @Test("Undo retains only the latest ten actions")
    func undoCountEviction() throws {
        let store = try CurrencyTestStore()
        var ids: [NSManagedObjectID] = []
        for value in 1...11 {
            let record = try store.transaction(amount: "\(value)", currency: "RUB")
            try store.context.save()
            ids.append(record.objectID)
        }
        let mutations = LedgerMutationService()
        for id in ids { try mutations.delete(ids: [id], context: store.context) }
        for _ in 0..<10 { try mutations.undo(context: store.context) }
        #expect(!mutations.hasUndo)
        let records = try LedgerStoreTransaction.records(in: store.context)
        #expect(records.count == 10)
        #expect(!records.contains { $0.amountText == "1" })
    }

    @Test("A deleted selection fails the entire batch, and restore clears previous Undo")
    func staleSelectionAndRestore() throws {
        let store = try CurrencyTestStore()
        let first = try store.transaction(amount: "10", currency: "RUB")
        let second = try store.transaction(amount: "20", currency: "RUB")
        try store.context.save()
        let ids: Set<NSManagedObjectID> = [first.objectID, second.objectID]
        let mutations = LedgerMutationService()
        try mutations.delete(ids: [first.objectID], context: store.context)
        #expect(throws: LedgerOperationError.self) {
            try mutations.recategorize(ids: ids, category: TRANS_TAG_TRAVEL, context: store.context)
        }
        #expect(second.tag == TRANS_TAG_FOOD)
        mutations.didRestoreLedger()
        #expect(!mutations.hasUndo)
        #expect(mutations.restoreGeneration == 1)
    }
}
