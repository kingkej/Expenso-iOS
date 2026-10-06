import SwiftUI
import CoreData

private struct HistoryRow: Identifiable, Sendable {
    let id: NSManagedObjectID
    let record: TransactionHistoryRecord
    let originalLabel: String
    let convertedLabel: String?
    let baseAmount: Decimal?
    let usesEstimatedConversion: Bool
}

struct HistoryFilteredTotals: Sendable {
    var income: Decimal? = 0
    var expense: Decimal? = 0
    var netCashFlow: Decimal? = 0
    var excludedUnknownTypes = 0
    var estimatedConversionCount = 0

    static func compute(_ records: [(type: String, amount: Decimal?)], estimatedCount: Int = 0) -> Self {
        var totals = Self()
        totals.estimatedConversionCount = max(0, estimatedCount)
        for record in records {
            guard record.type == TRANS_TYPE_INCOME || record.type == TRANS_TYPE_EXPENSE else {
                totals.excludedUnknownTypes += 1
                continue
            }
            let isIncome = record.type == TRANS_TYPE_INCOME
            guard let amount = record.amount, !amount.isNaN, amount >= 0 else {
                if isIncome { totals.income = nil } else { totals.expense = nil }
                totals.netCashFlow = nil
                continue
            }
            if isIncome, let income = totals.income { totals.income = try? Money.add(income, amount) }
            if !isIncome, let expense = totals.expense { totals.expense = try? Money.add(expense, amount) }
            if let net = totals.netCashFlow { totals.netCashFlow = try? Money.add(net, isIncome ? amount : -amount) }
        }
        return totals
    }
}

/// A dictionary projection never materializes receipt images or managed-object rows.
struct HistoryLedgerProjection: Sendable {
    let id: NSManagedObjectID
    let record: TransactionHistoryRecord
    let createdAt: Date?
    let rateSnapshotData: Data?

    static func request(entity: NSEntityDescription) -> NSFetchRequest<NSDictionary> {
        let request = NSFetchRequest<NSDictionary>(entityName: "ExpenseCD")
        request.resultType = .dictionaryResultType
        // Dictionary results do not reliably merge pending edits. Overlay them explicitly below.
        request.includesPendingChanges = false
        let identity = NSExpressionDescription()
        identity.name = "historyObjectID"
        identity.expression = NSExpression(format: "SELF")
        identity.expressionResultType = .objectIDAttributeType
        let names = ["title", "note", "type", "tag", "occuredOn", "createdAt", "amount",
                     "currencyCode", "amountText", "rateSnapshotData"]
        var properties: [Any] = [identity]
        properties.append(contentsOf: names.compactMap { entity.attributesByName[$0] })
        request.propertiesToFetch = properties
        return request
    }

    static func fetch(in context: NSManagedObjectContext) throws -> [Self] {
        guard let entity = NSEntityDescription.entity(forEntityName: "ExpenseCD", in: context) else { return [] }
        var projections: [NSManagedObjectID: Self] = [:]
        for values in try context.fetch(request(entity: entity)) {
            guard let id = values["historyObjectID"] as? NSManagedObjectID else { continue }
            let currency = values["currencyCode"] as? String ?? "RUB"
            let amount: Decimal?
            if let text = values["amountText"] as? String {
                amount = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
            } else if let number = values["amount"] as? NSNumber, number.doubleValue.isFinite, number.doubleValue >= 0 {
                amount = Decimal(string: String(number.doubleValue), locale: Locale(identifier: "en_US_POSIX"))
            } else { amount = nil }
            projections[id] = Self(id: id, record: TransactionHistoryRecord(
                title: values["title"] as? String ?? "", note: values["note"] as? String ?? "",
                type: values["type"] as? String ?? "", category: values["tag"] as? String ?? "",
                currency: currency, originalAmount: amount, occurredOn: values["occuredOn"] as? Date),
                createdAt: values["createdAt"] as? Date, rateSnapshotData: values["rateSnapshotData"] as? Data)
        }
        // Read only already-realized pending objects; never fire a receipt-bearing fault here.
        for case let object as ExpenseCD in context.insertedObjects.union(context.updatedObjects)
            where !object.isDeleted && !object.isFault {
            projections[object.objectID] = Self(id: object.objectID, record: TransactionHistoryRecord(
                title: object.title ?? "", note: object.note ?? "", type: object.type ?? "",
                category: object.tag ?? "", currency: object.originalCurrency,
                originalAmount: object.originalDecimal, occurredOn: object.occuredOn), createdAt: object.createdAt,
                rateSnapshotData: object.supportsCurrencyMetadata ? object.rateSnapshotData : nil)
        }
        for object in context.deletedObjects { projections.removeValue(forKey: object.objectID) }
        return projections.values.sorted {
            let leftDate = $0.record.occurredOn ?? .distantPast
            let rightDate = $1.record.occurredOn ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            let leftCreated = $0.createdAt ?? .distantPast
            let rightCreated = $1.createdAt ?? .distantPast
            if leftCreated != rightCreated { return leftCreated > rightCreated }
            return $0.id.uriRepresentation().absoluteString < $1.id.uriRepresentation().absoluteString
        }
    }

