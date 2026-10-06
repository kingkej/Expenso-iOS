import SwiftUI
import CoreData

private struct InsightsHistoryDestination: Identifiable {
    let id = UUID()
    let filter: TransactionHistoryFilter
}

private struct InsightsTypesDestination: Identifiable {
    let id: String
    let range: InsightsRange
}

struct InsightsView: View {
    let initialPeriod: InsightsPeriod
    let initialKind: InsightsKind
    var body: some View {
        NavigationStack { InsightsContentView(initialPeriod: initialPeriod, initialKind: initialKind) }
    }
    init(initialPeriod: InsightsPeriod = .thisMonth, initialKind: InsightsKind = .expense) {
        self.initialPeriod = initialPeriod
        self.initialKind = initialKind
    }
}

/// Shared by the Insights tab and the existing Dashboard summary sheet.
struct InsightsContentView: View {
    @Environment(\.motionReflectionsAllowed) private var allowsMotion
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var mutations: LedgerMutationService
    @AppStorage(CurrencySettings.key) private var currency = "RUB"
    @AppStorage(AmountDisplaySettings.compactKey) private var compactAmounts = false
    @AppStorage(CategoryCatalog.storageKey) private var categoryData = Data()
    @State private var period: InsightsPeriod
    @State private var kind: InsightsKind
    @State private var projections: [HistoryLedgerProjection] = []
    @State private var report: InsightsReport?
    @State private var selectedDate: Date?
    @State private var selectedCategory: String?
    @State private var errorMessage: String?
    @State private var isReloading = false
    @State private var reportTask: Task<Void, Never>?
    @State private var reportGeneration = UUID()
    @State private var calendarAnchor = LedgerCalendarAnchor()
    @State private var historyDestination: InsightsHistoryDestination?
    @State private var typesDestination: InsightsTypesDestination?
    private var catalog: [ExpenseCategory] { CategoryCatalog.decode(categoryData) }

