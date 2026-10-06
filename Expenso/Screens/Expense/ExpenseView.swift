//
//  ExpenseView.swift
//  Expenso
//
//  Created by Sameer Nawaz on 31/01/21.
//

import SwiftUI
import CoreData
import UIKit

/// A coherent calendar snapshot; equal snapshots do not invalidate navigation or fetches.
struct LedgerCalendarAnchor: Equatable {
    let day: Date
    let calendar: Calendar

    init(now: Date = Date(), calendar: Calendar = .current) {
        self.calendar = calendar
        day = calendar.startOfDay(for: now)
    }
}

private struct LedgerCalendarRefresh: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Binding var anchor: LedgerCalendarAnchor

    func body(content: Content) -> some View {
        content
            .onAppear { refresh() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in refresh() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in refresh() }
    }

    private func refresh() {
        let current = LedgerCalendarAnchor()
        if anchor != current { anchor = current }
    }
}

extension View {
    func ledgerCalendarRefresh(_ anchor: Binding<LedgerCalendarAnchor>) -> some View {
        modifier(LedgerCalendarRefresh(anchor: anchor))
    }
}

/// Dashboard cards, rows, and Insights use inclusive local calendar days.
struct ExpenseCalendarWindow: Equatable {
    let start: Date?
    let endExclusive: Date
    let today: Date
    let calendar: Calendar

    init(filter: ExpenseCDFilterTime, now: Date = Date(), calendar: Calendar = .current) {
        self.calendar = calendar
        today = calendar.startOfDay(for: now)
        endExclusive = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        switch filter {
        case .all: start = nil
        case .week: start = calendar.date(byAdding: .day, value: -6, to: today)
        case .month: start = calendar.date(byAdding: .day, value: -29, to: today)
        }
    }

    var predicate: NSPredicate {
        if let start { return NSPredicate(format: "occuredOn >= %@ AND occuredOn < %@", start as NSDate, endExclusive as NSDate) }
        return NSPredicate(format: "occuredOn != nil AND occuredOn < %@", endExclusive as NSDate)
    }

    var label: String {
        let last = today.formatted(date: .abbreviated, time: .omitted)
        if let start { return "\(start.formatted(date: .abbreviated, time: .omitted)) – \(last)" }
        return "Through \(last)"
    }

    func historyFilter(type: String? = nil, category: String? = nil) -> TransactionHistoryFilter {
        TransactionHistoryFilter(type: type, category: category, startDay: start, endDay: today)
    }
}

/// A stable presentation host keeps sheets alive when a transaction row disappears.
enum TransactionSheet: Identifiable {
    case details(ExpenseCD), summary(Bool), category(String), history

    var id: String {
        switch self {
        case .details(let expense): return "details-\(expense.objectID.uriRepresentation().absoluteString)"
        case .summary(let income): return "summary-\(income)"
        case .category(let tag): return "category-\(tag)"
        case .history: return "history"
        }
    }
}

struct TransactionSheetView: View {
    let destination: TransactionSheet
    let filter: ExpenseCDFilterTime
    var window: ExpenseCalendarWindow? = nil

    var body: some View {
        Group {
            switch destination {
            case .details(let expense): ExpenseDetailedView(expenseObj: expense)
            case .summary(let income): TransactionHistorySheet(initialFilter: resolvedWindow.historyFilter(type: income ? TRANS_TYPE_INCOME : TRANS_TYPE_EXPENSE))
            case .category(let tag): TransactionHistorySheet(initialFilter: resolvedWindow.historyFilter(category: tag))
            case .history: TransactionHistorySheet(initialFilter: resolvedWindow.historyFilter())
            }
        }
        .expenseSheetStyle(.editor)
    }

    private var resolvedWindow: ExpenseCalendarWindow { window ?? ExpenseCalendarWindow(filter: filter) }
}