    fileprivate func row(baseCurrency: String, locale: Locale) -> HistoryRow {
        let original: String
        if let amount = record.originalAmount, !amount.isNaN {
            original = Money.format(amount, currency: record.currency, locale: locale)
        } else { original = "Invalid amount" }
        let convertedAmount = try? amount(in: baseCurrency)
        let converted: String? = record.currency == baseCurrency ? nil
            : convertedAmount.map { Money.format($0, currency: baseCurrency, locale: locale) } ?? "Conversion unavailable"
        return HistoryRow(id: id, record: record, originalLabel: original,
            convertedLabel: converted, baseAmount: convertedAmount,
            usesEstimatedConversion: isEstimated(in: baseCurrency))
    }

    /// Same-currency amounts, unknown types and failed conversions never use an estimate.
    func isEstimated(in baseCurrency: String) -> Bool {
        guard record.currency != baseCurrency,
              [TRANS_TYPE_EXPENSE, TRANS_TYPE_INCOME].contains(record.type),
              let amount = try? amount(in: baseCurrency), !amount.isNaN, amount >= 0,
              let data = rateSnapshotData,
              let snapshot = CurrencyRateSnapshot.cachedDecode(data) else { return false }
        return snapshot.isApproximate
    }

    /// Matches ExpenseCD.amount(in:) exactly, including per-transaction rounding.
    func amount(in baseCurrency: String) throws -> Decimal {
        guard let amount = record.originalAmount, !amount.isNaN, amount >= 0 else { throw MoneyError.invalidAmount }
        if record.currency == baseCurrency { return Money.rounded(amount, currency: baseCurrency) }
        guard let data = rateSnapshotData,
              let rates = CurrencyRateSnapshot.cachedDecode(data) else { throw MoneyError.missingRate }
        return Money.rounded(try Money.multiply(amount, rates.rate(from: record.currency, to: baseCurrency)), currency: baseCurrency)
    }
}

struct TransactionHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    var initialFilter = TransactionHistoryFilter()

    var body: some View {
        NavigationStack {
            TransactionHistoryView(initialFilter: initialFilter)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                    }
                }
        }
    }
}

struct TransactionHistoryView: View {
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var mutations: LedgerMutationService
    @AppStorage(CurrencySettings.key) private var baseCurrency = "RUB"
    @AppStorage(CategoryCatalog.storageKey) private var categoryData = Data()
    @State private var filter: TransactionHistoryFilter
    @State private var rows: [HistoryRow] = []
    @State private var projections: [HistoryLedgerProjection] = []
    @State private var allRows: [HistoryRow] = []
    @State private var totals = HistoryFilteredTotals()
    @State private var selection = Set<NSManagedObjectID>()
    @State private var editMode: EditMode = .inactive
    @State private var showFilters = false
    @State private var showDelete = false
    @State private var errorMessage: String?
    @State private var detail: HistoryDetail?
    @State private var isReloading = false
    @FocusState private var searchFocused: Bool
    @State private var displayTask: Task<Void, Never>?
    @State private var filterTask: Task<Void, Never>?
    @State private var displayGeneration = UUID()
    @State private var filterGeneration = UUID()
    @State private var preparingRows = false
    @State private var calendarAnchor = LedgerCalendarAnchor()
    @State private var formattingLocaleID = Locale.current.identifier