    init(initialPeriod: InsightsPeriod = .thisMonth, initialKind: InsightsKind = .expense) {
        // Dashboard routing seeds this screen once; subsequent choices belong to this screen.
        _period = State(initialValue: initialPeriod)
        _kind = State(initialValue: initialKind)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Picker("Transaction Type", selection: $kind) {
                    ForEach(InsightsKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if let report {
                    overview(report)
                    if report.total != nil {
                        if report.count == 0 {
                            ContentUnavailableView("No \(kind.title) in This Period", systemImage: "chart.bar",
                                description: Text("Choose another period or add a transaction."))
                        } else {
                            trend(report)
                            categoryBreakdown(report)
                            statistics(report)
                        }
                    } else {
                        repair(report)
                    }
                    disclosure(report)
                } else if let errorMessage {
                    ContentUnavailableView("Insights Unavailable", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                    Button("Retry", systemImage: "arrow.clockwise") { reload() }
                } else { ProgressView("Loading insights…") }
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .environment(\.motionReflectionsAllowed, allowsMotion && historyDestination == nil && typesDestination == nil)
        .expenseScreenChrome()
        .navigationTitle("Insights")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Period", selection: $period) {
                        ForEach(InsightsPeriod.allCases) { Text($0.title).tag($0) }
                    }
                } label: { Label(period.title, systemImage: "calendar") }
            }
        }
        .onAppear { reload() }
        .onDisappear {
            reportTask?.cancel()
            reportGeneration = UUID()
        }
        .sheet(item: $historyDestination) { destination in
            TransactionHistorySheet(initialFilter: destination.filter).expenseSheetStyle(.editor)
        }
        .sheet(item: $typesDestination) { destination in
            InsightsSpendingTypesSheet(category: destination.id == "all" ? "All Categories" : categoryName(destination.id),
                range: destination.range, calendar: calendarAnchor.calendar, currency: currency,
                projections: projections.filter {
                    guard $0.record.type == TRANS_TYPE_EXPENSE,
                          destination.id == "all" || $0.record.category == destination.id,
                          let date = $0.record.occurredOn else { return false }
                    return date >= destination.range.start && date < destination.range.endExclusive
                }).expenseSheetStyle(.editor)
        }
        .ledgerCalendarRefresh($calendarAnchor)
        .onChange(of: calendarAnchor) { _, _ in recompute() }
        .onChange(of: period) { _, _ in recompute() }
        .onChange(of: kind) { _, _ in recompute() }
        .onChange(of: currency) { _, _ in rebuildTransactions() }
        .onChange(of: mutations.restoreGeneration) { _, _ in
            historyDestination = nil
            typesDestination = nil
            reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange, object: context)) { notification in
            let changes = notification.userInfo ?? [:]
            let changed = [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey, NSRefreshedObjectsKey].contains { key in
                (changes[key] as? Set<NSManagedObject>)?.contains { $0.entity.name == "ExpenseCD" } == true
            }
            if changed || changes[NSInvalidatedAllObjectsKey] != nil { reload() }
        }
    }

    private func overview(_ report: InsightsReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(kind.title, systemImage: kind == .expense ? "arrow.up.right" : "arrow.down.left").font(.headline)
                Spacer()
                Text(currency).font(.subheadline).foregroundStyle(.secondary)
            }
            summaryAmount(report.total)
                .font(.largeTitle.weight(.semibold)).minimumScaleFactor(0.7)
            Text(rangeLabel(report.range)).font(.subheadline).foregroundStyle(.secondary)
            if report.estimatedConversionCount > 0 {
                Text("\(report.estimatedConversionCount) transactions use estimated exchange rates from another date.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let previous = report.previousRange {
                Divider()
                Text("Compared with \(rangeLabel(previous))").font(.caption).foregroundStyle(.secondary)
                if report.previousEstimatedConversionCount > 0 {
                    Text("The comparison includes \(report.previousEstimatedConversionCount) estimated currency conversions.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let previousTotal = report.previousTotal {
                    LabeledContent("Previous \(kind.title)") { summaryAmount(previousTotal) }
                    if let change = report.change {
                        comparison(change: change, percent: report.changePercent)
                    }
                } else { Text("Previous total unavailable: \(report.previousInvalidAmountCount) transactions need valid amounts or saved rates.").font(.caption).foregroundStyle(.secondary) }
            }
            Button {
                showHistory(report.range)
            } label: { Label("View \(report.count) Transactions", systemImage: "list.bullet.rectangle") }
            if kind == .expense {
                Button {
                    typesDestination = InsightsTypesDestination(id: "all", range: report.range)
                } label: { Label("Spending Types", systemImage: "sparkles") }
            }
        }
        .insightsCard()
    }

    private func comparison(change: Decimal, percent: Decimal?) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                changeDirection(change).fixedSize()
                Spacer()
                comparisonValues(change: change, percent: percent).fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                changeDirection(change)
                comparisonValues(change: change, percent: percent)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
    }

    private func changeDirection(_ change: Decimal) -> some View {
        Label(change > 0 ? "Higher" : change < 0 ? "Lower" : "Unchanged", systemImage: change > 0 ? "arrow.up" : change < 0 ? "arrow.down" : "equal")
    }

    @ViewBuilder private func comparisonValues(change: Decimal, percent: Decimal?) -> some View {
        Text("\(change > 0 ? "+" : "")\(Money.display(change, currency: currency, compact: compactAmounts))")
            .monospacedDigit()
            .accessibilityLabel("\(change > 0 ? "+" : "")\(Money.format(change, currency: currency))")
        if let percent { Text("(\(decimal(percent))%)") }
    }

    private func trend(_ report: InsightsReport) -> some View {
        let selected = selectedBucket(report)
        let displayed = selected ?? report.peakBucket ?? report.buckets.first(where: { $0.count > 0 }) ?? report.buckets.first
        return VStack(alignment: .leading, spacing: 16) {
            Text("\(kind.title) Over Time").font(.headline)
            if let bucket = displayed {
                VStack(alignment: .leading, spacing: 6) {
                    Text(selected == nil ? peakTitle(bucket, report: report) : (bucket.range(calendar: calendarAnchor.calendar).dayCount == 1 ? "Selected day" : "Selected period"))
                        .font(.subheadline).foregroundStyle(.secondary)
                    // A selected column always reveals the exact amount.
                    Text(Money.display(bucket.amount, currency: currency, compact: compactAmounts && selected == nil))
                        .font(.title2.weight(.semibold)).monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(Money.format(bucket.amount, currency: currency))
                    Text(rangeLabel(bucket.range(calendar: calendarAnchor.calendar)))
                        .font(.subheadline)
                    if let percent = report.sharePercent(for: bucket), bucket.amount > 0 {
                        Text("\(decimal(percent))% of this period’s \(kind == .expense ? "spending" : "income")")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if bucket.amount == 0 {
                        Text(kind == .expense ? "No spending recorded" : "No income recorded")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            InsightsTrendChart(buckets: report.buckets, currency: currency, title: kind.title,
                calendar: calendarAnchor.calendar, selectedDate: $selectedDate)
            Text("Tap a column to see its total.").font(.caption).foregroundStyle(.secondary)
            if let bucket = displayed {
                if bucket.count > 0 {
                    Button {
                        showHistory(bucket.range(calendar: calendarAnchor.calendar))
                    } label: {
                        Label(bucket.count == 1 ? "View Transaction" : "View \(bucket.count) Transactions", systemImage: "list.bullet.rectangle")
                    }
                    .accessibilityHint("Shows transactions for \(rangeLabel(bucket.range(calendar: calendarAnchor.calendar)))")
                } else {
                    Text("No transactions in this period.").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }.insightsCard()
    }

    private func peakTitle(_ bucket: InsightsBucket, report: InsightsReport) -> String {
        guard report.peakBucket != nil else { return "No \(kind == .expense ? "spending" : "income") in this period" }
        let unit = bucket.range(calendar: calendarAnchor.calendar).dayCount == 1 ? "day" : "period"
        return kind == .expense ? "Highest-spending \(unit)" : "Highest-income \(unit)"
    }

    private func categoryBreakdown(_ report: InsightsReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Where Your \(kind == .expense ? "Money Goes" : "Income Comes From")").font(.headline)
            if !report.categories.isEmpty {
                InsightsCategoryChart(categories: Array(report.categories.prefix(8)), catalog: catalog, currency: currency, selectedID: $selectedCategory)
                if report.categories.count > 8 { Text("Chart shows the top 8; the list includes every category.").font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(report.categories, id: \.id) { category in
                VStack(alignment: .leading, spacing: 8) {
                Button {
                    showHistory(report.range, category: category.id)
                } label: {
                    categorySummary(category)
                    .padding(.vertical, 6)
                    .padding(.horizontal, selectedCategory == category.id ? 8 : 0)
                    .background(selectedCategory == category.id ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).accessibilityElement(children: .combine)
                if kind == .expense {
                    Button {
                        typesDestination = InsightsTypesDestination(id: category.id, range: report.range)
                    } label: {
                        Label("Spending Types in \(categoryName(category.id))", systemImage: "sparkles")
                            .font(.subheadline)
                    }
                }
                Divider()
                }
            }
        }.insightsCard()
    }

    private func categorySummary(_ category: InsightsCategoryTotal) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                categoryIcon(category.id)
                categoryDescription(category).fixedSize(horizontal: true, vertical: false)
                Spacer()
                categoryAmounts(category, alignment: .trailing).fixedSize(horizontal: true, vertical: false)
                categoryChevron
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    categoryIcon(category.id)
                    categoryDescription(category)
                    Spacer(minLength: 0)
                    categoryChevron
                }
                categoryAmounts(category, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func categoryIcon(_ id: String) -> some View {
        Image(systemName: catalog.first { $0.id == id }?.symbol ?? "tag.fill")
            .frame(width: 28).foregroundStyle(.tint).accessibilityHidden(true)
    }

    private var categoryChevron: some View {
        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
    }

    private func categoryDescription(_ category: InsightsCategoryTotal) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(categoryName(category.id)).font(.subheadline.weight(.medium))
            Text("\(category.count) transactions").font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func categoryAmounts(_ category: InsightsCategoryTotal, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            summaryAmount(category.amount).font(.subheadline.weight(.semibold))
            Text("\(decimal((try? Money.multiply(category.share, 100)) ?? 0))%")
                .font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func statistics(_ report: InsightsReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("At a Glance").font(.headline)
            LabeledContent("Daily Average") { summaryAmount(report.averagePerDay) }
            LabeledContent("Average Transaction") { summaryAmount(report.averageTransaction) }
            LabeledContent("Transaction Count", value: String(report.count))
            if kind == .expense, let days = report.daysWithoutSpending { LabeledContent("Days Without Spending", value: String(days)) }
            if let largest = report.largest, let amount = largest.amount {
                Divider()
                Text("Largest \(kind == .expense ? "Expense" : "Income")").font(.subheadline.weight(.semibold))
                Text(largest.title.isEmpty ? "Untitled Transaction" : largest.title).lineLimit(3)
                Text(Money.format(amount, currency: currency)).font(.title3.weight(.semibold))
                if let date = largest.date { Text(date, format: .dateTime.day().month().year()).font(.caption).foregroundStyle(.secondary) }
                Button {
                    showHistory(report.range, category: largest.category)
                } label: { Label("View Transactions in \(categoryName(largest.category))", systemImage: "list.bullet") }
            }
        }.insightsCard()
    }

    private func repair(_ report: InsightsReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Some transactions need attention", systemImage: "exclamationmark.triangle").font(.headline)
            Text("\(report.invalidAmountCount) transactions need an amount or exchange rate before this total is available.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button {
                showHistory(report.range)
            } label: { Label("Review Transactions", systemImage: "list.bullet.rectangle") }
        }.insightsCard()
    }

    private func disclosure(_ report: InsightsReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if report.excludedUnknownTypeCount + report.excludedUndatedCount > 0 {
                Text("\(report.excludedUnknownTypeCount + report.excludedUndatedCount) transactions are excluded because their date or type is missing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("How totals work") {
                VStack(alignment: .leading, spacing: 6) {
                    if compactAmounts {
                        Text("Summaries are rounded. Select a chart column or open transactions for full amounts.")
                    }
                    Text("Amounts use each transaction’s saved rate in \(currency). Original amounts stay unchanged. Cash flow is income minus expenses, not an account balance.")
                    Text("Future days are excluded. Daily averages include every calendar day in the selected period. This month and this year compare matching elapsed days; completed months compare whole months.")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .font(.subheadline)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func selectedBucket(_ report: InsightsReport) -> InsightsBucket? {
        guard let selectedDate else { return nil }
        return report.buckets.first { selectedDate >= $0.id && selectedDate < $0.endExclusive }
    }

    private func showHistory(_ range: InsightsRange, category: String? = nil) {
        historyDestination = InsightsHistoryDestination(filter:
            range.historyFilter(kind: kind, category: category, calendar: calendarAnchor.calendar))
    }

    private func rangeLabel(_ range: InsightsRange) -> String {
        range.formatted(calendar: calendarAnchor.calendar)
    }

    private func summaryAmount(_ amount: Decimal?) -> some View {
        Text(amount.map { Money.display($0, currency: currency, compact: compactAmounts) } ?? "Unavailable")
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(amount.map { Money.format($0, currency: currency) } ?? "Unavailable")
    }

    private func categoryName(_ id: String) -> String { catalog.first { $0.id == id }?.name ?? (id.isEmpty ? "Uncategorized" : id) }
    private func decimal(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? Money.string(amount)
    }

    private func reload() {
        guard !isReloading else { return }
        isReloading = true
        reportTask?.cancel()
        reportGeneration = UUID()
        defer { isReloading = false }
        do { projections = try HistoryLedgerProjection.fetch(in: context); rebuildTransactions() }
        catch { report = nil; errorMessage = error.localizedDescription }
    }

    private func rebuildTransactions() { recompute() }

    private func recompute() {
        reportTask?.cancel()
        let generation = UUID()
        reportGeneration = generation
        let snapshot = projections
        let requestedCurrency = currency
        let requestedPeriod = period
        let requestedKind = kind
        let day = calendarAnchor.day
        let calendar = calendarAnchor.calendar
        selectedDate = nil
        selectedCategory = nil
        report = nil
        errorMessage = nil
        let work = Task.detached(priority: .userInitiated) { () -> (report: InsightsReport?, error: String?) in
            do {
                var transactions: [InsightsTransaction] = []
                transactions.reserveCapacity(snapshot.count)
                for row in snapshot {
                    try Task.checkCancellation()
                    transactions.append(InsightsTransaction(id: row.id.uriRepresentation().absoluteString, title: row.record.title,
                        type: row.record.type, category: row.record.category, date: row.record.occurredOn,
                        amount: try? row.amount(in: requestedCurrency),
                        usesEstimatedConversion: row.isEstimated(in: requestedCurrency)))
                }
                let report = try InsightsAnalytics.report(transactions, period: requestedPeriod, kind: requestedKind,
                    now: day, calendar: calendar)
                try Task.checkCancellation()
                return (report, nil)
            } catch is CancellationError { return (nil, nil) }
            catch { return (nil, error.localizedDescription) }
        }
        reportTask = Task {
            let result = await withTaskCancellationHandler {
                await work.value
            } onCancel: { work.cancel() }
            guard !Task.isCancelled, reportGeneration == generation else { return }
            report = result.report
            errorMessage = result.error
        }
    }

}

private struct InsightsTypeGroup: Identifiable {
    let id: String
    let label: String
    var amount: Decimal? = 0
    var rows: [HistoryLedgerProjection] = []
}

/// Classification supplies labels only. Every amount comes from the local saved ledger.
private struct InsightsSpendingTypesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = SpendingClassificationStore.shared
    @State private var showSettings = false
    let category: String
    let range: InsightsRange
    let calendar: Calendar
    let currency: String
    let projections: [HistoryLedgerProjection]

    private var groups: [InsightsTypeGroup] {
        var result: [String: InsightsTypeGroup] = [:]
        for row in projections {
            let label = store.label(for: row)
            let key = label.map { "label.\($0)" } ?? "unclassified"
            var group = result[key] ?? InsightsTypeGroup(id: key, label: label ?? "Unclassified")
            group.rows.append(row)
            if let running = group.amount {
                if let amount = try? row.amount(in: currency) { group.amount = try? Money.add(running, amount) }
                else { group.amount = nil }
            }
            result[key] = group
        }
        return result.values.sorted {
            if ($0.amount == nil) != ($1.amount == nil) { return $0.amount != nil }
            if let lhs = $0.amount, let rhs = $1.amount, lhs != rhs { return lhs > rhs }
            return $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Category", value: category)
                    Text(range.formatted(calendar: calendar)).foregroundStyle(.secondary)
                    Text("Suggested types · Totals in \(currency)")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !store.enabled {
                        Label("Automatic suggestions are off. Saved types remain available.", systemImage: "sparkles")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("Manage Spending Types", systemImage: "slider.horizontal.3") { showSettings = true }
                }
                .expenseFormSectionSurface()
                if projections.isEmpty {
                    Section { Text("No expense transactions in this category and period.").foregroundStyle(.secondary) }
                        .expenseFormSectionSurface()
                }
                ForEach(groups) { group in
                    Section {
                        LabeledContent("\(group.rows.count) transactions") {
                            Text(group.amount.map { Money.format($0, currency: currency) } ?? "Unavailable")
                                .monospacedDigit().fontWeight(.semibold)
                        }
                        if group.amount == nil {
                            Text("A transaction has an invalid amount or lacks a saved conversion. No partial total is shown.")
                                .font(.footnote).foregroundStyle(.red)
                        }
                        ForEach(group.rows, id: \.id) { row in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(row.record.title.isEmpty ? "Untitled Transaction" : row.record.title)
                                HStack(alignment: .firstTextBaseline) {
                                    if let date = row.record.occurredOn { Text(date, format: .dateTime.day().month().year()) }
                                    Spacer()
                                    Text((try? row.amount(in: currency)).map { Money.format($0, currency: currency) } ?? "Conversion unavailable")
                                        .monospacedDigit()
                                }.font(.caption).foregroundStyle(.secondary)
                            }.accessibilityElement(children: .combine)
                        }
                    } header: { Text(group.label) }
                    .expenseFormSectionSurface()
                }
                Section {
                    DisclosureGroup("About spending types") {
                        Text("AI types are suggestions and can be corrected in Spending Types settings. Unclassified includes missing suggestions and expenses you left unclassified. Totals are calculated from your transactions, not by AI. Types stay on this device and are not included in backups.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .expenseFormSectionSurface()
            }
            .expenseScreenChrome()
            .navigationTitle("Spending Types")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                }
            }
            .sheet(isPresented: $showSettings) { ClassificationSettingsView().expenseSheetStyle(.editor) }
        }
    }
}

private extension View {
    func insightsCard() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .expenseSummarySurface(cornerRadius: 22)
    }
}
