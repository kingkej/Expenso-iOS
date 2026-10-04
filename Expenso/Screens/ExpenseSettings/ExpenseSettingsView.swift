//
//  ExpenseSettingsView.swift
//  Expenso
//
//  Created by Sameer Nawaz on 31/01/21.
//

import SwiftUI
import CoreData

struct ExpenseSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var managedObjectContext
    @StateObject private var viewModel = ExpenseSettingsViewModel()
    @AppStorage(CurrencySettings.key) private var baseCurrency = "RUB"
    @AppStorage(AppAccent.storageKey) private var accentSelection = AppAccent.original.rawValue
    @State private var proposedCurrency = CurrencySettings.base
    @State private var showCurrencyPicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Accent Color", selection: accentBinding) {
                        ForEach(AppAccent.allCases) { accent in
                            Label {
                                Text(accent.title)
                            } icon: {
                                Image(systemName: "circle.fill")
                                    .foregroundStyle(accent.color)
                            }
                            .tag(accent)
                        }
                    }
                    .pickerStyle(.navigationLink)
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Personalize buttons, tabs and highlights. Changes apply immediately and are saved on this device.")
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
                    Button { showCurrencyPicker = true } label: {
                        LabeledContent("Base Currency", value: proposedCurrency)
                    }
                    if proposedCurrency != baseCurrency {
                        Button("Apply \(proposedCurrency)", systemImage: "checkmark") {
                            Task { await viewModel.saveCurrency(currency: proposedCurrency, context: managedObjectContext) }
                        }
                    }
                    if viewModel.isChangingCurrency { ProgressView("Preparing locked daily rates…") }
                } header: { Text("Currencies") } footer: {
                    Text("Totals use \(baseCurrency). New transactions default to this currency; each transaction can use another. Existing records are RUB. Changing base uses saved historical rates and never relabels original amounts. Missing historical quotes must be supplied manually by editing the transaction.")
                }
                .disabled(viewModel.isChangingCurrency)
                Section("Exchange Rates") {
                    Label("Daily rates • 24-hour cache", systemImage: "arrow.triangle.2.circlepath")
                    Text("Only a date and currency reference are requested from the rate service. Transaction amounts, titles and notes are never sent. Saved transaction rates don't expire.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section {
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
            .scrollContentBackground(.hidden)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly).disabled(viewModel.isChangingCurrency)
                }
            }
            .sheet(isPresented: $showCurrencyPicker) {
                CurrencyPickerView(selection: $proposedCurrency, title: "Base Currency").expenseSheetStyle()
            }
            .interactiveDismissDisabled(viewModel.isChangingCurrency)
            .alert(APP_NAME, isPresented: $viewModel.showAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(viewModel.alertMsg)
            }
        }
    }

    private var accentBinding: Binding<AppAccent> {
        Binding(
            get: { AppAccent.resolve(accentSelection) },
            set: { accentSelection = $0.rawValue }
        )
    }
}

struct ExpenseSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        ExpenseSettingsView()
    }
}
