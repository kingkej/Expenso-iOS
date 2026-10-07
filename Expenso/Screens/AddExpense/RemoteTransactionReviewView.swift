import SwiftUI
import UIKit
import CoreData

/// Detection is not import: each candidate must be reviewed before saving.
struct RemoteTransactionReviewView: View {
    let result: RemoteImageTransactions
    @ObservedObject var editor: AddExpenseViewModel
    var onSaved: () -> Void = {}
    var onFinished: () -> Void = {}
    @State private var selection: RemoteImageTransaction?
    @State private var savedIDs = Set<UUID>()
    @State private var openedSingleCandidate = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        List {
            Section {
                if editor.expenseObj == nil { LabeledContent("Added", value: "\(savedIDs.count) of \(result.transactions.count)") }
            }
            if !result.warnings.isEmpty {
                Section("Import Review") {
                    ForEach(Array(Set(result.warnings)).sorted(), id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle").font(.footnote)
                    }
                }
            }
            Section("Detected Transactions") {
                if result.transactions.isEmpty { Text("No transactions were detected. Try another image or text batch.").foregroundStyle(.secondary) }
                ForEach(result.transactions) { candidate in
                    Button { selection = candidate } label: {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(candidate.title ?? "Title Needs Review").foregroundStyle(.primary)
                                Text("\(candidate.amount ?? "Amount missing") \(candidate.currency ?? "Currency missing")")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                if let date = candidate.date { Text(date, format: .dateTime.day().month().year()).font(.caption).foregroundStyle(.secondary) }
                                if !candidate.warnings.isEmpty { Text("\(candidate.warnings.count) review warnings").font(.caption).foregroundStyle(.orange) }
                                if savedIDs.contains(candidate.id), dynamicTypeSize.isAccessibilitySize {
                                    Label("Saved", systemImage: "checkmark.circle.fill").font(.caption)
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            if savedIDs.contains(candidate.id) {
                                if !dynamicTypeSize.isAccessibilitySize { Label("Saved", systemImage: "checkmark.circle.fill").font(.caption) }
                            } else { Image(systemName: "chevron.right").foregroundStyle(.secondary).accessibilityHidden(true) }
                        }.accessibilityElement(children: .combine)
                    }.disabled(savedIDs.contains(candidate.id))
                }
            }
        }
        .expenseScreenChrome()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if selection == nil {
                    Button("Close", systemImage: "xmark", action: onFinished).labelStyle(.iconOnly)
                }
            }
        }
        .task {
            if result.transactions.count == 1, !openedSingleCandidate {
                openedSingleCandidate = true
                selection = result.transactions.first
            }
        }
        .navigationDestination(item: $selection) { candidate in
            RemoteCandidateVerificationView(candidate: candidate, imageData: result.imageData,
                sourceText: result.sourceText, editor: editor,
                onSaved: {
                    savedIDs.insert(candidate.id)
                    onSaved()
                    if result.transactions.count == 1 { onFinished() }
                }, onApplied: onFinished)
        }
    }
}

private struct RemoteCandidateVerificationView: View {
    let candidate: RemoteImageTransaction
    let imageData: Data
    let sourceText: String?
    @ObservedObject var editor: AddExpenseViewModel
    let onSaved: () -> Void
    let onApplied: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var managedObjectContext
    @AppStorage(CategoryCatalog.storageKey) private var categoryData = Data()
    @State private var categoryCatalog = CategoryCatalog.load()
    @StateObject private var reviewModel: AddExpenseViewModel
    @State private var hasDate: Bool
    @State private var replaceCategory = false
    @State private var replacePaymentMethod = false
    @State private var attachImage = false
    @State private var showCurrency = false
    @State private var saved = false
    @State private var saveTask: Task<Void, Never>?
    @State private var sourceImage: UIImage?
    private enum Field: Hashable { case amount, title, rate }
    @FocusState private var focusedField: Field?

    init(candidate: RemoteImageTransaction, imageData: Data, sourceText: String?, editor: AddExpenseViewModel,
         onSaved: @escaping () -> Void, onApplied: @escaping () -> Void) {
        self.candidate = candidate
        self.imageData = imageData
        self.sourceText = sourceText
        self.editor = editor
        self.onSaved = onSaved
        self.onApplied = onApplied
        // Each presented candidate owns an independent, one-time-seeded draft.
        _reviewModel = StateObject(wrappedValue: Self.makeModel(candidate, editor: editor))
        _hasDate = State(initialValue: candidate.date != nil)
    }

    private static func makeModel(_ candidate: RemoteImageTransaction, editor: AddExpenseViewModel) -> AddExpenseViewModel {
        let model = AddExpenseViewModel(paymentMethod: editor.expenseObj != nil ? editor.paymentMethodRawValue : nil)
        model.applyReceipt(title: candidate.title ?? "", amount: candidate.amount ?? "",
            currency: candidate.currency ?? "", date: candidate.date, type: candidate.type ?? "", image: nil,
            paymentMethod: candidate.paymentMethod)
        model.selectedTag = candidate.category ?? ""
        return model
    }

