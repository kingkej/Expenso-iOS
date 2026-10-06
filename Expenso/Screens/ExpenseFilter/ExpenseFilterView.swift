//
//  ExpenseFilterView.swift
//  Expenso
//
//  Created by Sameer Nawaz on 31/01/21.
//

import SwiftUI
import CoreData

struct ExpenseFilterView: View {
    @AppStorage(CategoryCatalog.storageKey) private var categoryData = Data()
    
    @Environment(\.dismiss) private var dismiss
    @State private var filter: ExpenseCDFilterTime
    @State private var calendarAnchor = LedgerCalendarAnchor()
    private var window: ExpenseCalendarWindow {
        ExpenseCalendarWindow(filter: filter, now: calendarAnchor.day, calendar: calendarAnchor.calendar)
    }
    
    var isIncome: Bool?
    var categTag: String?
    let haptics = HapticsHelper.shared
    
    init(isIncome: Bool? = nil, categTag: String? = nil, defaultFilter: ExpenseCDFilterTime = .month) {
        self.isIncome = isIncome
        self.categTag = categTag
        _filter = State(initialValue: defaultFilter)
    }
    
    var body: some View {
        NavigationStack {
            Group {
                if let isIncome {
                    InsightsContentView(initialPeriod: insightsPeriod, initialKind: isIncome ? .income : .expense)
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 16) {
                            if let tag = categTag {
                                Text(window.label).font(.caption).foregroundStyle(.secondary)
                                ExpenseSummaryPair {
                                    ExpenseModelView(isIncome: true, filter: filter, categTag: tag, window: window)
                                    ExpenseModelView(isIncome: false, filter: filter, categTag: tag, window: window)
                                }.frame(maxWidth: .infinity)
                                ExpenseFilterTransList(filter: filter, tag: tag, window: window)
                            }
                        }
                        .padding(16)
                    }
                    .background(Color(uiColor: .systemGroupedBackground))
                    .expenseScreenChrome()
                    .navigationTitle(categTag.map { tag in CategoryCatalog.decode(categoryData).first { $0.id == tag }?.name ?? tag } ?? "Transactions")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                }
                if isIncome == nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Overall") { haptics.lightButtonTap(); filter = .all }
                            Button("Last 7 days") { haptics.lightButtonTap(); filter = .week }
                            Button("Last 30 days") { haptics.lightButtonTap(); filter = .month }
                        } label: {
                            Label("Period", systemImage: "line.3.horizontal.decrease")
                        }
                    }
                }
            }
        }
        .ledgerCalendarRefresh($calendarAnchor)
    }
    private var insightsPeriod: InsightsPeriod {
        switch filter {
        case .week: return .last7Days
        case .month: return .last30Days
        case .all: return .allTime
        }
    }
}

struct ExpenseFilterTransList: View {
    var isIncome: Bool?
    var tag: String?
    var currentFilter: ExpenseCDFilterTime
    let window: ExpenseCalendarWindow
    var fetchRequest: FetchRequest<ExpenseCD>
    var expense: FetchedResults<ExpenseCD> { fetchRequest.wrappedValue }
    @State private var transactionSheet: TransactionSheet?
    
    init(isIncome: Bool? = nil, filter: ExpenseCDFilterTime, tag: String? = nil, window: ExpenseCalendarWindow? = nil) {
        self.currentFilter = filter
        self.isIncome = isIncome
        self.tag = tag
        let resolvedWindow = window ?? ExpenseCalendarWindow(filter: filter)
        self.window = resolvedWindow
        let sortDescriptor = NSSortDescriptor(key: "occuredOn", ascending: false)
        let request: NSFetchRequest<ExpenseCD> = ExpenseCD.fetchRequest() as! NSFetchRequest<ExpenseCD>
        request.sortDescriptors = [sortDescriptor]
        request.fetchBatchSize = 50
        var predicates = [resolvedWindow.predicate]
        if let isIncome { predicates.append(NSPredicate(format: "type == %@", isIncome ? TRANS_TYPE_INCOME : TRANS_TYPE_EXPENSE)) }
        if let tag { predicates.append(NSPredicate(format: "tag == %@", tag)) }
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        fetchRequest = FetchRequest<ExpenseCD>(fetchRequest: request)
    }

    private var predicate: NSPredicate {
        var predicates = [window.predicate]
        if let isIncome { predicates.append(NSPredicate(format: "type == %@", isIncome ? TRANS_TYPE_INCOME : TRANS_TYPE_EXPENSE)) }
        if let tag { predicates.append(NSPredicate(format: "tag == %@", tag)) }
        return NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
    }
    
    var body: some View {
        LazyVStack(spacing: 8) {
            if expense.isEmpty {
                ContentUnavailableView("No Transactions", systemImage: "tray",
                    description: Text("There are no transactions for this period."))
            }
            ForEach(self.fetchRequest.wrappedValue) { expenseObj in
                ExpenseTransView(expenseObj: expenseObj, currentFilter: currentFilter) {
                    transactionSheet = .details(expenseObj)
                } onCategory: { tag in
                    transactionSheet = .category(tag)
                }
            }
        }
        .onChange(of: window) { _, _ in expense.nsPredicate = predicate }
        .sheet(item: $transactionSheet) { destination in
            TransactionSheetView(destination: destination, filter: currentFilter)
        }
    }
}

struct ExpenseFilterView_Previews: PreviewProvider {
    static var previews: some View {
        ExpenseFilterView(isIncome: true)
    }
}
