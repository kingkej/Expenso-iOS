import SwiftUI
import CoreData

struct ExpenseDetailedView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var managedObjectContext
    @EnvironmentObject private var ledgerMutations: LedgerMutationService
    @StateObject private var viewModel: ExpenseDetailedViewModel
    @ObservedObject private var expense: ExpenseCD
    @AppStorage(CurrencySettings.key) private var baseCurrency = "RUB"
    @AppStorage(CategoryCatalog.storageKey) private var categoryData = Data()
    @State private var confirmDelete = false
    @State private var expenseToEdit: ExpenseCD?

    init(expenseObj: ExpenseCD) {
        _viewModel = StateObject(wrappedValue: ExpenseDetailedViewModel(expenseObj: expenseObj))
        _expense = ObservedObject(wrappedValue: expenseObj)
    }

    var body: some View {
        NavigationStack {
            ExpenseForm {
                if !expense.isDeleted {
                    Section("Transaction") {
                        ExpenseValueRow(title: "Title") { Text(expense.title ?? "") }
                        ExpenseValueRow(title: "Original Amount") { Text(expense.originalAmountLabel) }
                        if expense.originalCurrency != baseCurrency {
                            ExpenseValueRow(title: "In \(baseCurrency)") { Text(expense.convertedAmountLabel(in: baseCurrency)) }
                        }
                        if let snapshot = expense.lockedRates {
                            DisclosureGroup("Exchange rate details") {
                                ExpenseValueRow(title: "Rate date") { Text(snapshot.date) }
                                ExpenseValueRow(title: "Source") { Text(snapshot.displaySource) }
                                if expense.originalCurrency != baseCurrency,
                                   let rate = try? snapshot.rate(from: expense.originalCurrency, to: baseCurrency) {
                                    Text("1 \(expense.originalCurrency) = \(Money.string(rate)) \(baseCurrency)")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            if let notice = snapshot.approximationNotice {
                                Label(notice, systemImage: "exclamationmark.triangle")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        ExpenseValueRow(title: "Type") { Text(expense.type == TRANS_TYPE_INCOME ? "Income" : "Expense") }
                        if let method = expense.paymentMethodValue {
                            ExpenseValueRow(title: "Payment Method") { Text(method.title) }
                        }
                        ExpenseValueRow(title: "Category") {
                            Text(CategoryCatalog.decode(categoryData).first { $0.id == expense.tag }?.name
                                ?? getTransTagTitle(transTag: expense.tag ?? ""))
                        }
                        ExpenseValueRow(title: "Date") { Text(getDateFormatter(date: expense.occuredOn, format: "EEE, dd MMM yyyy, hh:mm a")) }
                    }
                    if let note = expense.note, !note.isEmpty {
                        Section("Note") { Text(note).textSelection(.enabled) }
                    }
                    if let data = expense.imageAttached, let image = UIImage(data: data) {
                        Section("Attachment") {
                            Image(uiImage: image).resizable().scaledToFit()
                                .frame(maxHeight: 320)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .frame(maxWidth: .infinity, alignment: .center)
                                .accessibilityLabel("Transaction attachment")
                        }
                    }
                }
            }
            .expenseScreenChrome()
            .navigationTitle("Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit", systemImage: "pencil") { expenseToEdit = expense }.labelStyle(.iconOnly)
                        .disabled(expense.isDeleted || expense.managedObjectContext == nil)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Share", systemImage: "square.and.arrow.up") { viewModel.shareNote() }
                        Button("Delete Transaction", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    } label: { Label("More", systemImage: "ellipsis") }
                    .disabled(expense.isDeleted || expense.managedObjectContext == nil)
                }
            }
            .sheet(item: $expenseToEdit) { item in
                AddExpenseView(viewModel: AddExpenseViewModel(expenseObj: item)).expenseSheetStyle(.editor)
            }
            .alert("Delete Transaction?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) {
                    do {
                        try ledgerMutations.delete(ids: [expense.objectID], context: managedObjectContext)
                        dismiss()
                    } catch {
                        viewModel.alertMsg = error.localizedDescription
                        viewModel.showAlert = true
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: { Text("You can undo recent changes from Dashboard or History while the app stays open.") }
            .alert("Unable to Delete", isPresented: $viewModel.showAlert) {
                Button("OK", role: .cancel) { }
            } message: { Text(viewModel.alertMsg) }
        }
        .onReceive(viewModel.$closePresenter) { if $0 { dismiss() } }
    }
}