    private var categories: [ExpenseCategory] { categoryCatalog.filter { !$0.isArchived } }
    private var valid: Bool {
        !reviewModel.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && ((try? Money.parse(reviewModel.amount)).map { $0 > 0 } ?? false)
            && CurrencySettings.codes.contains(reviewModel.currency)
            && [TRANS_TYPE_EXPENSE, TRANS_TYPE_INCOME].contains(reviewModel.selectedType)
            && hasDate
            && (editor.expenseObj != nil && !replaceCategory || categories.contains { $0.id == reviewModel.selectedTag })
    }

    private var missingFields: [String] {
        var missing: [String] = []
        if !((try? Money.parse(reviewModel.amount)).map { $0 > 0 } ?? false) { missing.append("an amount greater than zero") }
        if reviewModel.validationMessage(for: .title) != nil { missing.append("a title") }
        if !CurrencySettings.codes.contains(reviewModel.currency) { missing.append("a currency") }
        if ![TRANS_TYPE_EXPENSE, TRANS_TYPE_INCOME].contains(reviewModel.selectedType) { missing.append("Expense or Income") }
        if !hasDate { missing.append("a date") }
        if (editor.expenseObj == nil || replaceCategory), !categories.contains(where: { $0.id == reviewModel.selectedTag }) { missing.append("a category") }
        return missing
    }

