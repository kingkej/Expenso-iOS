//
//  AddExpenseViewModel.swift
//  Expenso
//
//  Created by Sameer Nawaz on 31/01/21.
//

import UIKit
import CoreData

@MainActor
class AddExpenseViewModel: ObservableObject {
    
    var expenseObj: ExpenseCD?
    private var initialRevision: TransactionRevision?
    private var rateRequestID: UUID?
    private let baseCurrencyOverride: String?
    private var baseCurrency: String { baseCurrencyOverride ?? CurrencySettings.base }
    
    @Published var title = ""
    @Published var amount = ""
    @Published var currency = CurrencySettings.base
    @Published var conversionCurrency = CurrencySettings.base
    @Published var rateSnapshot: CurrencyRateSnapshot?
    @Published var useManualRate = false
    @Published var manualRate = ""
    @Published var isFetchingRate = false
    @Published var isSaving = false
    @Published var rateError: String?
    @Published var occuredOn = Date()
    @Published var note = ""
    @Published var typeTitle = "Income"
    @Published var tagTitle = getTransTagTitle(transTag: TRANS_TAG_TRANSPORT)
    @Published var showTypeDrop = false
    @Published var showTagDrop = false
    
    @Published var selectedType = TRANS_TYPE_INCOME
    @Published var selectedTag = TRANS_TAG_TRANSPORT
    
    @Published var imageUpdated = false // When transaction edit, check if attachment is updated?
    @Published var imageAttached: UIImage? = nil
    
    @Published var alertMsg = String()
    @Published var showAlert = false
    @Published var closePresenter = false
    
    init(expenseObj: ExpenseCD? = nil, baseCurrency: String? = nil) {
        self.baseCurrencyOverride = baseCurrency
        self.currency = baseCurrency ?? CurrencySettings.base
        self.conversionCurrency = baseCurrency ?? CurrencySettings.base
        
        self.expenseObj = expenseObj
        self.initialRevision = expenseObj.map(TransactionRevision.init)
        self.title = expenseObj?.title ?? ""
        if let expenseObj = expenseObj {
            self.amount = expenseObj.originalDecimal.map(Money.string) ?? String(expenseObj.amount)
            self.currency = expenseObj.originalCurrency
            self.rateSnapshot = expenseObj.lockedRates
            self.typeTitle = expenseObj.type == TRANS_TYPE_INCOME ? "Income" : "Expense"
        } else {
            self.amount = ""
            self.typeTitle = "Income"
        }
        self.occuredOn = expenseObj?.occuredOn ?? Date()
        self.note = expenseObj?.note ?? ""
        self.tagTitle = getTransTagTitle(transTag: expenseObj?.tag ?? TRANS_TAG_TRANSPORT)
        self.selectedType = expenseObj?.type ?? TRANS_TYPE_INCOME
        self.selectedTag = expenseObj?.tag ?? TRANS_TAG_TRANSPORT
        if let data = expenseObj?.imageAttached {
            self.imageAttached = UIImage(data: data)
        }
        
        AttachmentHandler.shared.imagePickedBlock = { [weak self] image in
            self?.imageUpdated = true
            self?.imageAttached = image
        }
    }
    
    func getButtText() -> String {
        if selectedType == TRANS_TYPE_INCOME { return "\(expenseObj == nil ? "Add" : "Edit") income" }
        else if selectedType == TRANS_TYPE_EXPENSE { return "\(expenseObj == nil ? "Add" : "Edit") expense" }
        else { return "\(expenseObj == nil ? "Add" : "Edit") transaction" }
    }
    
    func attachImage() { AttachmentHandler.shared.showAttachmentActionSheet() }
    
    func removeImage() { imageAttached = nil }

    var rateRequestKey: String { "\(currency)|\(Money.day(occuredOn))|\(conversionCurrency)|\(baseCurrency)|\(useManualRate)" }

    /// Receipt suggestions replace only reviewed fields, never save the ledger.
    func applyReceipt(title: String, amount: String, currency: String, date: Date?, type: String, image: UIImage?) {
        let nextDate = date ?? occuredOn
        if self.currency != currency || Money.day(occuredOn) != Money.day(nextDate) {
            rateRequestID = nil
            rateSnapshot = nil
            useManualRate = false
            manualRate = ""
            rateError = nil
            isFetchingRate = false
        }
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.amount = amount
        self.currency = currency
        occuredOn = nextDate
        selectedType = type
        typeTitle = type == TRANS_TYPE_INCOME ? "Income" : "Expense"
        if let image {
            imageAttached = image
            imageUpdated = true
        }
    }

    func refreshRate() async {
        let id = UUID()
        rateRequestID = id
        let key = rateRequestKey
        let day = Money.day(occuredOn)
        let base = conversionCurrency
        rateError = nil
        if useManualRate { rateSnapshot = nil; isFetchingRate = false; return }
        if let original = expenseObj, original.originalCurrency == currency,
           Money.day(original.occuredOn ?? occuredOn) == day,
           let locked = original.lockedRates, (try? locked.rate(from: currency, to: base)) != nil {
            rateSnapshot = locked
            isFetchingRate = false
            return
        }
        if currency == base { rateSnapshot = nil; isFetchingRate = false; return }
        isFetchingRate = true
        rateSnapshot = nil
        do {
            let snapshot = try await ExchangeRateService.shared.snapshot(for: day)
            try Task.checkCancellation()
            guard key == rateRequestKey, rateRequestID == id else { return }
            _ = try snapshot.rate(from: currency, to: base)
            rateSnapshot = snapshot
        } catch {
            guard key == rateRequestKey, rateRequestID == id else { return }
            if !Task.isCancelled { rateError = error.localizedDescription }
        }
        if key == rateRequestKey, rateRequestID == id { isFetchingRate = false }
    }

