//
//  AddExpenseViewModel.swift
//  Expenso
//
//  Created by Sameer Nawaz on 31/01/21.
//

import UIKit
import CoreData
import ImageIO

@MainActor
class AddExpenseViewModel: ObservableObject {
    
    var expenseObj: ExpenseCD?
    private var initialRevision: TransactionRevision?
    private var rateRequestID: UUID?
    private let rateService: ExchangeRateService
    private var unpublishedRateKey: String?
    private var nearestProposalKey: String?
    private var acceptedEstimateKey: String?
    private let baseCurrencyOverride: String?
    private let categoryDefaults: UserDefaults
    private let initialDraftDate: Date
    private let initialDraftCategory: String
    private let initialDraftCurrency: String
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
    @Published private(set) var nearestRateProposal: CurrencyRateSnapshot?
    @Published var occuredOn = Date()
    @Published var note = ""
    @Published var typeTitle = "Expense"
    @Published var tagTitle = getTransTagTitle(transTag: TRANS_TAG_TRANSPORT)
    @Published var showTypeDrop = false
    @Published var showTagDrop = false
    
    @Published var selectedType = TRANS_TYPE_EXPENSE
    @Published var selectedTag = TRANS_TAG_TRANSPORT
    // Preserve an unfamiliar stored value during unrelated edits and recovery.
    // Choosing a supported method or clearing it deliberately replaces the raw value.
    @Published private(set) var paymentMethodRawValue: String?
    var selectedPaymentMethod: PaymentMethod? {
        get { paymentMethodRawValue.flatMap(PaymentMethod.init(rawValue:)) }
        set { paymentMethodRawValue = newValue?.rawValue }
    }
    
    @Published var imageUpdated = false // When transaction edit, check if attachment is updated?
    @Published var imageAttached: UIImage? = nil
    
    @Published var alertMsg = String()
    @Published var showAlert = false
    @Published var closePresenter = false
    
