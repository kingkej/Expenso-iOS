import SwiftUI
import CoreData

private struct ClassificationEditDestination: Identifiable {
    let id: NSManagedObjectID
    let title: String
    let label: String?
}

struct ClassificationSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context
    @AppStorage(CategoryCatalog.storageKey) private var categoryData = Data()
    @State private var store = SpendingClassificationStore.shared
    @State private var settings = OpenRouterSettings.shared
    @State private var rows: [HistoryLedgerProjection] = []
    @State private var search = ""
    @State private var confirmEnable = false
    @State private var fetchError: String?
    @State private var edit: ClassificationEditDestination?
    @State private var showAccount = false
    @State private var selectedType: String?
    @FocusState private var searchFocused: Bool

    private var typeCounts: [(label: String, count: Int)] {
        Dictionary(grouping: rows, by: { store.label(for: $0) ?? "Unclassified" })
            .map { (label: $0.key, count: $0.value.count) }
            .sorted { $0.count == $1.count ? $0.label.localizedStandardCompare($1.label) == .orderedAscending : $0.count > $1.count }
    }

    private var visibleRows: [HistoryLedgerProjection] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter {
            (selectedType == nil || (store.label(for: $0) ?? "Unclassified") == selectedType)
                && (query.isEmpty || $0.record.title.localizedCaseInsensitiveContains(query)
                || categoryName($0.record.category).localizedCaseInsensitiveContains(query)
                || (store.label(for: $0) ?? "Unclassified").localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("AI Spending Types", systemImage: "sparkles", isOn: Binding(
                        get: { store.enabled },
                        set: { searchFocused = false; if $0 { confirmEnable = true } else { store.disable() } }))
                    if !settings.hasKey {
                        Label("An OpenRouter API key is required for AI classification.", systemImage: "key")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("OpenRouter Account", systemImage: "person.crop.circle") { searchFocused = false; showAccount = true }
                } header: { Text("Automatic Suggestions") } footer: {
                    Text("Optional online AI sends expense titles, categories and previous AI suggestions to OpenRouter. Charges may apply. This is separate from your chat provider; your categories stay unchanged.")
                }
                .expenseFormSectionSurface()

                Section("Suggestions") {
                    if store.isRunning {
                        ProgressView(value: Double(store.completedCount), total: Double(max(1, store.totalCount))) {
                            Text("\(store.completedCount) of \(store.totalCount) expenses")
                        }
                        Button("Stop", role: .cancel) { store.cancel() }
                    } else {
                        if let completed = store.lastCompletedAt {
                            LabeledContent("Last Updated") { Text(completed, format: .dateTime.day().month().year().hour().minute()) }
                        }
                        Button("Update Suggestions", systemImage: "arrow.clockwise") { store.runNow(context: context) }
                            .disabled(!store.enabled || !settings.hasKey)
                    }
                    if let message = store.errorMessage { Text(message).foregroundStyle(.red) }
                    DisclosureGroup("More options") {
                        Button("Reload Saved Types", systemImage: "externaldrive") { store.reload() }
                        LabeledContent("Reviewed Expenses", value: "\(rows.filter { store.entry(for: $0) != nil }.count) of \(rows.count)")
                        Text("Reviewed expenses have a saved result, even when no type was suggested.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .expenseFormSectionSurface()

                Section {
                    LabeledContent("Expenses with Types", value: "\(rows.filter { store.label(for: $0) != nil }.count) of \(rows.count)")
                    ForEach(typeCounts, id: \.label) { type in
                        Button {
                            selectedType = selectedType == type.label ? nil : type.label
                        } label: {
                            HStack {
                                Text(type.label).foregroundStyle(.primary)
                                Spacer()
                                Text("\(type.count)").foregroundStyle(.secondary)
                                if selectedType == type.label { Image(systemName: "checkmark") }
                            }
                        }
                        .accessibilityHint("Filters the expense list below by this spending type")
                    }
                    if selectedType != nil {
                        Button("Show All Expenses") { selectedType = nil }
                    }
                } header: { Text("Saved Results · All Time") } footer: {
                    Text("Tap a type to filter expenses. Suggestions can be wrong; tap an expense to correct its type.")
                }
                .expenseFormSectionSurface()

                Section {
                    if let fetchError { Text(fetchError).foregroundStyle(.red) }
                    if visibleRows.isEmpty {
                        Text(search.isEmpty && selectedType == nil ? "No expense transactions." : "No matching expenses.").foregroundStyle(.secondary)
                    }
                    ForEach(visibleRows, id: \.id) { row in
                        let label = store.label(for: row)
                        Button {
                            searchFocused = false
                            edit = ClassificationEditDestination(id: row.id, title: row.record.title, label: label)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(row.record.title.isEmpty ? "Untitled Transaction" : row.record.title).foregroundStyle(.primary)
                                Text("\(categoryName(row.record.category)) · \(label ?? "Unclassified")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } header: { Text("Review Expenses") } footer: {
                    Text("Your corrections are kept. While enabled, suggestions update daily when you open the app. Types stay on this device and are not included in backups.")
                }
                .expenseFormSectionSurface()
            }
            .searchable(text: $search, prompt: "Title, category or spending type")
            .searchFocused($searchFocused)
            .scrollDismissesKeyboard(.interactively)
            .expenseScreenChrome()
            .navigationTitle("Spending Types")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { searchFocused = false; dismiss() }.labelStyle(.iconOnly)
                }
            }
            .confirmationDialog("Enable AI Spending Types?", isPresented: $confirmEnable, titleVisibility: .visible) {
                Button("Enable and Classify Expenses") { store.enableAndRun(context: context) }
                    .disabled(!settings.hasKey)
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Titles, categories and previous AI-suggested type names will be sent in batches to OpenRouter for all expenses. Future new or edited expenses are checked on the first app opening each day. No manual type names, amounts, notes or receipt images are sent by classification. This uses your OpenRouter account and may cost money. AI suggestions can be wrong; you can correct them locally or disable automatic classification anytime.")
            }
            .sheet(item: $edit) { destination in
                ClassificationLabelEditor(id: destination.id, title: destination.title, currentLabel: destination.label)
                    .expenseSheetStyle(.editor)
            }
            .sheet(isPresented: $showAccount) { AISettingsView().expenseSheetStyle(.editor) }
            .onAppear { reloadRows() }
            .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange, object: context)) { notification in
                let changes = notification.userInfo ?? [:]
                let changed = [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey, NSRefreshedObjectsKey].contains { key in
                    (changes[key] as? Set<NSManagedObject>)?.contains { $0.entity.name == "ExpenseCD" } == true
                }
                if changed || changes[NSInvalidatedAllObjectsKey] != nil { reloadRows() }
            }
        }
    }

    private func categoryName(_ id: String) -> String {
        CategoryCatalog.decode(categoryData).first { $0.id == id }?.name ?? (id.isEmpty ? "Uncategorized" : id)
    }

    private func reloadRows() {
        do {
            rows = try HistoryLedgerProjection.fetch(in: context).filter { $0.record.type == TRANS_TYPE_EXPENSE }
            fetchError = nil
        } catch { fetchError = "Expense transactions could not be read. Try reopening this screen." }
    }
}