    private func selectedSnapshot() throws -> CurrencyRateSnapshot? {
        let base = conversionCurrency
        if currency == base { return rateSnapshot }
        if useManualRate {
            let rate = try Money.parse(manualRate)
            guard rate > 0 else { throw MoneyError.missingRate }
            var rates: [String: Decimal] = [currency: 1]
            if let original = expenseObj, original.originalCurrency == currency,
               Money.day(original.occuredOn ?? occuredOn) == Money.day(occuredOn),
               let existing = original.lockedRates {
                // Retain all same-day locked conversions while adding a manual target.
                // Ratios are normalized to the original currency; no rates are refreshed.
                for code in existing.rates.keys {
                    rates[code] = try existing.rate(from: currency, to: code)
                }
            }
            rates[base] = rate
            return CurrencyRateSnapshot(date: Money.day(occuredOn), rates: rates,
                source: "Manual — anchored to \(currency), retaining other saved rates")
        }
        guard let rateSnapshot else { throw MoneyError.missingRate }
        _ = try rateSnapshot.rate(from: currency, to: base)
        return rateSnapshot
    }

    var conversionPreview: String? {
        guard currency != conversionCurrency, let amount = try? Money.parse(amount),
              let snapshot = try? selectedSnapshot(),
              let rate = try? snapshot.rate(from: currency, to: conversionCurrency),
              let converted = try? Money.multiply(amount, rate) else { return nil }
        return Money.format(Money.rounded(converted, currency: conversionCurrency), currency: conversionCurrency)
    }
    
    func saveTransaction(managedObjectContext: NSManagedObjectContext) async {
        guard !isSaving else { return }
        let expense: ExpenseCD
        let titleStr = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let amountStr = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if titleStr.isEmpty || titleStr == "" {
            alertMsg = "Enter Title"; showAlert = true
            return
        }
        if amountStr.isEmpty || amountStr == "" {
            alertMsg = "Enter Amount"; showAlert = true
            return
        }
        let amountValue: Decimal
        let snapshotData: Data?
        let supportsMetadata = NSEntityDescription.entity(forEntityName: "ExpenseCD", in: managedObjectContext)?.attributesByName["currencyCode"] != nil
        do {
            guard CurrencySettings.codes.contains(currency) else { throw MoneyError.missingRate }
            // Keep ordinary RUB editing usable while V2 activation is awaiting approval.
            guard supportsMetadata || (currency == "RUB" && baseCurrency == "RUB"
                && conversionCurrency == "RUB" && !useManualRate) else { throw MoneyError.schemaNotReady }
            amountValue = try Money.parse(amountStr)
            isSaving = true
            defer { isSaving = false }
            if !useManualRate { await refreshRate() }
            try Task.checkCancellation()
            let snapshot = try selectedSnapshot()
            if currency != baseCurrency {
                guard let snapshot else { throw MoneyError.missingRate }
                _ = try snapshot.rate(from: currency, to: baseCurrency)
            }
            snapshotData = try snapshot.map { try JSONEncoder().encode($0) }
        } catch {
            alertMsg = error.localizedDescription; showAlert = true
            return
        }
        
        if let expenseObj, expenseObj.isDeleted || initialRevision != TransactionRevision(expenseObj) {
            alertMsg = MoneyError.concurrentEdit.localizedDescription; showAlert = true; return
        }
        let keys = ["updatedAt", "type", "title", "tag", "occuredOn", "note", "amount", "imageAttached"]
            + (supportsMetadata ? ["amountText", "currencyCode", "rateSnapshotData"] : [])
        let oldValues = expenseObj?.dictionaryWithValues(forKeys: keys)
        if expenseObj != nil {
            
            expense = expenseObj!
            
            if let image = imageAttached {
                if imageUpdated {
                    if let _ = expense.imageAttached {
                        // Delete Previous Image from CoreData
                    }
                    expense.imageAttached = image.jpegData(compressionQuality: 1.0)
                }
            } else {
                if let _ = expense.imageAttached {
                    // Delete Previous Image from CoreData
                }
                expense.imageAttached = nil
            }
            
        } else {
            expense = ExpenseCD(context: managedObjectContext)
            expense.createdAt = Date()
            if let image = imageAttached {
                expense.imageAttached = image.jpegData(compressionQuality: 1.0)
            }
        }
        expense.updatedAt = Date()
        expense.type = selectedType
        expense.title = titleStr
        expense.tag = selectedTag
        expense.occuredOn = occuredOn
        expense.note = note
        expense.amount = NSDecimalNumber(decimal: amountValue).doubleValue
        if supportsMetadata {
            expense.amountText = Money.string(amountValue)
            expense.currencyCode = currency
            expense.rateSnapshotData = snapshotData
        }
        do {
            try managedObjectContext.save()
            closePresenter = true
        } catch {
            if let oldValues { expense.setValuesForKeys(oldValues) }
            else { managedObjectContext.delete(expense) }
            alertMsg = error.localizedDescription; showAlert = true
        }
    }
    
    func deleteTransaction(managedObjectContext: NSManagedObjectContext) {
        guard let expenseObj = expenseObj else { return }
        managedObjectContext.delete(expenseObj)
        do {
            try managedObjectContext.save(); closePresenter = true
        } catch { alertMsg = "\(error)"; showAlert = true }
    }
}
