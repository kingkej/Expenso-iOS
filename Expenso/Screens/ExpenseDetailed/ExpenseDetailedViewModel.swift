//
//  ExpenseDetailedViewModel.swift
//  Expenso
//
//  Created by Sameer Nawaz on 31/01/21.
//

import UIKit
import CoreData

class ExpenseDetailedViewModel: ObservableObject {
    
    @Published var expenseObj: ExpenseCD
    
    @Published var alertMsg = String()
    @Published var showAlert = false
    @Published var closePresenter = false
    
    init(expenseObj: ExpenseCD) {
        self.expenseObj = expenseObj
    }
    
    func deleteNote(managedObjectContext: NSManagedObjectContext) {
        managedObjectContext.delete(expenseObj)
        do {
            try managedObjectContext.save(); closePresenter = true
        } catch { alertMsg = "\(error)"; showAlert = true }
    }
    
    func shareNote() {
        let shareStr = """
        Title: \(expenseObj.title ?? "")
        Original amount: \(expenseObj.originalAmountLabel)
        In base currency: \(expenseObj.convertedAmountLabel(in: CurrencySettings.base))
        Locked rate date: \(expenseObj.lockedRates?.date ?? "Same currency; no conversion")
        Rate source: \(expenseObj.lockedRates?.exportSource ?? "No conversion")
        \(expenseObj.lockedRates?.approximationNotice ?? "")
        Transaction type: \(expenseObj.type == TRANS_TYPE_INCOME ? "Income" : "Expense")
        Category: \(getTransTagTitle(transTag: expenseObj.tag ?? ""))
        Date: \(getDateFormatter(date: expenseObj.occuredOn, format: "EEEE, dd MMM hh:mm a"))
        Note: \(expenseObj.note ?? "")
        
        \(SHARED_FROM_EXPENSO)
        """
        let av = UIActivityViewController(activityItems: [shareStr], applicationActivities: nil)
        DispatchQueue.main.async {
            guard let presenter = topMostViewController() else { return }
            if let popover = av.popoverPresentationController {
                popover.sourceView = presenter.view
                popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            presenter.present(av, animated: true, completion: nil)
        }
    }
}