    init(initialFilter: TransactionHistoryFilter = TransactionHistoryFilter()) {
        // Drilldowns seed the filter once; users can freely change it after navigation.
        _filter = State(initialValue: initialFilter)
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                LabeledContent("Income", value: totalLabel(totals.income))
                LabeledContent("Expense", value: totalLabel(totals.expense))
                LabeledContent("Net Cash Flow", value: totalLabel(totals.netCashFlow))
            } header: { Text("Filtered Totals · \(baseCurrency)") } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if totals.income == nil || totals.expense == nil {
                        Text("Some transactions need an amount or exchange rate before totals are available.")
                    }
                    if totals.excludedUnknownTypes > 0 {
                        Text("\(totals.excludedUnknownTypes) transactions have an unknown type and are excluded.")
                    }
                    if totals.estimatedConversionCount > 0 {
                        Text("\(totals.estimatedConversionCount) transactions use estimated exchange rates from another date.")
                    }
                    DisclosureGroup("How totals work") {
                        Text("Cash flow is income minus expenses, not an account balance. Totals use saved exchange rates. Missing conversions make the affected total unavailable.")
                    }
                }
            }
            Section {
                Text("\(rows.count) matching transactions")
                    .font(.subheadline).foregroundStyle(.secondary)
                if filter.hasAdvancedFilters {
                    if let type = filter.type { LabeledContent("Type", value: type.capitalized) }
                    if let category = filter.category { LabeledContent("Category", value: getTransTagTitle(transTag: category)) }
                    if let start = filter.startDay { LabeledContent("From", value: start.formatted(date: .abbreviated, time: .omitted)) }
                    if let end = filter.endDay { LabeledContent("Through", value: end.formatted(date: .abbreviated, time: .omitted)) }
                    if let currency = filter.currency { LabeledContent("Original Currency", value: currency) }
                    if filter.minimumAmount != nil || filter.maximumAmount != nil {
                        LabeledContent("Original Amount", value: "\(filter.minimumAmount.map { NSDecimalNumber(decimal: $0).stringValue } ?? "0") – \(filter.maximumAmount.map { NSDecimalNumber(decimal: $0).stringValue } ?? "No maximum")")
                    }
                    Button("Clear Filters", systemImage: "xmark.circle") {
                        let search = filter.search
                        filter = TransactionHistoryFilter(search: search)
                    }
                }
            }
            if preparingRows {
                ProgressView("Loading transactions…")
            } else if rows.isEmpty {
                ContentUnavailableView("No Matching Transactions", systemImage: "magnifyingglass",
                    description: Text("Change your search or filters to see more history."))
            }
            ForEach(rows) { row in
                VStack(alignment: .leading) {
                    if editMode.isEditing {
                        HistoryTransactionRow(row: row)
                    } else {
                        Button { presentDetails(row.id) } label: { HistoryTransactionRow(row: row) }
                            .buttonStyle(.plain)
                    }
                }
                .tag(row.id)
            }
        }
        .environment(\.editMode, $editMode)
        .expenseScreenChrome(bottom: !editMode.isEditing && !mutations.hasUndo)
        .navigationTitle("History")
        .searchable(text: $filter.search, prompt: "Search titles and notes")
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        .searchFocused($searchFocused)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Filters", systemImage: filter.hasAdvancedFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") { searchFocused = false; showFilters = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(editMode.isEditing ? "Done" : "Select") {
                    searchFocused = false
                    editMode = editMode.isEditing ? .inactive : .active
                    selection.removeAll()
                }
            }
        }
        .expenseBottomBar { bottomActions }
        .sheet(isPresented: $showFilters) {
            HistoryFiltersView(filter: $filter).expenseSheetStyle(.editor)
        }
        .sheet(item: $detail) { item in
            HistoryDetailSheet(expense: item.expense).expenseSheetStyle(.editor)
        }
        .confirmationDialog("Delete \(selection.count) selected transactions?", isPresented: $showDelete, titleVisibility: .visible) {
            Button("Delete Transactions", role: .destructive) {
                perform { try mutations.delete(ids: selection, context: context) }
            }
        } message: { Text("You can undo recent changes while the app stays open.") }
        .alert("History", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .onAppear { reload() }
        .onDisappear {
            displayTask?.cancel()
            filterTask?.cancel()
            displayGeneration = UUID()
            filterGeneration = UUID()
        }
        .onChange(of: filter) { old, updated in applyFilters(debounce: old.search != updated.search) }
        .onChange(of: baseCurrency) { _, _ in rebuildDisplayRows() }
        .ledgerCalendarRefresh($calendarAnchor)
        .onChange(of: calendarAnchor) { _, _ in rebuildDisplayRows() }
        .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
            let identifier = Locale.current.identifier
            if formattingLocaleID != identifier {
                formattingLocaleID = identifier
                rebuildDisplayRows()
            }
        }
        .onChange(of: mutations.restoreGeneration) { _, _ in
            detail = nil
            selection.removeAll()
            reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange, object: context)) { notification in
            let changes = notification.userInfo ?? [:]
            let changedRows = [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey, NSRefreshedObjectsKey]
                .contains { key in
                    (changes[key] as? Set<NSManagedObject>)?.contains { $0.entity.name == "ExpenseCD" } == true
                }
            if changedRows || changes[NSInvalidatedAllObjectsKey] != nil { reload() }
            else if let detail, detail.expense.isDeleted || detail.expense.isFault { self.detail = nil }
        }
    }

    @ViewBuilder private var bottomActions: some View {
        if editMode.isEditing || mutations.hasUndo {
            VStack(spacing: 12) {
                if editMode.isEditing {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            selectionCount.fixedSize()
                            Spacer()
                            selectionButtons.fixedSize()
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            selectionCount
                            ViewThatFits(in: .horizontal) {
                                HStack { selectionButtons.fixedSize() }
                                VStack(alignment: .leading, spacing: 10) { selectionButtons }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                LedgerUndoBanner()
            }
            .padding()
        }
    }

    private var selectionCount: some View {
        Text("\(selection.count) selected").font(.subheadline)
    }

    @ViewBuilder private var selectionButtons: some View {
        Menu {
            ForEach(CategoryCatalog.choices(in: CategoryCatalog.decode(categoryData))) { category in
                Button(category.name, systemImage: category.symbol) {
                    perform { try mutations.recategorize(ids: selection, category: category.id, context: context) }
                }
            }
        } label: { Label("Category", systemImage: "tag") }
        .disabled(selection.isEmpty)
        Button("Delete", systemImage: "trash", role: .destructive) { showDelete = true }
            .disabled(selection.isEmpty)
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); selection.removeAll(); reload() }
        catch { errorMessage = error.localizedDescription }
    }

    private func reload() {
        guard !isReloading else { return }
        isReloading = true
        displayTask?.cancel()
        filterTask?.cancel()
        displayGeneration = UUID()
        filterGeneration = UUID()
        defer { isReloading = false }
        do {
            projections = try HistoryLedgerProjection.fetch(in: context)
            rebuildDisplayRows()
            let liveIDs = Set(projections.map(\.id))
            if let detail, !liveIDs.contains(detail.id) || detail.expense.isDeleted || detail.expense.isFault { self.detail = nil }
        } catch {
            preparingRows = false
            errorMessage = error.localizedDescription
        }
    }

    private func rebuildDisplayRows() {
        displayTask?.cancel()
        filterTask?.cancel()
        let generation = UUID()
        displayGeneration = generation
        filterGeneration = UUID()
        let snapshot = projections
        let currency = baseCurrency
        let locale = Locale.current
        // Do not show old-currency amounts under the newly selected currency.
        preparingRows = true
        allRows = []
        rows = []
        totals = HistoryFilteredTotals(income: nil, expense: nil, netCashFlow: nil)
        let work = Task.detached(priority: .userInitiated) { () -> [HistoryRow]? in
            var result: [HistoryRow] = []
            result.reserveCapacity(snapshot.count)
            for item in snapshot {
                guard !Task.isCancelled else { return nil }
                result.append(item.row(baseCurrency: currency, locale: locale))
            }
            return result
        }
        displayTask = Task {
            let result = await withTaskCancellationHandler {
                await work.value
            } onCancel: { work.cancel() }
            guard !Task.isCancelled, displayGeneration == generation, let result else { return }
            allRows = result
            applyFilters()
        }
    }

    private func applyFilters(debounce: Bool = false) {
        filterTask?.cancel()
        let generation = UUID()
        filterGeneration = generation
        let snapshot = allRows
        let requestedFilter = filter
        let calendar = calendarAnchor.calendar
        filterTask = Task {
            if debounce {
                do { try await Task.sleep(for: .milliseconds(150)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            let work = Task.detached(priority: .userInitiated) { () -> ([HistoryRow], HistoryFilteredTotals)? in
                var matches: [HistoryRow] = []
                for row in snapshot {
                    guard !Task.isCancelled else { return nil }
                    if requestedFilter.matches(row.record, calendar: calendar) { matches.append(row) }
                }
                let totals = HistoryFilteredTotals.compute(matches.map { (type: $0.record.type, amount: $0.baseAmount) },
                    estimatedCount: matches.filter(\.usesEstimatedConversion).count)
                return (matches, totals)
            }
            let result = await withTaskCancellationHandler {
                await work.value
            } onCancel: { work.cancel() }
            guard !Task.isCancelled, filterGeneration == generation, let result else { return }
            rows = result.0
            totals = result.1
            preparingRows = false
            selection.formIntersection(Set(rows.map(\.id)))
        }
    }

    private func totalLabel(_ value: Decimal?) -> String {
        value.map { Money.format($0, currency: baseCurrency) } ?? "Unavailable"
    }

    private func presentDetails(_ id: NSManagedObjectID) {
        searchFocused = false
        let request = NSFetchRequest<ExpenseCD>(entityName: "ExpenseCD")
        request.predicate = NSPredicate(format: "SELF == %@", id)
        request.returnsObjectsAsFaults = false
        do {
            guard let expense = try context.fetch(request).first, !expense.isDeleted, !expense.isFault else {
                reload(); return
            }
            detail = HistoryDetail(id: id, expense: expense)
        } catch { errorMessage = error.localizedDescription }
    }
}

/// App-owned Undo remains reachable after dismissing a transaction detail sheet.
struct LedgerUndoBanner: View {
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var mutations: LedgerMutationService
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if mutations.hasUndo {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(mutations.undoDescription ?? "Transactions updated").font(.subheadline)
                        Spacer()
                        Button("Undo", systemImage: "arrow.uturn.backward") {
                            do { try mutations.undo(context: context) }
                            catch { errorMessage = error.localizedDescription }
                        }
                    }
                }
            }
        }
        .alert("Unable to Undo", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
}

