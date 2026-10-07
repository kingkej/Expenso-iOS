import SwiftUI
import CoreData

struct AddExpenseView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var managedObjectContext
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.appAccentColor) private var accentColor
    @State private var showAttachmentRemoval = false
    private enum Destination: String, Identifiable {
        case currency, conversion, receipt
        var id: String { rawValue }
    }
    private enum Field: Hashable { case amount, title, note, rate }
    @State private var destination: Destination?
    @FocusState private var focusedField: Field?
    @State private var attemptedSave = false
    @State private var showConversionOptions = false
    @AppStorage(CurrencySettings.key) private var baseCurrency = "RUB"
    @AppStorage(CategoryCatalog.storageKey) private var categoryData = Data()
    @State private var categoryCatalog = CategoryCatalog.load()
    @StateObject var viewModel: AddExpenseViewModel

    private var categories: [ExpenseCategory] {
        CategoryCatalog.choices(in: categoryCatalog, preserving: viewModel.selectedTag)
    }

    var body: some View {
        NavigationStack {
            ExpenseForm {
                Section("Transaction") {
                    ExpenseField(title: "Amount") {
                      TextField("Amount", text: $viewModel.amount).keyboardType(.decimalPad)
                        .font(.title2.weight(.semibold))
                        .focused($focusedField, equals: .amount)
                    }
                    if attemptedSave, let message = viewModel.validationMessage(for: .amount) {
                        Text(message).font(.caption).foregroundStyle(.red)
                    }
                    ExpenseField(title: "Title") {
                      TextField("Title", text: $viewModel.title)
                        .focused($focusedField, equals: .title)
                    }
                    if attemptedSave, let message = viewModel.validationMessage(for: .title) {
                        Text(message).font(.caption).foregroundStyle(.red)
                    }
                    Button { present(.currency) } label: {
                        ExpenseValueRow(title: "Currency") { Text(viewModel.currency).foregroundStyle(.primary) }
                    }
                    transactionTypePicker
                    ExpenseMenuRow(title: "Payment Method", value: viewModel.selectedPaymentMethod?.title ?? "Not specified") {
                        Button("Not specified") { viewModel.selectedPaymentMethod = nil }
                        ForEach(PaymentMethod.allCases, id: \.self) { method in
                            Button(method.title) { viewModel.selectedPaymentMethod = method }
                        }
                    }
                    .simultaneousGesture(TapGesture().onEnded { focusedField = nil })
                    ExpenseMenuRow(title: "Category", value: categories.first(where: { $0.id == viewModel.selectedTag })?.name ?? "Choose Category",
                        symbol: categories.first(where: { $0.id == viewModel.selectedTag })?.symbol) {
                        ForEach(categories) { category in
                            Button { viewModel.selectedTag = category.id } label: {
                                Label(category.name + (category.isArchived ? " (Archived)" : ""), systemImage: category.symbol)
                            }
                        }
                    }
                    .simultaneousGesture(TapGesture().onEnded { focusedField = nil })
                    if dynamicTypeSize.isAccessibilitySize {
                        ExpenseValueRow(title: "Date") {
                            DatePicker("Date", selection: $viewModel.occuredOn, displayedComponents: .date)
                                .labelsHidden()
                        }
                        .simultaneousGesture(TapGesture().onEnded { focusedField = nil })
                        ExpenseValueRow(title: "Time") {
                            DatePicker("Time", selection: $viewModel.occuredOn, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                        }
                        .simultaneousGesture(TapGesture().onEnded { focusedField = nil })
                    } else {
                        ExpenseValueRow(title: "Date") {
                          DatePicker("Date", selection: $viewModel.occuredOn, displayedComponents: [.date, .hourAndMinute]).labelsHidden()
                            .simultaneousGesture(TapGesture().onEnded { focusedField = nil })
                        }
                    }
                }
                  Section {
                    if viewModel.currency != viewModel.conversionCurrency {
                        if viewModel.isFetchingRate { ProgressView("Fetching daily rate…") }
                        if let converted = viewModel.conversionPreview { LabeledContent("Converted Amount", value: converted) }
                        if let notice = viewModel.rateApproximationNotice {
                            Label(notice, systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let error = viewModel.rateError {
                            Text(viewModel.rateRecoveryMessage ?? "The exchange rate is unavailable. Retry or enter a manual rate in Rate Options.")
                                .font(.caption).foregroundStyle(.red)
                            if viewModel.canRequestNearestRate {
                                Button("Review Available Rate", systemImage: "calendar") {
                                    focusedField = nil
                                    Task { await viewModel.requestNearestRate() }
                                }
                            }
                            Button("Retry Rate", systemImage: "arrow.clockwise") { Task { await viewModel.refreshRate() } }
                            DisclosureGroup("Details") { Text(error).font(.caption).textSelection(.enabled) }
                        }
                    }
                    DisclosureGroup("Rate Options", isExpanded: $showConversionOptions) {
                        if let snapshot = viewModel.rateSnapshot {
                            Text("Rate: \(snapshot.date) • \(snapshot.displaySource)").font(.caption).foregroundStyle(.secondary)
                        }
                        Button { present(.conversion) } label: {
                            LabeledContent("Convert to", value: viewModel.conversionCurrency)
                        }
                        Toggle("Manual Rate", isOn: $viewModel.useManualRate)
                        if viewModel.useManualRate {
                            TextField("1 \(viewModel.currency) = ? \(viewModel.conversionCurrency)", text: $viewModel.manualRate).keyboardType(.decimalPad)
                                .focused($focusedField, equals: .rate)
                        }
                    }
                  } header: { Text("Conversion") }
                Section {
                    DisclosureGroup("Notes & Attachment") {
                        TextField("Note", text: $viewModel.note, axis: .vertical).lineLimit(3...6)
                            .focused($focusedField, equals: .note)
                        Button("Attach Image", systemImage: "paperclip") { focusedField = nil; viewModel.attachImage() }
                        if let image = viewModel.imageAttached {
                            TransactionAttachmentPreview(image: image)
                            Button("Remove Attachment", systemImage: "trash", role: .destructive) {
                                focusedField = nil
                                showAttachmentRemoval = true
                            }
                        }
                    }
                }
            }
            .disabled(viewModel.isSaving)
            .scrollDismissesKeyboard(.interactively)
            .expenseScreenChrome(bottom: false)
            .navigationTitle(viewModel.expenseObj == nil ? "New Transaction" : "Edit Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly).disabled(viewModel.isSaving)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Scan Receipt or Screenshot", systemImage: "doc.viewfinder") { present(.receipt) }
                        .labelStyle(.iconOnly)
                        .accessibilityHint("Review a receipt or banking screenshot using your selected AI provider")
                        .disabled(viewModel.isSaving)
                }
            }
            .expenseBottomBar {
                Button {
                    attemptedSave = true
                    if let invalid = viewModel.firstInvalidField {
                        focusedField = invalid == .amount ? .amount : .title
                        return
                    }
                    focusedField = nil
                    HapticsHelper.shared.hardButtonTap()
                    Task { await viewModel.saveTransaction(managedObjectContext: managedObjectContext) }
                } label: {
                    Label(viewModel.expenseObj == nil ? "Add" : "Save", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .primaryActionStyle()
                .disabled(viewModel.isSaving || viewModel.isFetchingRate)
                .padding(.horizontal, 20).padding(.vertical, 12)
            }
        }
        .interactiveDismissDisabled(viewModel.isSaving)
        .expenseRateConfirmation(viewModel)
        .onChange(of: categoryData) { _, data in categoryCatalog = CategoryCatalog.decode(data) }
        .task(id: viewModel.rateRequestKey) { await viewModel.refreshRate() }
        .task(id: displayScale) { await viewModel.prepareAttachmentPreview(maxPixelSize: 480 * displayScale) }
        .sheet(item: $destination) { destination in
            switch destination {
            case .currency: CurrencyPickerView(selection: $viewModel.currency, title: "Transaction Currency").expenseSheetStyle()
            case .conversion: CurrencyPickerView(selection: $viewModel.conversionCurrency, title: "Conversion Currency").expenseSheetStyle()
            case .receipt: ReceiptImportView(editor: viewModel).expenseSheetStyle(.editor)
            }
        }
        .onReceive(viewModel.$closePresenter) { if $0 { dismiss() } }
        .confirmationDialog("Remove attachment?", isPresented: $showAttachmentRemoval, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { viewModel.removeImage() }
        }
        .alert("Unable to Save", isPresented: $viewModel.showAlert) {
            Button("OK", role: .cancel) { }
        } message: { Text(viewModel.alertMsg) }
    }

    private func present(_ destination: Destination) {
        focusedField = nil
        self.destination = destination
    }

    private var transactionTypePicker: some View {
        ExpenseField(title: "Type") {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    typeButton("Expense", symbol: "arrow.up.right", value: TRANS_TYPE_EXPENSE)
                    typeButton("Income", symbol: "arrow.down.left", value: TRANS_TYPE_INCOME)
                }
                VStack(spacing: 8) {
                    typeButton("Expense", symbol: "arrow.up.right", value: TRANS_TYPE_EXPENSE, wraps: true)
                    typeButton("Income", symbol: "arrow.down.left", value: TRANS_TYPE_INCOME, wraps: true)
                }
            }
        }
    }

    private func typeButton(_ title: String, symbol: String, value: String, wraps: Bool = false) -> some View {
        Button {
            focusedField = nil
            viewModel.selectedType = value
        } label: {
            Label(title, systemImage: symbol).fixedSize(horizontal: !wraps, vertical: true)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(viewModel.selectedType == value ? accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(viewModel.selectedType == value ? accentColor : Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(viewModel.selectedType == value ? [.isSelected] : [])
    }
}

/// Typing changes the editor fields; an unchanged attachment keeps its own
/// rendering boundary and reads no editor observation or conversion state.
private struct TransactionAttachmentPreview: View {
    let image: UIImage

    var body: some View {
        Image(uiImage: image).resizable().scaledToFit()
            .frame(maxHeight: 240).clipShape(RoundedRectangle(cornerRadius: 16))
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityLabel("Transaction attachment")
    }
}

private struct ExpenseRateConfirmation: ViewModifier {
    @ObservedObject var model: AddExpenseViewModel
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .onChange(of: model.nearestRateProposal) { _, proposal in isPresented = proposal != nil }
            .confirmationDialog("Use available exchange rate?", isPresented: $isPresented, titleVisibility: .visible) {
                Button("Use This Rate") { model.acceptNearestRateProposal() }
                Button("Cancel", role: .cancel) { model.dismissNearestRateProposal() }
            } message: {
                if let proposal = model.nearestRateProposal {
                    Text("Use rates from \(dateLabel(proposal.date)) for the transaction dated \(dateLabel(proposal.requestedDate ?? Money.day(model.occuredOn))). The conversion will be marked estimated.")
                }
            }
    }

    private func dateLabel(_ day: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: day) else { return day }
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        return formatter.string(from: date)
    }
}

extension View {
    func expenseRateConfirmation(_ model: AddExpenseViewModel) -> some View {
        modifier(ExpenseRateConfirmation(model: model))
    }
}