/// The five-row preview is independent of financial totals, which always use the full period.
enum DashboardSummary {
    static func compute(_ projections: [HistoryLedgerProjection], window: ExpenseCalendarWindow,
                        currency: String) -> HistoryFilteredTotals {
        let period = window.historyFilter()
        let matches = projections.filter { period.matches($0.record, calendar: window.calendar) }
        return HistoryFilteredTotals.compute(matches.map { ($0.record.type, try? $0.amount(in: currency)) },
            estimatedCount: matches.filter { $0.isEstimated(in: currency) }.count)
    }
}

struct ExpenseView: View {
    @Environment(\.motionReflectionsAllowed) private var allowsMotion
    private enum Sheet: String, Identifiable {
        case add, history, settings, about
        var id: String { rawValue }
    }
    @State private var filter: ExpenseCDFilterTime = .month
    @State private var sheet: Sheet?
    @State private var calendarAnchor = LedgerCalendarAnchor()

    var body: some View {
        NavigationStack {
            ExpenseMainView(filter: filter, anchor: calendarAnchor)
                .environment(\.motionReflectionsAllowed, allowsMotion && sheet == nil)
                .background(Color(uiColor: .systemGroupedBackground))
                .expenseScreenChrome()
                .navigationTitle("Dashboard")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button("History", systemImage: "clock.arrow.circlepath") { sheet = .history }
                            Button("Settings", systemImage: "gearshape") { sheet = .settings }
                            Button("About Expenso", systemImage: "info.circle") { sheet = .about }
                        } label: { Label("Options", systemImage: "ellipsis") }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Picker("Period", selection: $filter) {
                                Text("Overall").tag(ExpenseCDFilterTime.all)
                                Text("Last 7 days").tag(ExpenseCDFilterTime.week)
                                Text("Last 30 days").tag(ExpenseCDFilterTime.month)
                            }
                        } label: { Label("Period", systemImage: "line.3.horizontal.decrease") }
                    }
                }
                .expenseBottomBar {
                    VStack(spacing: 12) {
                        LedgerUndoBanner()
                        HStack {
                            Spacer()
                            Button {
                                HapticsHelper.shared.hardButtonTap()
                                sheet = .add
                            } label: { Label("Add", systemImage: "plus") }
                            .primaryActionStyle()
                            .accessibilityLabel("Add Transaction")
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 12)
                }
                .sheet(item: $sheet) { destination in
                    Group {
                        switch destination {
                        case .add: AddExpenseView(viewModel: AddExpenseViewModel())
                        case .history: TransactionHistorySheet()
                        case .settings: ExpenseSettingsView()
                        case .about: AboutView()
                        }
                    }
                    .expenseSheetStyle(destination == .about ? .floating : .editor)
                }
        }
        .ledgerCalendarRefresh($calendarAnchor)
    }
}

