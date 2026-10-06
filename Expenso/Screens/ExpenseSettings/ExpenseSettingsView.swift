//
//  ExpenseSettingsView.swift
//  Expenso
//
//  Created by Sameer Nawaz on 31/01/21.
//

import SwiftUI
import CoreData

struct ExpenseSettingsView: View {
    private enum Sheet: String, Identifiable {
        case accent, categories, backup, currency, rateReview, ai, classification
        var id: String { rawValue }
    }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var managedObjectContext
    @StateObject private var viewModel = ExpenseSettingsViewModel()
    @AppStorage(CurrencySettings.key) private var baseCurrency = "RUB"
    @AppStorage(AppAccent.storageKey) private var accentSelection = AppAccent.original.rawValue
    @AppStorage(AmountDisplaySettings.compactKey) private var compactAmounts = false
    @AppStorage(GlassAppearanceSettings.motionKey) private var motionReflections = false
    @State private var proposedCurrency = CurrencySettings.base
    @State private var sheet: Sheet?
    @State private var confirmReviewedRates = false

    var body: some View {
        NavigationStack {
            ExpenseForm {
                Section {
                    Button { sheet = .accent } label: {
                        ExpenseValueRow(title: "Accent Color") { Text(AppAccent.resolve(accentSelection).title) }
                    }
                    Toggle("Motion Reflections", systemImage: "sparkle", isOn: $motionReflections)
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Personalize your glass accents. Motion reflections gently follow your phone’s tilt and respect Reduce Motion.")
                }

                Section {
                    Toggle("Compact Amounts", systemImage: "number", isOn: $compactAmounts)
                } header: {
                    Text("Amounts")
                } footer: {
                    Text("Show shorter summaries, such as \(Money.display(12_500, currency: baseCurrency, compact: true)). Transaction details keep the full amount.")
                }

                Section {
                    Button {
                        sheet = .categories
                    } label: {
                        Label("Categories", systemImage: "tag")
                    }
                } header: { Text("Transactions") } footer: {
                    Text("Create and organize categories. Archiving keeps existing transactions intact.")
                }

                Section {
                    Toggle(isOn: $viewModel.enableBiometric) {
                        Label("Enable \(viewModel.getBiometricType())", systemImage: "lock.shield")
                    }
                } header: {
                    Text("Security")
                } footer: {
                    Text("Require authentication when opening \(APP_NAME).")
                }

                Section {
                    Button { sheet = .currency } label: {
                        ExpenseValueRow(title: "Main Currency") { Text(proposedCurrency) }
                    }
                    if proposedCurrency != baseCurrency {
                        Button("Apply \(proposedCurrency)", systemImage: "checkmark") {
                            Task { await viewModel.saveCurrency(currency: proposedCurrency, context: managedObjectContext) }
                        }
                    }
                    if viewModel.isChangingCurrency { ProgressView("Updating conversions…") }
                } header: { Text("Currencies") } footer: {
                    Text("Use \(baseCurrency) for summaries and new transactions. Original amounts stay unchanged.")
                }

                .disabled(viewModel.isChangingCurrency)
                Section {
                    DisclosureGroup("About exchange rates") {
                        Text("Conversions use saved daily rates. When a historical rate is missing, you can review an estimated rate or enter one manually. The actual rate date stays available in transaction details.")
                        Text("Only public rate tables are requested. Your transaction amounts, titles and notes are never sent. Saved rates do not expire.")
                    }
                    .font(.footnote)
                }

                Section("AI") {
                    Button("AI Provider", systemImage: "cpu") { sheet = .ai }
                    Button("AI Spending Types", systemImage: "sparkles") { sheet = .classification }
                }

                Section {
                    Button {
                        sheet = .backup
                    } label: {
                        Label("Backup & Restore", systemImage: "externaldrive")
                    }
                    Button {
                        viewModel.exportTransactions(moc: managedObjectContext)
                    } label: {
                        Label("Export Transactions", systemImage: "square.and.arrow.up")
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text("Share a CSV file containing your transactions.")
                }

            }
            .disabled(viewModel.isChangingCurrency)
            .expenseScreenChrome()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly).disabled(viewModel.isChangingCurrency)
                }
            }
            .sheet(item: $sheet, onDismiss: finishSheet) { destination in
                Group {
                    switch destination {
                    case .accent: AccentSettingsSheet(selection: accentBinding)
                    case .categories: CategorySettingsSheet()
                    case .backup: BackupRestoreView()
                    case .ai: AISettingsView()
                    case .classification: ClassificationSettingsView()
                    case .currency: CurrencyPickerView(selection: $proposedCurrency, title: "Base Currency")
                    case .rateReview:
                        if let review = viewModel.currencyChangeReview {
                            NearestRatesReviewSheet(review: review) { confirmReviewedRates = true }
                        }
                    }
                }
                .expenseSheetStyle(destination == .accent || destination == .currency ? .floating : .editor)
            }
            .onChange(of: viewModel.currencyChangeReview?.id) { _, id in
                if id != nil { sheet = .rateReview }
            }
            .interactiveDismissDisabled(viewModel.isChangingCurrency)
            .alert(APP_NAME, isPresented: $viewModel.showAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(viewModel.alertMsg)
            }
        }
    }

    private func finishSheet() {
        // Commit after dismissal so any concurrency/save error can be presented
        // on Settings without competing with the closing review sheet.
        if confirmReviewedRates { viewModel.confirmCurrencyChange() }
        else { viewModel.cancelCurrencyChange() }
        confirmReviewedRates = false
    }

    private var accentBinding: Binding<AppAccent> {
        Binding(
            get: { AppAccent.resolve(accentSelection) },
            set: { accentSelection = $0.rawValue }
        )
    }
}

private struct NearestRatesReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let review: CurrencyChangeReview
    let confirm: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Estimated conversions", systemImage: "calendar.badge.exclamationmark")
                        .font(.headline)
                    Text("\(review.affectedCount) transactions need rates from a different day to display totals in \(review.currency). These are estimates, not the exchange rates on the transaction dates.")
                    Text("The closest published date is used; ties prefer the earlier day. For old records, the gap can be months or years.")
                        .foregroundStyle(.secondary)
                }
                Section("Transaction date → rate date") {
                    ForEach(review.substitutions) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(item.dates.requestedDate) → \(item.dates.rateDate)")
                                .font(.body.monospacedDigit())
                            Text("\(item.count) transactions").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Text("Original amounts, currencies and transaction dates stay unchanged. Existing locked rates are kept. The actual rate date will be saved and shown in transaction details and exports.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .expenseScreenChrome()
            .navigationTitle("Review Exchange Rates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Nearest Rates") { confirm(); dismiss() }
                }
            }
        }
    }
}

private struct AccentSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: AppAccent

    var body: some View {
        NavigationStack {
            List(AppAccent.allCases) { accent in
                Button { selection = accent } label: {
                    HStack {
                        Label { Text(accent.title) } icon: {
                            Image(systemName: "circle.fill").foregroundStyle(accent.color)
                        }
                        Spacer()
                        if selection == accent { Image(systemName: "checkmark").accessibilityLabel("Selected") }
                    }
                    .foregroundStyle(.primary)
                }
                .accessibilityAddTraits(selection == accent ? .isSelected : [])
            }
            .expenseScreenChrome()
            .navigationTitle("Accent Color")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                }
            }
        }
    }
}

struct ExpenseSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        ExpenseSettingsView()
    }
}
