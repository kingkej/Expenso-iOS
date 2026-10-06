import SwiftUI

/// Catalog operations never rewrite transaction category IDs or delete ledger records.
struct CategorySettingsView: View {
    @AppStorage(CategoryCatalog.storageKey) private var categoryData = Data()
    @State private var editor: CategoryEditDestination?
    @State private var errorMessage: String?
    private var categories: [ExpenseCategory] { CategoryCatalog.decode(categoryData) }

    var body: some View {
        List {
            Section {
                ForEach(categories) { category in
                    Button { editor = CategoryEditDestination(category: category) } label: {
                        HStack {
                            Label(category.name, systemImage: category.symbol)
                                .foregroundStyle(category.isArchived ? .secondary : .primary)
                            Spacer()
                            if category.isArchived { Text("Archived").font(.caption).foregroundStyle(.secondary) }
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(category.isArchived ? "Unarchive" : "Archive", systemImage: category.isArchived ? "tray.and.arrow.up" : "archivebox") {
                            setArchived(!category.isArchived, id: category.id)
                        }
                        .tint(category.isArchived ? .green : .orange)
                    }
                }
                .onMove(perform: move)
            } footer: {
                Text("Rename, reorder or archive categories. Archiving keeps existing transactions. Keep at least one category active.")
            }
        }
        .expenseScreenChrome()
        .navigationTitle("Categories")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Button("New Category", systemImage: "plus") {
                    editor = CategoryEditDestination(category: ExpenseCategory(
                        id: "custom." + UUID().uuidString.lowercased(), name: "", symbol: CategoryCatalog.symbols.first ?? "tag", isArchived: false))
                }
            }
        }
        .sheet(item: $editor) { destination in
            CategoryEditorView(category: destination.category).expenseSheetStyle(.editor)
        }
        .alert("Unable to Update Categories", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func setArchived(_ archived: Bool, id: String) {
        var updated = categories
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        updated[index].isArchived = archived
        persist(updated)
    }

    private func move(from offsets: IndexSet, to destination: Int) {
        var updated = categories
        updated.move(fromOffsets: offsets, toOffset: destination)
        persist(updated)
    }

    private func persist(_ categories: [ExpenseCategory]) {
        do { try CategoryCatalog.save(categories) }
        catch { errorMessage = error.localizedDescription }
    }
}

/// Standalone category management owns its sheet navigation and dismissal.
struct CategorySettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            CategorySettingsView()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                    }
                }
        }
    }
}

private struct CategoryEditDestination: Identifiable {
    let category: ExpenseCategory
    var id: String { category.id }
}

private struct CategoryEditorView: View {
    private enum Sheet: String, Identifiable {
        case symbol
        var id: String { rawValue }
    }
    @Environment(\.dismiss) private var dismiss
    @AppStorage(CategoryCatalog.storageKey) private var categoryData = Data()
    let category: ExpenseCategory
    @State private var name: String
    @State private var symbol: String
    @State private var isArchived: Bool
    @State private var errorMessage: String?
    @State private var sheet: Sheet?
    @FocusState private var nameFocused: Bool

    init(category: ExpenseCategory) {
        self.category = category
        _name = State(initialValue: category.name)
        _symbol = State(initialValue: category.symbol)
        _isArchived = State(initialValue: category.isArchived)
    }

    var body: some View {
        NavigationStack {
            ExpenseForm {
                Section("Category") {
                    ExpenseField(title: "Name") {
                        TextField("Name", text: $name)
                            .textInputAutocapitalization(.words)
                            .focused($nameFocused)
                    }
                    Button { nameFocused = false; sheet = .symbol } label: {
                        ExpenseValueRow(title: "Symbol") {
                            Image(systemName: symbol).accessibilityLabel(symbol.replacingOccurrences(of: ".", with: " "))
                        }
                    }
                    Toggle("Archived", isOn: $isArchived)
                }
                Section {
                    Label(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Category Preview" : name, systemImage: symbol)
                } header: { Text("Preview") } footer: {
                    Text("Choose a unique name, up to 40 characters. Archiving keeps existing transactions.")
                }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
            }
            .scrollDismissesKeyboard(.interactively)
            .expenseScreenChrome()
            .navigationTitle(category.name.isEmpty ? "New Category" : "Edit Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { nameFocused = false; dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
            .sheet(item: $sheet) { _ in
                CategorySymbolSheet(selection: $symbol).expenseSheetStyle()
            }
        }
    }

    private func save() {
        nameFocused = false
        // Merge the current catalog so a concurrently changed order or unrelated category is retained.
        let categories = CategoryCatalog.decode(categoryData)
        let updated = ExpenseCategory(id: category.id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines), symbol: symbol, isArchived: isArchived)
        do {
            let next = try CategoryCatalog.applying(updated, replacing: category.name.isEmpty ? nil : category, in: categories)
            try CategoryCatalog.save(next)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct CategorySymbolSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String

    var body: some View {
        NavigationStack {
            List(CategoryCatalog.symbols, id: \.self) { value in
                Button {
                    selection = value
                    dismiss()
                } label: {
                    HStack {
                        Label(value.replacingOccurrences(of: ".", with: " ").capitalized, systemImage: value)
                        Spacer()
                        if selection == value { Image(systemName: "checkmark").accessibilityLabel("Selected") }
                    }
                    .foregroundStyle(.primary)
                }
                .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
            .expenseScreenChrome()
            .navigationTitle("Category Symbol")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                }
            }
        }
    }
}
