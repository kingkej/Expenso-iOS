import SwiftUI
import CoreData

struct AddExpenseView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var managedObjectContext
    @State private var showAttachmentRemoval = false
    @State private var showCurrencyPicker = false
    @State private var showConversionPicker = false
    @State private var showReceiptScanner = false
    @AppStorage(CurrencySettings.key) private var baseCurrency = "RUB"
    @StateObject var viewModel: AddExpenseViewModel

    private let categories = [TRANS_TAG_TRANSPORT, TRANS_TAG_FOOD, TRANS_TAG_HOUSING,
        TRANS_TAG_INSURANCE, TRANS_TAG_MEDICAL, TRANS_TAG_SAVINGS, TRANS_TAG_PERSONAL,
        TRANS_TAG_ENTERTAINMENT, TRANS_TAG_OTHERS, TRANS_TAG_UTILITIES, TRANS_TAG_CAR, TRANS_TAG_TRAVEL]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("Scan Receipt", systemImage: "doc.viewfinder") { showReceiptScanner = true }
                } footer: { Text("Read a paper receipt or saved image on-device, then review the suggested fields.") }
                Section("Transaction") {
                    TextField("Title", text: $viewModel.title)
                    TextField("Amount", text: $viewModel.amount).keyboardType(.decimalPad)
                    Button { showCurrencyPicker = true } label: {
                        LabeledContent("Currency", value: viewModel.currency)
                    }
                    Picker("Type", selection: $viewModel.selectedType) {
                        Label("Income", systemImage: "arrow.down.left").tag(TRANS_TYPE_INCOME)
                        Label("Expense", systemImage: "arrow.up.right").tag(TRANS_TYPE_EXPENSE)
                    }
                    Picker("Category", selection: $viewModel.selectedTag) {
                        ForEach(categories, id: \.self) { tag in
                            Label(getTransTagTitle(transTag: tag), systemImage: transactionSymbol(for: tag)).tag(tag)
                        }
                    }
                    DatePicker("Date", selection: $viewModel.occuredOn, displayedComponents: [.date, .hourAndMinute])
                }
                Section {
                    Button { showConversionPicker = true } label: {
                        LabeledContent("Conversion Currency", value: viewModel.conversionCurrency)
                    }
                    if viewModel.currency != viewModel.conversionCurrency {
                        if viewModel.isFetchingRate { ProgressView("Fetching daily rate…") }
                        if let converted = viewModel.conversionPreview { LabeledContent("Converted Amount", value: converted) }
                        if let snapshot = viewModel.rateSnapshot {
                            Text("Locked rate: \(snapshot.date) • \(snapshot.displaySource)").font(.caption).foregroundStyle(.secondary)
                        }
                        if let error = viewModel.rateError {
                            Text(error).font(.caption).foregroundStyle(.red)
                            Button("Retry Rate", systemImage: "arrow.clockwise") { Task { await viewModel.refreshRate() } }
                        }
                        Toggle("Enter a manual rate", isOn: $viewModel.useManualRate)
                        if viewModel.useManualRate {
                            TextField("1 \(viewModel.currency) = ? \(viewModel.conversionCurrency)", text: $viewModel.manualRate).keyboardType(.decimalPad)
                        }
                    }
                } header: { Text("Locked Conversion") } footer: {
                    Text("Totals use \(baseCurrency); original amounts stay in \(viewModel.currency). Daily rates are saved and never refresh with the market. For unavailable history, choose a conversion currency and enter a manual rate. Manual rates cover only that pair; other base currencies may require another explicit edit.")
                }
                Section("Notes") {
                    TextField("Optional note", text: $viewModel.note, axis: .vertical).lineLimit(3...6)
                }
                Section("Attachment") {
                    Button("Attach an image", systemImage: "paperclip") { viewModel.attachImage() }
                    if let image = viewModel.imageAttached {
                        Image(uiImage: image).resizable().scaledToFit()
                            .frame(maxHeight: 240).clipShape(RoundedRectangle(cornerRadius: 16))
                        Button("Remove attachment", systemImage: "trash", role: .destructive) {
                            showAttachmentRemoval = true
                        }
                    }
                }
            }
            .disabled(viewModel.isSaving)
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden)
            .navigationTitle(viewModel.expenseObj == nil ? "New Transaction" : "Edit Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly).disabled(viewModel.isSaving)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    HapticsHelper.shared.hardButtonTap()
                    Task { await viewModel.saveTransaction(managedObjectContext: managedObjectContext) }
                } label: {
                    Label(viewModel.expenseObj == nil ? "Add Transaction" : "Save Changes", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .primaryActionStyle()
                .disabled(viewModel.isSaving || viewModel.isFetchingRate)
                .padding(.horizontal, 20).padding(.vertical, 12)
            }
        }
        .interactiveDismissDisabled(viewModel.isSaving)
        .task(id: viewModel.rateRequestKey) { await viewModel.refreshRate() }
        .sheet(isPresented: $showCurrencyPicker) {
            CurrencyPickerView(selection: $viewModel.currency, title: "Transaction Currency").expenseSheetStyle()
        }
        .sheet(isPresented: $showConversionPicker) {
            CurrencyPickerView(selection: $viewModel.conversionCurrency, title: "Conversion Currency").expenseSheetStyle()
        }
        .sheet(isPresented: $showReceiptScanner) {
            ReceiptImportView(editor: viewModel).expenseSheetStyle()
        }
        .onReceive(viewModel.$closePresenter) { if $0 { dismiss() } }
        .confirmationDialog("Remove attachment?", isPresented: $showAttachmentRemoval, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { viewModel.removeImage() }
        }
        .alert("Unable to Save", isPresented: $viewModel.showAlert) {
            Button("OK", role: .cancel) { }
        } message: { Text(viewModel.alertMsg) }
    }
}