private struct HistoryDetail: Identifiable {
    let id: NSManagedObjectID
    let expense: ExpenseCD
}

private struct HistoryDetailSheet: View {
    @ObservedObject var expense: ExpenseCD
    var body: some View {
        Group {
            if !expense.isDeleted && !expense.isFault { ExpenseDetailedView(expenseObj: expense) }
            else { ContentUnavailableView("Transaction Unavailable", systemImage: "tray") }
        }
    }
}

private struct HistoryTransactionRow: View {
    let row: HistoryRow
    @AppStorage(CategoryCatalog.storageKey) private var categoryData = Data()
    private var category: ExpenseCategory? {
        CategoryCatalog.decode(categoryData).first { $0.id == row.record.category }
    }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                categoryIcon
                transactionDescription.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 4)
                transactionAmounts(alignment: .trailing).fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    categoryIcon
                    transactionDescription
                }
                transactionAmounts(alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
    }

    private var categoryIcon: some View {
        Image(systemName: category?.symbol ?? transactionSymbol(for: row.record.category))
            .font(.title3).foregroundStyle(.tint).frame(width: 30)
            .accessibilityHidden(true)
    }

    private var transactionDescription: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.record.title.isEmpty ? "Untitled Transaction" : row.record.title).font(.headline)
            Text(category?.name ?? getTransTagTitle(transTag: row.record.category)).font(.caption).foregroundStyle(.secondary)
            if let date = row.record.occurredOn { Text(date, format: .dateTime.day().month().year()).font(.caption).foregroundStyle(.secondary) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func transactionAmounts(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Text("\(row.record.type == TRANS_TYPE_INCOME ? "+" : row.record.type == TRANS_TYPE_EXPENSE ? "−" : "")\(row.originalLabel)")
                .font(.subheadline.weight(.semibold))
            Text(row.record.type.capitalized).font(.caption).foregroundStyle(.secondary)
            if let converted = row.convertedLabel { Text(converted).font(.caption).foregroundStyle(.secondary) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct HistoryFiltersView: View {
    private enum Period: String, CaseIterable, Identifiable {
        case all = "All time", thisMonth = "This month", lastMonth = "Last month", custom = "Custom"
        var id: Self { self }
    }
    private enum Field: Hashable { case minimum, maximum }

    @Environment(\.dismiss) private var dismiss
    @Binding var filter: TransactionHistoryFilter
    @AppStorage(CategoryCatalog.storageKey) private var categoryData = Data()
    @State private var draft: TransactionHistoryFilter
    @State private var minimum: String
    @State private var maximum: String
    @State private var period: Period
    @State private var hasStart: Bool
    @State private var hasEnd: Bool
    @State private var start: Date
    @State private var end: Date
    @State private var showMore: Bool
    @State private var error: String?
    @FocusState private var focusedField: Field?

    private var categories: [ExpenseCategory] {
        let catalog = CategoryCatalog.decode(categoryData)
        guard let selected = draft.category, !catalog.contains(where: { $0.id == selected }),
              let preserved = CategoryCatalog.choices(in: catalog, preserving: selected).first(where: { $0.id == selected }) else { return catalog }
        return catalog + [preserved]
    }

    init(filter: Binding<TransactionHistoryFilter>) {
        _filter = filter
        let value = filter.wrappedValue
        _draft = State(initialValue: value)
        _minimum = State(initialValue: value.minimumAmount.map { NSDecimalNumber(decimal: $0).stringValue } ?? "")
        _maximum = State(initialValue: value.maximumAmount.map { NSDecimalNumber(decimal: $0).stringValue } ?? "")
        _period = State(initialValue: Self.period(for: value))
        _hasStart = State(initialValue: value.startDay != nil)
        _hasEnd = State(initialValue: value.endDay != nil)
        _start = State(initialValue: value.startDay ?? Date())
        _end = State(initialValue: value.endDay ?? Date())
        _showMore = State(initialValue: value.currency != nil || value.minimumAmount != nil || value.maximumAmount != nil)
    }

    var body: some View {
        NavigationStack {
            ExpenseForm {
                Section("Dates") {
                    ExpenseValueRow(title: "Period") {
                        Picker("Period", selection: $period) {
                            ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.menu)
                        .simultaneousGesture(TapGesture().onEnded { focusedField = nil })
                    }
                    if period == .custom {
                        Toggle("Start date", isOn: $hasStart)
                        if hasStart {
                            ExpenseValueRow(title: "From") {
                                DatePicker("From", selection: $start, displayedComponents: .date)
                                    .labelsHidden().datePickerStyle(.compact)
                                    .simultaneousGesture(TapGesture().onEnded { focusedField = nil })
                            }
                        }
                        Toggle("End date", isOn: $hasEnd)
                        if hasEnd {
                            ExpenseValueRow(title: "Through") {
                                DatePicker("Through", selection: $end, displayedComponents: .date)
                                    .labelsHidden().datePickerStyle(.compact)
                                    .simultaneousGesture(TapGesture().onEnded { focusedField = nil })
                            }
                        }
                    }
                }
                Section("Transaction") {
                    ExpenseValueRow(title: "Type") {
                        Picker("Type", selection: $draft.type) {
                            Text("All Types").tag(String?.none)
                            Text("Income").tag(Optional(TRANS_TYPE_INCOME))
                            Text("Expense").tag(Optional(TRANS_TYPE_EXPENSE))
                        }
                        .labelsHidden().pickerStyle(.menu)
                        .simultaneousGesture(TapGesture().onEnded { focusedField = nil })
                    }
                    ExpenseValueRow(title: "Category") {
                        Picker("Category", selection: $draft.category) {
                            Text("All Categories").tag(String?.none)
                            ForEach(categories) { category in
                                Label(category.name + (category.isArchived ? " (Archived)" : ""), systemImage: category.symbol).tag(Optional(category.id))
                            }
                        }
                        .labelsHidden().pickerStyle(.menu)
                        .simultaneousGesture(TapGesture().onEnded { focusedField = nil })
                    }
                }
                Section {
                    DisclosureGroup("More filters", isExpanded: $showMore) {
                        ExpenseValueRow(title: "Currency") {
                            Picker("Currency", selection: $draft.currency) {
                                Text("All Currencies").tag(String?.none)
                                ForEach(CurrencySettings.codes, id: \.self) { Text(CurrencySettings.label($0)).tag(Optional($0)) }
                            }
                            .labelsHidden().pickerStyle(.menu)
                            .simultaneousGesture(TapGesture().onEnded { focusedField = nil })
                        }
                        ExpenseField(title: "Minimum Amount") {
                            TextField("Minimum amount", text: $minimum)
                                .keyboardType(.decimalPad).focused($focusedField, equals: .minimum)
                        }
                        ExpenseField(title: "Maximum Amount") {
                            TextField("Maximum amount", text: $maximum)
                                .keyboardType(.decimalPad).focused($focusedField, equals: .maximum)
                        }
                        Text("Amounts use each transaction’s original currency. Choose a currency to compare like-for-like.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .scrollDismissesKeyboard(.interactively)
            .expenseScreenChrome()
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { focusedField = nil; dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Apply") { apply() } }
            }
            .onChange(of: period) { _, selected in
                focusedField = nil
                if selected == .custom, !hasStart, !hasEnd { hasStart = true; hasEnd = true }
            }
            .onChange(of: showMore) { _, expanded in if !expanded { focusedField = nil } }
        }
    }

    private static func period(for filter: TransactionHistoryFilter) -> Period {
        guard filter.startDay != nil || filter.endDay != nil else { return .all }
        let calendar = Calendar.current
        for (period, offset) in [(Period.thisMonth, 0), (.lastMonth, -1)] {
            guard let date = calendar.date(byAdding: .month, value: offset, to: Date()) else { continue }
            var month = TransactionHistoryFilter()
            month.selectMonth(containing: date, calendar: calendar)
            if filter.startDay.map({ calendar.startOfDay(for: $0) }) == month.startDay,
               filter.endDay.map({ calendar.startOfDay(for: $0) }) == month.endDay { return period }
        }
        return .custom
    }

    private func apply() {
        focusedField = nil
        do {
            draft.minimumAmount = try TransactionHistoryFilter.amountBound(minimum)
            draft.maximumAmount = try TransactionHistoryFilter.amountBound(maximum)
            switch period {
            case .all:
                draft.startDay = nil
                draft.endDay = nil
            case .thisMonth: draft.selectMonth(containing: Date())
            case .lastMonth:
                if let date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) { draft.selectMonth(containing: date) }
            case .custom:
                draft.startDay = hasStart ? start : nil
                draft.endDay = hasEnd ? end : nil
            }
            try draft.validate()
            filter = draft
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
