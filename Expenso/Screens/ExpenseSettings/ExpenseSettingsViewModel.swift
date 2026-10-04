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
    @Published var enableBiometric = UserDefaults.standard.bool(forKey: UD_USE_BIOMETRIC) {
        didSet {
            if enableBiometric { authenticate() }
            else { UserDefaults.standard.setValue(false, forKey: UD_USE_BIOMETRIC) }
        }
    }
    
    @Published var alertMsg = String()
    @Published var showAlert = false
    
    init() {}
        
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
        guard !isChangingCurrency, currency != CurrencySettings.base else { return }
        isChangingCurrency = true
        defer { isChangingCurrency = false }
        let previousBase = CurrencySettings.base
        do {
            guard CurrencySettings.codes.contains(currency) else { throw MoneyError.missingRate }
            guard !context.hasChanges else { throw CurrencyChangeError.pendingEdits }
            guard NSEntityDescription.entity(forEntityName: "ExpenseCD", in: context)?
                .attributesByName["currencyCode"] != nil else { throw MoneyError.schemaNotReady }
            let transactions = try context.fetch(NSFetchRequest<ExpenseCD>(entityName: "ExpenseCD"))
            let revisions = Dictionary(uniqueKeysWithValues: transactions.map { ($0.objectID, TransactionRevision($0)) })
            var pending: [(ExpenseCD, Data)] = []
            var snapshots: [String: CurrencyRateSnapshot] = [:]
            for transaction in transactions where !transaction.isDeleted {
                if transaction.originalCurrency == currency { continue }
                if let existing = transaction.lockedRates {
                    // Never replace a user's manual locked rate as a side effect of changing base.
                    _ = try existing.rate(from: transaction.originalCurrency, to: currency)
                    continue
                }
                guard transaction.supportsCurrencyMetadata else { throw MoneyError.schemaNotReady }
                guard let date = transaction.occuredOn else { throw CurrencyChangeError.missingDate }
                let day = Money.day(date)
                let snapshot: CurrencyRateSnapshot
                if let cached = snapshots[day] { snapshot = cached }
                else {
                    snapshot = try await ExchangeRateService.shared.snapshot(for: day)
                    snapshots[day] = snapshot
                }
                try Task.checkCancellation()
                _ = try snapshot.rate(from: transaction.originalCurrency, to: currency)
                pending.append((transaction, try JSONEncoder().encode(snapshot)))
            }
            let latest = try context.fetch(NSFetchRequest<ExpenseCD>(entityName: "ExpenseCD"))
            let currentRevisions = Dictionary(uniqueKeysWithValues: latest.map { ($0.objectID, TransactionRevision($0)) })
            guard !context.hasChanges, previousBase == CurrencySettings.base,
                  revisions == currentRevisions else { throw CurrencyChangeError.pendingEdits }
            for (transaction, data) in pending { transaction.rateSnapshotData = data }
            do { if !pending.isEmpty { try context.save() } }
            catch {
                for (transaction, _) in pending { transaction.rateSnapshotData = nil }
                throw error
            }
            self.currency = currency
            UserDefaults.standard.set(currency, forKey: CurrencySettings.key)
        } catch {
            alertMsg = "Base currency wasn't changed. \(error.localizedDescription) No original amounts were changed."
            showAlert = true
        }
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
                    csvModel.rateSource = i.lockedRates?.source ?? "No conversion"
                    csvModel.transactionType = "\(i.type == TRANS_TYPE_INCOME ? "INCOME" : "EXPENSE")"
                    csvModel.tag = getTransTagTitle(transTag: i.tag ?? "")
                    csvModel.occuredOn = "\(getDateFormatter(date: i.occuredOn, format: "yyyy-MM-dd hh:mm a"))"
                    csvModel.note = i.note ?? ""
                    csvModelArr.append(csvModel)
                }
                self.generateCSV()
            }
        } catch { alertMsg = "\(error)"; showAlert = true }
    }
    
    func generateCSV() {
        let fileName = "Expense.csv"
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        var csvText = "\u{FEFF}Title,Original Amount,Original Currency,Base Amount,Base Currency,Locked Rate,Rate Date,Rate Source,Type,Tag,Occured On,Note\n"

        for csvModel in csvModelArr {
            let fields = [csvModel.title, csvModel.amount, csvModel.originalCurrency, csvModel.baseAmount,
                          csvModel.baseCurrency, csvModel.lockedRate, csvModel.rateDate, csvModel.rateSource,
                          csvModel.transactionType, csvModel.tag, csvModel.occuredOn, csvModel.note]
            csvText.append(fields.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: ",") + "\n")
        }

        do {
            try csvText.write(to: path, atomically: true, encoding: .utf8)
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

private enum CurrencyChangeError: LocalizedError {
    case pendingEdits, missingDate
    var errorDescription: String? {
        switch self {
        case .pendingEdits: return "Transactions or settings changed while preparing rates. Finish editing and try again."
        case .missingDate: return "A transaction has no date. Edit it before changing base currency."
        }
    }
}