    init(expenseObj: ExpenseCD? = nil, baseCurrency: String? = nil, categoryDefaults: UserDefaults = .standard,
         rateService: ExchangeRateService = .shared, paymentMethod: String? = nil) {
        self.rateService = rateService
        let initialDate = expenseObj?.occuredOn ?? Date()
        let initialCategory = expenseObj?.tag ?? CategoryCatalog.load(defaults: categoryDefaults).first(where: { !$0.isArchived })?.id ?? TRANS_TAG_TRANSPORT
        self.initialDraftDate = initialDate
        self.initialDraftCategory = initialCategory
        self.initialDraftCurrency = baseCurrency ?? CurrencySettings.base
        self.baseCurrencyOverride = baseCurrency
        self.categoryDefaults = categoryDefaults
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
            self.typeTitle = "Expense"
        }
        self.occuredOn = initialDate
        self.note = expenseObj?.note ?? ""
        self.tagTitle = getTransTagTitle(transTag: expenseObj?.tag ?? TRANS_TAG_TRANSPORT)
        self.selectedType = expenseObj?.type ?? TRANS_TYPE_EXPENSE
        self.selectedTag = initialCategory
        self.paymentMethodRawValue = expenseObj.map { $0.supportsPaymentMethod ? $0.paymentMethod : nil } ?? paymentMethod
        
    }
    
    func getButtText() -> String {
        if selectedType == TRANS_TYPE_INCOME { return "\(expenseObj == nil ? "Add" : "Edit") income" }
        else if selectedType == TRANS_TYPE_EXPENSE { return "\(expenseObj == nil ? "Add" : "Edit") expense" }
        else { return "\(expenseObj == nil ? "Add" : "Edit") transaction" }
    }
    
    func attachImage() {
        AttachmentHandler.shared.imagePickedBlock = { [weak self] image in
            self?.imageUpdated = true
            self?.imageAttached = image
        }
        AttachmentHandler.shared.showAttachmentActionSheet()
    }
    
    func removeImage() { imageUpdated = true; imageAttached = nil }

    /// Preparing the display preview must never replace the original stored bytes.
    func prepareAttachmentPreview(maxPixelSize: CGFloat) async {
        guard !imageUpdated, imageAttached == nil, let data = initialRevision?.image else { return }
        let work = Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard !Task.isCancelled,
                  let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                  ] as CFDictionary) else { return nil }
            return UIImage(cgImage: image)
        }
        let preview = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        guard !Task.isCancelled, !imageUpdated, imageAttached == nil else { return }
        imageAttached = preview
    }

    /// Scanner completion may close only an untouched new-transaction flow.
    var isPristineDraft: Bool {
        expenseObj == nil && title.isEmpty && amount.isEmpty && note.isEmpty
            && currency == initialDraftCurrency && conversionCurrency == initialDraftCurrency
            && occuredOn == initialDraftDate && selectedType == TRANS_TYPE_EXPENSE
            && selectedTag == initialDraftCategory && !useManualRate && manualRate.isEmpty
            && paymentMethodRawValue == nil
            && imageAttached == nil && !imageUpdated
    }

    var rateRequestKey: String { "\(currency)|\(Money.day(occuredOn))|\(conversionCurrency)|\(baseCurrency)|\(useManualRate)" }

    enum RequiredField: Hashable { case amount, title }

    var firstInvalidField: RequiredField? {
        if (try? Money.parse(amount)) == nil { return .amount }
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .title }
        return nil
    }

    func validationMessage(for field: RequiredField) -> String? {
        switch field {
        case .amount:
            return (try? Money.parse(amount)) != nil ? nil : "Enter a valid amount of zero or more."
        case .title:
            return title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Give this transaction a title." : nil
        }
    }

    /// Receipt suggestions replace only reviewed fields, never save the ledger.
    func applyReceipt(title: String, amount: String, currency: String, date: Date?, type: String, image: UIImage?,
                      paymentMethod: PaymentMethod? = nil, replacePaymentMethod: Bool = false) {
        let nextDate = date ?? occuredOn
        if self.currency != currency || Money.day(occuredOn) != Money.day(nextDate) {
            rateRequestID = nil
            unpublishedRateKey = nil
            nearestProposalKey = nil
            acceptedEstimateKey = nil
            nearestRateProposal = nil
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
        // Suggestions fill an empty field. Only an explicit review choice may replace or clear it.
        if replacePaymentMethod || paymentMethodRawValue == nil {
            selectedPaymentMethod = paymentMethod
        }
        if let image {
            imageAttached = image
            imageUpdated = true
        }
    }

    func refreshRate() async {
        guard !Task.isCancelled else { return }
        let id = UUID()
        rateRequestID = id
        let key = rateRequestKey
        let day = Money.day(occuredOn)
        let base = conversionCurrency
        rateError = nil
        unpublishedRateKey = nil
        nearestRateProposal = nil
        nearestProposalKey = nil
        if acceptedEstimateKey == key, let snapshot = rateSnapshot,
           snapshot.requestedDate == day, snapshot.isApproximate,
           (try? snapshot.rate(from: currency, to: base)) != nil {
            isFetchingRate = false
            return
        }
        acceptedEstimateKey = nil
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
            let snapshot = try await rateService.snapshot(for: day)
            try Task.checkCancellation()
            guard key == rateRequestKey, rateRequestID == id else { return }
            _ = try snapshot.rate(from: currency, to: base)
            rateSnapshot = snapshot
        } catch {
            guard key == rateRequestKey, rateRequestID == id else { return }
            if !Task.isCancelled {
                rateError = error.localizedDescription
                if case ExchangeRateError.notPublished = error { unpublishedRateKey = key }
            }
        }
        if key == rateRequestKey, rateRequestID == id { isFetchingRate = false }
    }

    var canRequestNearestRate: Bool {
        unpublishedRateKey == rateRequestKey && !useManualRate && currency != conversionCurrency && !isFetchingRate
    }

    var rateRecoveryMessage: String? {
        guard unpublishedRateKey == rateRequestKey else { return nil }
        return "Rates aren't published for this date. Review an available date or enter a manual rate."
    }

    /// Load a proposal only; a different day's rate cannot be saved until the
    /// editor shows both dates and the user explicitly accepts it.
    func requestNearestRate() async {
        guard !Task.isCancelled, canRequestNearestRate else { return }
        let id = UUID()
        rateRequestID = id
        let key = rateRequestKey
        let day = Money.day(occuredOn)
        let originalCurrency = currency
        let targetCurrency = conversionCurrency
        nearestRateProposal = nil
        nearestProposalKey = nil
        isFetchingRate = true
        defer {
            if key == rateRequestKey, rateRequestID == id { isFetchingRate = false }
        }
        do {
            let snapshot = try await rateService.nearestAvailableSnapshot(for: day)
            try Task.checkCancellation()
            guard key == rateRequestKey, rateRequestID == id else { return }
            _ = try snapshot.rate(from: originalCurrency, to: targetCurrency)
            if snapshot.isApproximate {
                nearestRateProposal = snapshot
                nearestProposalKey = key
            } else {
                // The requested day may have become available during recovery.
                rateSnapshot = snapshot
                unpublishedRateKey = nil
                rateError = nil
            }
        } catch {
            guard key == rateRequestKey, rateRequestID == id, !Task.isCancelled else { return }
            rateError = error.localizedDescription
        }
    }

    func acceptNearestRateProposal() {
        guard let proposal = nearestRateProposal, nearestProposalKey == rateRequestKey,
              proposal.requestedDate == Money.day(occuredOn), proposal.isApproximate,
              (try? proposal.rate(from: currency, to: conversionCurrency)) != nil else {
            dismissNearestRateProposal()
            return
        }
        rateSnapshot = proposal
        acceptedEstimateKey = rateRequestKey
        nearestRateProposal = nil
        nearestProposalKey = nil
        unpublishedRateKey = nil
        rateError = nil
    }

    func dismissNearestRateProposal() {
        nearestRateProposal = nil
        nearestProposalKey = nil
    }

    private func selectedSnapshot() throws -> CurrencyRateSnapshot? {
        let base = conversionCurrency
        if currency == base { return rateSnapshot }
        if useManualRate {
            let rate = try Money.parse(manualRate)
            guard rate > 0 else { throw MoneyError.missingRate }
            var rates: [String: Decimal] = [currency: 1]
            var snapshotDate = Money.day(occuredOn)
            var requestedDate: String?
            var inheritedSource: String?
            if let original = expenseObj, original.originalCurrency == currency,
               Money.day(original.occuredOn ?? occuredOn) == Money.day(occuredOn),
               let existing = original.lockedRates {
                // Retain all same-day locked conversions while adding a manual target.
                // Ratios are normalized to the original currency; no rates are refreshed.
                for code in existing.rates.keys {
                    rates[code] = try existing.rate(from: currency, to: code)
                }
                snapshotDate = existing.date
                requestedDate = existing.requestedDate
                inheritedSource = existing.exportSource
            }
            rates[base] = rate
            let manualSource = "Manual — 1 \(currency) = \(Money.string(rate)) \(base), entered for \(Money.day(occuredOn))"
            return CurrencyRateSnapshot(date: snapshotDate, rates: rates,
                source: inheritedSource.map { "\(manualSource); other saved rates retained from \($0) (rate date \(snapshotDate))" } ?? manualSource,
                requestedDate: requestedDate)
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

    var rateApproximationNotice: String? {
        (try? selectedSnapshot())?.approximationNotice
    }
    
    func saveTransaction(managedObjectContext: NSManagedObjectContext) async {
        guard !isSaving else { return }
        let expense: ExpenseCD
        let titleStr = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let amountStr = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Required fields are explained inline by each editor before saving.
        guard firstInvalidField == nil else { return }
        isSaving = true
        defer { isSaving = false }
        let amountValue: Decimal
        let snapshotData: Data?
        var attachmentData = expenseObj?.imageAttached
        guard let entity = NSEntityDescription.entity(forEntityName: "ExpenseCD", in: managedObjectContext) else {
            alertMsg = MoneyError.schemaNotReady.localizedDescription; showAlert = true; return
        }
        let supportsMetadata = entity.attributesByName["currencyCode"] != nil
        let supportsPaymentMethod = entity.attributesByName["paymentMethod"] != nil
        do {
            guard supportsPaymentMethod || paymentMethodRawValue == nil else { throw MoneyError.schemaNotReady }
            guard CurrencySettings.codes.contains(currency) else { throw MoneyError.missingRate }
            // Keep ordinary RUB editing usable while V2 activation is awaiting approval.
            guard supportsMetadata || (currency == "RUB" && baseCurrency == "RUB"
                && conversionCurrency == "RUB" && !useManualRate) else { throw MoneyError.schemaNotReady }
            amountValue = try Money.parse(amountStr)
            if !useManualRate { await refreshRate() }
            try Task.checkCancellation()
            let snapshot = try selectedSnapshot()
            if currency != baseCurrency {
                guard let snapshot else { throw MoneyError.missingRate }
                _ = try snapshot.rate(from: currency, to: baseCurrency)
            }
            snapshotData = try snapshot.map { try JSONEncoder().encode($0) }
            if expenseObj == nil || imageUpdated {
                if let image = imageAttached {
                    // UIImage is SDK-declared Sendable. The worker sees an
                    // immutable image and never reads editor or Core Data state.
                    let encoding = Task.detached(priority: .userInitiated) {
                        try Task.checkCancellation()
                        guard let data = image.jpegData(compressionQuality: 1.0) else {
                            throw ReceiptScanError.invalidImage
                        }
                        try Task.checkCancellation()
                        return data
                    }
                    attachmentData = try await withTaskCancellationHandler {
                        try await encoding.value
                    } onCancel: {
                        encoding.cancel()
                    }
                } else { attachmentData = nil }
            }
            try Task.checkCancellation()
        } catch {
            alertMsg = error.localizedDescription; showAlert = true
            return
        }
        
        if let expenseObj, expenseObj.isDeleted || initialRevision != TransactionRevision(expenseObj) {
            alertMsg = MoneyError.concurrentEdit.localizedDescription; showAlert = true; return
        }
        // Recheck after the rate await: a category may have been archived in another sheet.
        guard selectedTag == expenseObj?.tag || CategoryCatalog.load(defaults: categoryDefaults).contains(where: { $0.id == selectedTag && !$0.isArchived }) else {
            alertMsg = "Choose an active category."; showAlert = true; return
        }
        let keys = ["updatedAt", "type", "title", "tag", "occuredOn", "note", "amount", "imageAttached"]
            + (supportsMetadata ? ["amountText", "currencyCode", "rateSnapshotData"] : [])
            + (supportsPaymentMethod ? ["paymentMethod"] : [])
        let oldValues = expenseObj?.dictionaryWithValues(forKeys: keys)
        if expenseObj != nil {
            expense = expenseObj!
        } else {
            expense = ExpenseCD(entity: entity, insertInto: managedObjectContext)
            expense.createdAt = Date()
        }
        expense.imageAttached = attachmentData
        expense.updatedAt = Date()
        expense.type = selectedType
        expense.title = titleStr
        expense.tag = selectedTag
        expense.occuredOn = occuredOn
        expense.note = note
        expense.amount = NSDecimalNumber(decimal: amountValue).doubleValue
        if supportsPaymentMethod { expense.paymentMethod = paymentMethodRawValue }
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