    var body: some View {
            ExpenseForm {
                Section {
                    ExpenseField(title: "Amount") {
                      TextField("Amount", text: $reviewModel.amount).keyboardType(.decimalPad)
                        .font(.title2.weight(.semibold))
                        .focused($focusedField, equals: .amount)
                    }
                    ExpenseField(title: "Title") {
                      TextField("Title", text: $reviewModel.title)
                        .focused($focusedField, equals: .title)
                    }
                    Button { focusedField = nil; showCurrency = true } label: {
                        ExpenseValueRow(title: "Currency") { Text(reviewModel.currency.isEmpty ? "Choose Currency" : reviewModel.currency).foregroundStyle(.primary) }
                    }
                    ExpenseMenuRow(title: "Type", value: reviewModel.selectedType == TRANS_TYPE_EXPENSE ? "Expense" : reviewModel.selectedType == TRANS_TYPE_INCOME ? "Income" : "Choose Type") {
                        Button("Expense") { reviewModel.selectedType = TRANS_TYPE_EXPENSE }
                        Button("Income") { reviewModel.selectedType = TRANS_TYPE_INCOME }
                    }
                    .simultaneousGesture(TapGesture().onEnded { focusedField = nil })
                    if editor.expenseObj != nil { Toggle("Replace Current Category", isOn: $replaceCategory) }
                    ExpenseMenuRow(title: "Payment Method", value: reviewModel.selectedPaymentMethod?.title ?? "Not specified") {
                        Button("Not specified") {
                            reviewModel.selectedPaymentMethod = nil
                            replacePaymentMethod = true
                        }
                        ForEach(PaymentMethod.allCases, id: \.self) { method in
                            Button(method.title) {
                                reviewModel.selectedPaymentMethod = method
                                replacePaymentMethod = true
                            }
                        }
                    }
                    .simultaneousGesture(TapGesture().onEnded { focusedField = nil })
                    if editor.expenseObj == nil || replaceCategory {
                        ExpenseMenuRow(title: "Category", value: categories.first(where: { $0.id == reviewModel.selectedTag })?.name ?? "Choose Category",
                            symbol: categories.first(where: { $0.id == reviewModel.selectedTag })?.symbol) {
                            ForEach(categories) { item in
                                Button { reviewModel.selectedTag = item.id } label: { Label(item.name, systemImage: item.symbol) }
                            }
                        }
                        .simultaneousGesture(TapGesture().onEnded { focusedField = nil })
                    }
                    if hasDate {
                        ExpenseValueRow(title: "Date") {
                          DatePicker("Date", selection: $reviewModel.occuredOn, displayedComponents: .date).labelsHidden()
                            .simultaneousGesture(TapGesture().onEnded { focusedField = nil })
                        }
                    }
                    else {
                        Button("Choose Date", systemImage: "calendar") { reviewModel.occuredOn = Date(); hasDate = true }
                    }
                    if !imageData.isEmpty { Toggle("Attach This Image", isOn: $attachImage) }
                }
                if editor.expenseObj == nil, hasDate, CurrencySettings.codes.contains(reviewModel.currency),
                   reviewModel.currency != reviewModel.conversionCurrency {
                    Section("Conversion to \(reviewModel.conversionCurrency)") {
                        if reviewModel.isFetchingRate { ProgressView("Fetching rate…") }
                        if let converted = reviewModel.conversionPreview { LabeledContent("Amount", value: converted) }
                        if let notice = reviewModel.rateApproximationNotice {
                            Label(notice, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
                        }
                        if let error = reviewModel.rateError {
                            Text(reviewModel.rateRecoveryMessage ?? "The exchange rate is unavailable. Retry or enter a manual rate in Rate Options.")
                                .font(.caption).foregroundStyle(.red)
                            if reviewModel.canRequestNearestRate {
                                Button("Review Available Rate", systemImage: "calendar") {
                                    focusedField = nil
                                    Task { await reviewModel.requestNearestRate() }
                                }
                            }
                            Button("Retry Rate", systemImage: "arrow.clockwise") { Task { await reviewModel.refreshRate() } }
                            DisclosureGroup("Details") { Text(error).font(.caption).textSelection(.enabled) }
                        }
                        DisclosureGroup("Rate Options") {
                            Toggle("Manual Rate", isOn: $reviewModel.useManualRate)
                            if reviewModel.useManualRate {
                                TextField("1 \(reviewModel.currency) = ? \(reviewModel.conversionCurrency)", text: $reviewModel.manualRate)
                                    .keyboardType(.decimalPad).focused($focusedField, equals: .rate)
                            }
                        }
                    }
                }
                if !candidate.warnings.isEmpty {
                    Section("Needs Review") {
                        ForEach(Array(Set(candidate.warnings)).sorted(), id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle").font(.footnote)
                        }
                    }
                }
                if !missingFields.isEmpty {
                    Section("Complete This Transaction") {
                        Text("Choose \(missingFields.joined(separator: ", ")) before adding this transaction.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let sourceText {
                    Section("Original Text") {
                        DisclosureGroup("Show Source") { Text(sourceText).font(.footnote).textSelection(.enabled) }
                    }
                } else if let image = sourceImage {
                    Section("Original Image") {
                        DisclosureGroup("Show Source") {
                            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 320)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .frame(maxWidth: .infinity, alignment: .center)
                                .accessibilityLabel("Original import image")
                        }
                    }
                }
            }
            .disabled(reviewModel.isSaving)
            .scrollDismissesKeyboard(.interactively)
            .expenseScreenChrome(bottom: false)
            .navigationTitle("Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(reviewModel.isSaving || saveTask != nil)
            .expenseBottomBar {
                Button {
                    continueReview()
                } label: {
                    Label(editor.expenseObj == nil ? "Add" : "Apply to Draft", systemImage: "checkmark")
                        .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                }
                .primaryActionStyle().disabled(!valid || saved || reviewModel.isSaving || saveTask != nil || reviewModel.isFetchingRate)
                .padding()
            }
            .sheet(isPresented: $showCurrency) { CurrencyPickerView(selection: $reviewModel.currency, title: "Currency").expenseSheetStyle() }
            .alert("Unable to Add", isPresented: $reviewModel.showAlert) { Button("OK", role: .cancel) { } }
                message: { Text(reviewModel.alertMsg) }
        .interactiveDismissDisabled(reviewModel.isSaving || saveTask != nil)
        .expenseRateConfirmation(reviewModel)
        .onChange(of: categoryData) { _, data in categoryCatalog = CategoryCatalog.decode(data) }
        .onChange(of: reviewModel.currency) { _, _ in resetRate() }
        .onChange(of: Money.day(reviewModel.occuredOn)) { _, _ in resetRate() }
        .task(id: reviewModel.rateRequestKey + "|\(hasDate)") {
            guard editor.expenseObj == nil, hasDate, CurrencySettings.codes.contains(reviewModel.currency) else { return }
            await reviewModel.refreshRate()
        }
        .onDisappear { saveTask?.cancel() }
        .task {
            // Decode once for this candidate, rather than on every keystroke.
            sourceImage = sourceText == nil ? UIImage(data: imageData) : nil
        }
    }

    private func resetRate() {
        reviewModel.rateSnapshot = nil
        reviewModel.useManualRate = false
        reviewModel.manualRate = ""
        reviewModel.rateError = nil
    }

    private func continueReview() {
        guard valid, !saved, saveTask == nil else { return }
        focusedField = nil
        let image = attachImage ? UIImage(data: imageData) : nil
        if editor.expenseObj != nil {
            editor.applyReceipt(title: reviewModel.title, amount: reviewModel.amount, currency: reviewModel.currency,
                date: reviewModel.occuredOn, type: reviewModel.selectedType, image: image,
                paymentMethod: reviewModel.selectedPaymentMethod, replacePaymentMethod: replacePaymentMethod)
            if replaceCategory { editor.selectedTag = reviewModel.selectedTag; editor.tagTitle = getTransTagTitle(transTag: reviewModel.selectedTag) }
            onApplied()
            dismiss()
        } else {
            reviewModel.imageAttached = image
            reviewModel.tagTitle = getTransTagTitle(transTag: reviewModel.selectedTag)
            saveTask = Task { @MainActor in
                await reviewModel.saveTransaction(managedObjectContext: managedObjectContext)
                saveTask = nil
                guard reviewModel.closePresenter, !saved else { return }
                saved = true
                onSaved()
                dismiss()
            }
        }
    }
}
