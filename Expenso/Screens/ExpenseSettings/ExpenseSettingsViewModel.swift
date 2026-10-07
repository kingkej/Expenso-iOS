//
//  ExpenseSettingsViewModel.swift
//  Expenso
//
//  Created by Sameer Nawaz on 31/01/21.
//

import UIKit
import Combine
import CoreData
import LocalAuthentication

@MainActor
class ExpenseSettingsViewModel: ObservableObject {
    
    var csvModelArr = [ExpenseCSVModel]()
    
    var cancellableBiometricTask: AnyCancellable? = nil
    
    @Published var currency = CurrencySettings.base
    @Published var isChangingCurrency = false
    @Published private(set) var currencyChangeReview: CurrencyChangeReview?
    private let defaults: UserDefaults
    private let rateProvider: (String) async throws -> CurrencyRateSnapshot
    private var pendingCurrencyChange: PendingCurrencyChange?
    @Published var enableBiometric = UserDefaults.standard.bool(forKey: UD_USE_BIOMETRIC) {
        didSet {
            if enableBiometric { authenticate() }
            else { UserDefaults.standard.setValue(false, forKey: UD_USE_BIOMETRIC) }
        }
    }
    
    @Published var alertMsg = String()
    @Published var showAlert = false
    
    init(defaults: UserDefaults = .standard,
         rateProvider: @escaping (String) async throws -> CurrencyRateSnapshot = {
             try await ExchangeRateService.shared.nearestAvailableSnapshot(for: $0)
         }) {
        self.defaults = defaults
        self.rateProvider = rateProvider
        self.currency = CurrencySettings.base(in: defaults)
    }
        
