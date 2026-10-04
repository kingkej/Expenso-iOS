import SwiftUI
import CoreData

struct ExpenseDetailedView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var managedObjectContext
    @StateObject private var viewModel: ExpenseDetailedViewModel
    @ObservedObject private var expense: ExpenseCD
    @AppStorage(CurrencySettings.key) private var baseCurrency = "RUB"
    @State private var confirmDelete = false
    @State private var expenseToEdit: ExpenseCD?

    init(expenseObj: ExpenseCD) {
        _viewModel = StateObject(wrappedValue: ExpenseDetailedViewModel(expenseObj: expenseObj))
        _expense = ObservedObject(wrappedValue: expenseObj)
    }

    var body: some View {
        NavigationStack {
            Form {
                if !expense.isDeleted {
                    Section("Transaction") {
                        LabeledContent("Title", value: expense.title ?? "")
                        LabeledContent("Original Amount", value: expense.originalAmountLabel)
                        if expense.originalCurrency != baseCurrency {
                            LabeledContent("In \(baseCurrency)", value: expense.convertedAmountLabel(in: baseCurrency))
                        }
                        if let snapshot = expense.lockedRates {
                            LabeledContent("Locked Rate Date", value: snapshot.date)
                            LabeledContent("Rate Source", value: snapshot.displaySource)
                            if expense.originalCurrency != baseCurrency,
                               let rate = try? snapshot.rate(from: expense.originalCurrency, to: baseCurrency) {
                                Text("1 \(expense.originalCurrency) = \(Money.string(rate)) \(baseCurrency)")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        LabeledContent("Type", value: expense.type == TRANS_TYPE_INCOME ? "Income" : "Expense")
                        LabeledContent("Category", value: getTransTagTitle(transTag: expense.tag ?? ""))
                        LabeledContent("Date", value: getDateFormatter(date: expense.occuredOn, format: "EEE, dd MMM yyyy, hh:mm a"))
                    }
                    if let note = expense.note, !note.isEmpty {
                        Section("Note") { Text(note).textSelection(.enabled) }
                    }
                    if let data = expense.imageAttached, let image = UIImage(data: data) {
                        Section("Attachment") {
                            Image(uiImage: image).resizable().scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit", systemImage: "pencil") { expenseToEdit = expense }.labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Share", systemImage: "square.and.arrow.up") { viewModel.shareNote() }
                        Button("Delete Transaction", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    } label: { Label("More", systemImage: "ellipsis") }
                }
            }
            .sheet(item: $expenseToEdit) { item in
                AddExpenseView(viewModel: AddExpenseViewModel(expenseObj: item)).expenseSheetStyle()
            }
            .alert("Delete Transaction?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) { viewModel.deleteNote(managedObjectContext: managedObjectContext) }
                Button("Cancel", role: .cancel) { }
            } message: { Text("This transaction will be permanently removed.") }
            .alert("Unable to Delete", isPresented: $viewModel.showAlert) {
                Button("OK", role: .cancel) { }
            } message: { Text(viewModel.alertMsg) }
        }
        .onReceive(viewModel.$closePresenter) { if $0 { dismiss() } }
    }
}