struct ExpenseMainView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.motionReflectionsAllowed) private var allowsMotion
    var filter: ExpenseCDFilterTime
    let window: ExpenseCalendarWindow
    var fetchRequest: FetchRequest<ExpenseCD>
    var expense: FetchedResults<ExpenseCD> { fetchRequest.wrappedValue }
    @AppStorage(CurrencySettings.key) private var baseCurrency = "RUB"
    @AppStorage(AmountDisplaySettings.compactKey) private var compactAmounts = false
    
    @State private var transactionSheet: TransactionSheet?
    @State private var totals = HistoryFilteredTotals()
    @State private var totalsTask: Task<Void, Never>?
    @State private var totalsGeneration = UUID()
    @State private var isLoadingTotals = true
    
    let haptics = HapticsHelper.shared
    
    init(filter: ExpenseCDFilterTime, anchor: LedgerCalendarAnchor = LedgerCalendarAnchor()) {
        let sortDescriptor = NSSortDescriptor(key: "occuredOn", ascending: false)
        self.filter = filter
        let resolvedWindow = ExpenseCalendarWindow(filter: filter, now: anchor.day, calendar: anchor.calendar)
        window = resolvedWindow
        let request: NSFetchRequest<ExpenseCD> = ExpenseCD.fetchRequest() as! NSFetchRequest<ExpenseCD>
        request.sortDescriptors = [sortDescriptor]
        request.fetchBatchSize = 50
        request.predicate = resolvedWindow.predicate
        fetchRequest = FetchRequest<ExpenseCD>(fetchRequest: request)
    }
    
    var body: some View {
        ScrollView(showsIndicators: false) {
            Text(window.label)
                .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            if fetchRequest.wrappedValue.isEmpty {
                ContentUnavailableView("No Transactions", systemImage: "tray",
                    description: Text("Add a transaction to start tracking your net cash flow."))
                    .padding(.top, 60)
            } else {
                VStack(spacing: 16) {
                    TextView(text: "NET CASH FLOW", type: .overline)
                        .foregroundStyle(.primary)
                        .padding(.top, 30)
                    Text(isLoadingTotals ? "Updating…" : totals.netCashFlow.map { Money.display($0, currency: baseCurrency, compact: compactAmounts) } ?? "Rates needed")
                        .font(.title.weight(.semibold)).monospacedDigit()
                        .lineLimit(2).minimumScaleFactor(0.7)
                        .accessibilityLabel(isLoadingTotals ? "Updating totals" : totals.netCashFlow.map { Money.format($0, currency: baseCurrency) } ?? "Rates needed")
                        .foregroundStyle(.primary)
                    DisclosureGroup("How totals work") {
                        Text("Recorded income minus expenses, not an account balance. Future days and undated transactions are excluded. Currency conversions use each transaction’s saved rate.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .font(.caption).padding(.horizontal, 20).padding(.bottom, 20)
                }.frame(maxWidth: .infinity)
                    .expenseSummarySurface()
                if !isLoadingTotals, totals.excludedUnknownTypes > 0 {
                    Label("\(totals.excludedUnknownTypes) transactions excluded from totals: unknown type.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !isLoadingTotals, totals.estimatedConversionCount > 0 {
                    Label("\(totals.estimatedConversionCount) transactions use estimated exchange rates from another date.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                
                ExpenseSummaryPair {
                    Button(action: {
                        haptics.lightButtonTap()
                        transactionSheet = .summary(true)
                    }) {
                        ExpenseSummaryCard(isIncome: true, amount: totals.income, currency: baseCurrency, compactAmounts: compactAmounts, isLoading: isLoadingTotals)
                    }
                    Button(action: {
                        haptics.lightButtonTap()
                        transactionSheet = .summary(false)
                    }) {
                        ExpenseSummaryCard(isIncome: false, amount: totals.expense, currency: baseCurrency, compactAmounts: compactAmounts, isLoading: isLoadingTotals)
                    }
                }
                .frame(maxWidth: .infinity)
                .buttonStyle(.plain)
                
                Spacer().frame(height: 16)
                
                HStack {
                    Label("Recent Transactions", systemImage: "list.bullet.rectangle").font(.headline).foregroundStyle(.primary)
                    Spacer()
                    Button("See all") { transactionSheet = .history }
                        .font(.subheadline)
                }.padding(4)
                
                LazyVStack(spacing: 8) {
                    ForEach(Array(self.fetchRequest.wrappedValue.prefix(5))) { expenseObj in
                        ExpenseTransView(expenseObj: expenseObj, currentFilter: filter) {
                            haptics.hardButtonTap()
                            transactionSheet = .details(expenseObj)
                        } onCategory: { tag in
                            transactionSheet = .category(tag)
                        }
                    }
                }

            }
            
            Spacer().frame(height: 16)
            
        }
        .padding(.horizontal, 16)
        .onAppear { reloadTotals() }
        .onDisappear { totalsTask?.cancel(); totalsGeneration = UUID() }
        .onChange(of: baseCurrency) { reloadTotals() }
        .onChange(of: window) { _, updated in
            expense.nsPredicate = updated.predicate
            reloadTotals()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange, object: context)) { notification in
            let keys = [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey, NSRefreshedObjectsKey]
            if keys.contains(where: { key in
                (notification.userInfo?[key] as? Set<NSManagedObject>)?.contains(where: { $0 is ExpenseCD }) == true
            }) { reloadTotals() }
        }
        .environment(\.motionReflectionsAllowed, allowsMotion && transactionSheet == nil)
        .sheet(item: $transactionSheet) { destination in
            TransactionSheetView(destination: destination, filter: filter, window: window)
        }
    }

    private func reloadTotals() {
        totalsTask?.cancel()
        let generation = UUID()
        totalsGeneration = generation
        isLoadingTotals = true
        do {
            let projections = try HistoryLedgerProjection.fetch(in: context)
            let period = window
            let currency = baseCurrency
            totalsTask = Task {
                let computation = Task.detached(priority: .userInitiated) {
                    DashboardSummary.compute(projections, window: period, currency: currency)
                }
                let updated = await withTaskCancellationHandler {
                    await computation.value
                } onCancel: { computation.cancel() }
                guard !Task.isCancelled, totalsGeneration == generation else { return }
                totals = updated
                isLoadingTotals = false
            }
        } catch {
            totals = HistoryFilteredTotals(income: nil, expense: nil, netCashFlow: nil)
            isLoadingTotals = false
        }
    }
}

struct ExpenseModelView: View {
    
    var isIncome: Bool
    var type: String
    let window: ExpenseCalendarWindow
    let category: String?
    var fetchRequest: FetchRequest<ExpenseCD>
    var expense: FetchedResults<ExpenseCD> { fetchRequest.wrappedValue }
    @AppStorage(CurrencySettings.key) private var baseCurrency = "RUB"
    @AppStorage(AmountDisplaySettings.compactKey) private var compactAmounts = false
    var allowsCompactAmounts = false
    
    init(isIncome: Bool, filter: ExpenseCDFilterTime, categTag: String? = nil, window: ExpenseCalendarWindow? = nil, allowsCompactAmounts: Bool = false) {
        self.isIncome = isIncome
        self.allowsCompactAmounts = allowsCompactAmounts
        let resolvedType = isIncome ? TRANS_TYPE_INCOME : TRANS_TYPE_EXPENSE
        let resolvedWindow = window ?? ExpenseCalendarWindow(filter: filter)
        self.type = resolvedType
        self.window = resolvedWindow
        category = categTag
        let sortDescriptor = NSSortDescriptor(key: "occuredOn", ascending: false)
        fetchRequest = FetchRequest<ExpenseCD>(entity: ExpenseCD.entity(), sortDescriptors: [sortDescriptor],
            predicate: Self.predicate(window: resolvedWindow, type: resolvedType, category: categTag))
    }

    private static func predicate(window: ExpenseCalendarWindow, type: String, category: String?) -> NSPredicate {
        var predicates = [window.predicate, NSPredicate(format: "type == %@", type)]
        if let category { predicates.append(NSPredicate(format: "tag == %@", category)) }
        return NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
    }
    
    var body: some View {
        ExpenseSummaryCard(isIncome: isIncome, amount: try? Money.total(expense, base: baseCurrency),
                           currency: baseCurrency, compactAmounts: allowsCompactAmounts && compactAmounts)
            .onChange(of: window) { _, updated in expense.nsPredicate = Self.predicate(window: updated, type: type, category: category) }
    }
}

/// Display-only card, shared by the live fetch wrapper and hosted layout checks.
struct ExpenseSummaryCard: View {
    let isIncome: Bool
    let amount: Decimal?
    let currency: String
    let compactAmounts: Bool
    var isLoading = false

    var body: some View {
        let tint: Color = isIncome ? .green : .red
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text(isIncome ? "Income" : "Expense")
                    .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: isIncome ? "arrow.down.left" : "arrow.up.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(tint)
                    .padding(10)
                    .background(tint.opacity(0.12).gradient, in: Circle())
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 6) {
                Text(isLoading ? "Updating…" : amount.map { Money.displayNumber($0, currency: currency, compact: compactAmounts) } ?? "Rates needed")
                    .font(.title2.weight(.semibold)).monospacedDigit()
                    .lineLimit(2).minimumScaleFactor(0.8)
                Text(currency)
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.primary)
        .expenseSummarySurface()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isIncome ? "Income" : "Expense")
        .accessibilityValue(isLoading ? "Updating totals" : amount.map { Money.format($0, currency: currency) } ?? "Rates needed")
    }
}

struct ExpenseTransView: View {
    @AppStorage(CategoryCatalog.storageKey) private var categoryData = Data()
    @AppStorage(AmountDisplaySettings.compactKey) private var compactAmounts = false
    @Environment(\.appAccentColor) private var accentColor
    @ObservedObject var expenseObj: ExpenseCD
    var currentFilter: ExpenseCDFilterTime
    var onSelect: () -> Void
    var onCategory: (String) -> Void
    @AppStorage(CurrencySettings.key) private var baseCurrency = "RUB"

    var body: some View {
        let category = CategoryCatalog.choices(in: CategoryCatalog.decode(categoryData), preserving: expenseObj.tag ?? "")
            .first { $0.id == (expenseObj.tag ?? "") }
        Button(action: onSelect) {
          HStack(spacing: 12) {
                Image(systemName: category?.symbol ?? "tag.fill")
                    .font(.title3).frame(width: 48, height: 48)
                    .background(accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 6) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(expenseObj.title ?? "").font(.headline).lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: 8)
                            amountLabel.fixedSize(horizontal: true, vertical: false)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(expenseObj.title ?? "").font(.headline)
                                .fixedSize(horizontal: false, vertical: true)
                            amountLabel.fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if expenseObj.originalCurrency != baseCurrency {
                        Text(convertedAmountLabel)
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            .accessibilityLabel(expenseObj.convertedAmountLabel(in: baseCurrency))
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            Text(category?.name ?? "Uncategorized").fixedSize()
                            Spacer(minLength: 8)
                            Text(getDateFormatter(date: expenseObj.occuredOn, format: "MMM dd, yyyy")).fixedSize()
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(category?.name ?? "Uncategorized")
                            Text(getDateFormatter(date: expenseObj.occuredOn, format: "MMM dd, yyyy"))
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
          }
          .padding(12)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .expenseSummarySurface(cornerRadius: 20, reflectsMotion: false)
        .contextMenu {
            Button("View \(category?.name ?? "Uncategorized") transactions", systemImage: "tag") {
                onCategory(expenseObj.tag ?? "")
            }
        }
        .accessibilityAction(named: "View category transactions") {
            onCategory(expenseObj.tag ?? "")
        }
    }

    private var amountLabel: some View {
        Text("\(amountSign)\(originalAmountLabel)")
            .font(.headline).monospacedDigit()
            .foregroundStyle(expenseObj.type == TRANS_TYPE_INCOME ? Color.green : Color.primary)
            .accessibilityLabel("\(amountSign)\(expenseObj.originalAmountLabel)")
    }

    private var amountSign: String {
        expenseObj.type == TRANS_TYPE_INCOME ? "+" : "−"
    }

    private var originalAmountLabel: String {
        guard let amount = expenseObj.originalDecimal else { return expenseObj.originalAmountLabel }
        return Money.display(amount, currency: expenseObj.originalCurrency, compact: compactAmounts)
    }

    private var convertedAmountLabel: String {
        do {
            return Money.display(try expenseObj.amount(in: baseCurrency), currency: baseCurrency, compact: compactAmounts)
        } catch {
            return expenseObj.convertedAmountLabel(in: baseCurrency)
        }
    }
}

struct ExpenseView_Previews: PreviewProvider {
    static var previews: some View {
        ExpenseView()
    }
}