    func authenticate() {
        showAlert = false
        alertMsg = ""
        cancellableBiometricTask = BiometricAuthUtlity.shared.authenticate()
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { completion in
                switch completion {
                case .failure(let error):
                    self.showAlert = true
                    self.alertMsg = error.description
                    self.enableBiometric = false
                default: return
                }
            }) { _ in
                UserDefaults.standard.setValue(true, forKey: UD_USE_BIOMETRIC)
            }
    }
    
    func getBiometricType() -> String {
        if #available(iOS 11.0, *) {
            let context = LAContext()
            if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) {
                switch context.biometryType {
                    case .faceID: return "Face ID"
                    case .touchID: return "Touch ID"
                    case .opticID: return "Optic ID"
                    case .none: return "App Lock"
                    @unknown default: return "App Lock"
                }
            }
        }
        return "App Lock"
    }
    
    func saveCurrency(currency: String, context: NSManagedObjectContext) async {
        guard !isChangingCurrency, currency != CurrencySettings.base(in: defaults) else { return }
        cancelCurrencyChange()
        isChangingCurrency = true
        defer { isChangingCurrency = false }
        let previousBase = CurrencySettings.base(in: defaults)
        do {
            guard CurrencySettings.codes.contains(currency) else { throw MoneyError.missingRate }
            guard !context.hasChanges else { throw CurrencyChangeError.pendingEdits }
            guard NSEntityDescription.entity(forEntityName: "ExpenseCD", in: context)?
                .attributesByName["currencyCode"] != nil else { throw MoneyError.schemaNotReady }
            let transactions = try context.fetch(NSFetchRequest<ExpenseCD>(entityName: "ExpenseCD"))
            let revisions = Dictionary(uniqueKeysWithValues: transactions.map { ($0.objectID, TransactionRevision($0)) })
            var pending: [(ExpenseCD, Data)] = []
            var snapshots: [String: CurrencyRateSnapshot] = [:]
            var substitutions: [RateSubstitution: Int] = [:]
            for transaction in transactions where !transaction.isDeleted {
                if transaction.originalCurrency == currency { continue }
                if let existing = transaction.lockedRates {
                    // Never replace a user's manual locked rate as a side effect of changing base.
                    _ = try existing.rate(from: transaction.originalCurrency, to: currency)
                    continue
                }
                guard transaction.supportsCurrencyMetadata else { throw MoneyError.schemaNotReady }
                // A damaged saved blob is not consent to replace an existing
                // locked/manual rate. Leave it available for explicit recovery.
                guard transaction.rateSnapshotData == nil else { throw CurrencyChangeError.unreadableRate }
                guard let date = transaction.occuredOn else { throw CurrencyChangeError.missingDate }
                let day = Money.day(date)
                let snapshot: CurrencyRateSnapshot
                if let cached = snapshots[day] { snapshot = cached }
                else {
                    snapshot = try await rateProvider(day)
                    snapshots[day] = snapshot
                }
                try Task.checkCancellation()
                _ = try snapshot.rate(from: transaction.originalCurrency, to: currency)
                if snapshot.date != day {
                    guard snapshot.requestedDate == day else { throw ExchangeRateError.wrongDate }
                    substitutions[RateSubstitution(requestedDate: day, rateDate: snapshot.date), default: 0] += 1
                }
                pending.append((transaction, try JSONEncoder().encode(snapshot)))
            }
            let plan = PendingCurrencyChange(context: context, previousBase: previousBase,
                currency: currency, revisions: revisions, updates: pending)
            try validate(plan)
            if !substitutions.isEmpty {
                pendingCurrencyChange = plan
                currencyChangeReview = CurrencyChangeReview(currency: currency,
                    substitutions: substitutions.map { .init(dates: $0.key, count: $0.value) }
                        .sorted { $0.dates.requestedDate < $1.dates.requestedDate })
            } else {
                try apply(plan)
            }
        } catch {
            reportCurrencyChangeError(error)
        }
    }

    /// Confirmation applies the exact reviewed snapshots, not a second fetch.
    func confirmCurrencyChange() {
        guard let plan = pendingCurrencyChange, !isChangingCurrency else { return }
        isChangingCurrency = true
        defer { isChangingCurrency = false; cancelCurrencyChange() }
        do { try apply(plan) }
        catch { reportCurrencyChangeError(error) }
    }

    func cancelCurrencyChange() {
        pendingCurrencyChange = nil
        currencyChangeReview = nil
    }

    private func validate(_ plan: PendingCurrencyChange) throws {
        try Task.checkCancellation()
        let latest = try plan.context.fetch(NSFetchRequest<ExpenseCD>(entityName: "ExpenseCD"))
        let revisions = Dictionary(uniqueKeysWithValues: latest.map { ($0.objectID, TransactionRevision($0)) })
        guard !plan.context.hasChanges, plan.previousBase == CurrencySettings.base(in: defaults),
              plan.revisions == revisions else { throw CurrencyChangeError.pendingEdits }
    }

    private func apply(_ plan: PendingCurrencyChange) throws {
        try validate(plan)
        for (transaction, data) in plan.updates { transaction.rateSnapshotData = data }
        do { if !plan.updates.isEmpty { try plan.context.save() } }
        catch {
            // Preserve exact previous bytes, including undecodable legacy blobs.
            for (transaction, _) in plan.updates {
                transaction.rateSnapshotData = plan.revisions[transaction.objectID]?.rateData
            }
            throw error
        }
        currency = plan.currency
        defaults.set(plan.currency, forKey: CurrencySettings.key)
    }

    private func reportCurrencyChangeError(_ error: Error) {
        alertMsg = "Base currency wasn't changed. \(error.localizedDescription) No original amounts were changed."
        showAlert = true
    }
    
    func exportTransactions(moc: NSManagedObjectContext) {
        csvModelArr.removeAll()
        let request = ExpenseCD.fetchRequest()
        var results: [ExpenseCD]
        do {
            results = try moc.fetch(request) as! [ExpenseCD]
            if results.count <= 0 { alertMsg = "No data to export"; showAlert = true }
            else {
                for i in results {
                    let csvModel = ExpenseCSVModel()
                    csvModel.title = i.title ?? ""
                    guard let original = i.originalDecimal else { throw MoneyError.invalidAmount }
                    let base = CurrencySettings.base
                    csvModel.amount = Money.string(original)
                    csvModel.originalCurrency = i.originalCurrency
                    csvModel.baseAmount = Money.string(try i.amount(in: base))
                    csvModel.baseCurrency = base
                    if i.originalCurrency == base { csvModel.lockedRate = "1" }
                    else {
                        guard let snapshot = i.lockedRates else { throw MoneyError.missingRate }
                        csvModel.lockedRate = Money.string(try snapshot.rate(from: i.originalCurrency, to: base))
                    }
                    csvModel.rateDate = i.lockedRates?.date ?? ""
                    csvModel.rateSource = i.lockedRates?.exportSource ?? "No conversion"
                    csvModel.transactionType = "\(i.type == TRANS_TYPE_INCOME ? "INCOME" : "EXPENSE")"
                    csvModel.paymentMethod = i.paymentMethodValue?.title ?? (i.supportsPaymentMethod ? i.paymentMethod ?? "" : "")
                    csvModel.tag = getTransTagTitle(transTag: i.tag ?? "")
                    csvModel.occuredOn = "\(getDateFormatter(date: i.occuredOn, format: "yyyy-MM-dd hh:mm a"))"
                    csvModel.note = i.note ?? ""
                    csvModelArr.append(csvModel)
                }
                self.generateCSV()
            }
        } catch { alertMsg = "\(error)"; showAlert = true }
    }
    
    func csvContents() -> String {
        var csvText = "\u{FEFF}Title,Original Amount,Original Currency,Base Amount,Base Currency,Locked Rate,Rate Date,Rate Source,Type,Tag,Occured On,Note,Payment Method\n"

        for csvModel in csvModelArr {
            let fields = [csvModel.title, csvModel.amount, csvModel.originalCurrency, csvModel.baseAmount,
                          csvModel.baseCurrency, csvModel.lockedRate, csvModel.rateDate, csvModel.rateSource,
                          csvModel.transactionType, csvModel.tag, csvModel.occuredOn, csvModel.note, csvModel.paymentMethod]
            csvText.append(fields.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: ",") + "\n")
        }
        return csvText
    }

    func generateCSV() {
        let fileName = "Expense.csv"
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try csvContents().write(to: path, atomically: true, encoding: .utf8)
            let av = UIActivityViewController(activityItems: [path], applicationActivities: nil)
            DispatchQueue.main.async {
                guard let presenter = topMostViewController() else { return }
                if let popover = av.popoverPresentationController {
                    popover.sourceView = presenter.view
                    popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
                    popover.permittedArrowDirections = []
                }
                presenter.present(av, animated: true, completion: nil)
            }
        } catch {
            alertMsg = "\(error)"
            showAlert = true
        }

        print(path)
    }
    
    deinit {
        cancellableBiometricTask = nil
    }
}

private struct PendingCurrencyChange {
    let context: NSManagedObjectContext
    let previousBase: String
    let currency: String
    let revisions: [NSManagedObjectID: TransactionRevision]
    let updates: [(ExpenseCD, Data)]
}

struct RateSubstitution: Hashable {
    let requestedDate: String
    let rateDate: String
}

struct CurrencyChangeReview: Identifiable {
    struct Substitution: Identifiable {
        let dates: RateSubstitution
        let count: Int
        var id: RateSubstitution { dates }
    }
    let id = UUID()
    let currency: String
    let substitutions: [Substitution]
    var affectedCount: Int { substitutions.reduce(0) { $0 + $1.count } }
}

private enum CurrencyChangeError: LocalizedError {
    case pendingEdits, missingDate, unreadableRate
    var errorDescription: String? {
        switch self {
        case .pendingEdits: return "Transactions or settings changed while preparing rates. Finish editing and try again."
        case .missingDate: return "A transaction has no date. Edit it before changing base currency."
        case .unreadableRate: return "A transaction's saved rate could not be read. Its saved data was kept; review that transaction before changing base currency."
        }
    }
}