private struct ClassificationLabelEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context
    @State private var store = SpendingClassificationStore.shared
    @State private var label: String
    @FocusState private var labelFocused: Bool
    @State private var errorMessage: String?
    let id: NSManagedObjectID
    let title: String

    init(id: NSManagedObjectID, title: String, currentLabel: String?) {
        self.id = id
        self.title = title
        _label = State(initialValue: currentLabel ?? "")
    }

    private var existingLabels: [String] {
        Set(store.entries.values.compactMap(\.label)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            ExpenseForm {
                Section {
                    Text(title.isEmpty ? "Untitled Transaction" : title)
                    ExpenseField(title: "Spending Type") {
                        TextField("Spending type in English", text: $label).textInputAutocapitalization(.words)
                            .focused($labelFocused)
                    }
                    Button("Unclassified") { labelFocused = false; label = "" }
                    DisclosureGroup("About manual types") {
                        Text("Saved locally without contacting AI or changing the category. Manual types are excluded from automatic classification uploads. They may be shared in reports when you ask an OpenRouter chat question. An empty type keeps this expense unclassified.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                if !existingLabels.isEmpty {
                    Section("Existing Types") {
                        ForEach(existingLabels, id: \.self) { value in Button(value) { labelFocused = false; label = value } }
                    }

                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }

                }
            }
            .scrollDismissesKeyboard(.interactively)
            .expenseScreenChrome()
            .navigationTitle("Edit Spending Type")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { labelFocused = false; dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
        }
    }

    private func save() {
        labelFocused = false
        do {
            guard let expense = try context.existingObject(with: id) as? ExpenseCD, !expense.isDeleted else {
                errorMessage = "This transaction is no longer available."
                return
            }
            let value = label.trimmingCharacters(in: .whitespacesAndNewlines)
            try store.setManual(label: value.isEmpty ? nil : value, for: expense)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
