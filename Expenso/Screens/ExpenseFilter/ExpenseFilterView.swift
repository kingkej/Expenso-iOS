//
//  ExpenseFilterView.swift
//  Expenso
//
//  Created by Sameer Nawaz on 31/01/21.
//

import SwiftUI
import CoreData

struct ExpenseFilterView: View {
    
    @Environment(\.dismiss) private var dismiss
    @State private var filter: ExpenseCDFilterTime = .month
    
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
                VStack {
                    ScrollView(showsIndicators: false) {
                        if let isIncome = isIncome {
                            ExpenseFilterChartView(isIncome: isIncome, filter: filter).frame(maxWidth: 350, maxHeight: 350)
                            ExpenseFilterTransList(isIncome: isIncome, filter: filter)
                        }
                        if let tag = categTag {
                            HStack(spacing: 8) {
                                ExpenseModelView(isIncome: true, filter: filter, categTag: tag)
                                ExpenseModelView(isIncome: false, filter: filter, categTag: tag)
                            }.frame(maxWidth: .infinity)
                            ExpenseFilterTransList(filter: filter, tag: tag)
                        }
                    }.padding(.horizontal, 16)
                }
                .navigationTitle(categTag.map { getTransTagTitle(transTag: $0) } ?? (isIncome == true ? "Income" : "Expenses"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                    }
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
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
}

struct ExpenseFilterChartView: View {
    
    var isIncome: Bool
    var type: String
    var fetchRequest: FetchRequest<ExpenseCD>
    var expense: FetchedResults<ExpenseCD> { fetchRequest.wrappedValue }
    @AppStorage(CurrencySettings.key) private var baseCurrency = "RUB"
    
    private func getChartModel() -> [ChartModel] {
        
        var transactions = [String: Decimal]()
        for i in expense {
            let tag = i.tag ?? "unknown"
            guard let amount = try? i.amount(in: baseCurrency),
                  let total = try? Money.add(transactions[tag] ?? 0, amount) else { return [] }
            transactions[tag] = total
        }
        
        var models = [ChartModel]()
        for i in transactions.sorted(by: { $0.key < $1.key }) {
            models.append(ChartModel(transType: i.key == "unknown" ? "Unknown category" : getTransTagTitle(transTag: i.key), transAmount: NSDecimalNumber(decimal: i.value).doubleValue))
        }
        return models
    }
    
    init(isIncome: Bool, filter: ExpenseCDFilterTime) {
        self.isIncome = isIncome
        self.type = isIncome ? TRANS_TYPE_INCOME : TRANS_TYPE_EXPENSE
        let sortDescriptor = NSSortDescriptor(key: "occuredOn", ascending: false)
        if filter == .all {
            let predicate = NSPredicate(format: "type == %@", type)
            fetchRequest = FetchRequest<ExpenseCD>(entity: ExpenseCD.entity(), sortDescriptors: [sortDescriptor], predicate: predicate)
        } else {
            var startDate: NSDate!
            let endDate: NSDate = NSDate()
            if filter == .week { startDate = Date().getLast7Day()! as NSDate }
            else if filter == .month { startDate = Date().getLast30Day()! as NSDate }
            else { startDate = Date().getLast6Month()! as NSDate }
            let predicate = NSPredicate(format: "occuredOn >= %@ AND occuredOn <= %@ AND type == %@", startDate, endDate, type)
            fetchRequest = FetchRequest<ExpenseCD>(entity: ExpenseCD.entity(), sortDescriptors: [sortDescriptor], predicate: predicate)
        }
    }
    
    var body: some View {
        Group {
            if !expense.isEmpty {
                Text("Total \(isIncome ? "Income" : "Expense") — \(Money.totalLabel(expense, base: baseCurrency))")
                if (try? Money.total(expense, base: baseCurrency)) != nil {
                    PieChartView(entries: ChartModel.getTransaction(transactions: getChartModel()))
                } else {
                    Text("Edit transactions with missing rates before displaying a converted chart.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ExpenseFilterTransList: View {
    var isIncome: Bool?
    var tag: String?
    var currentFilter: ExpenseCDFilterTime
    var fetchRequest: FetchRequest<ExpenseCD>
    var expense: FetchedResults<ExpenseCD> { fetchRequest.wrappedValue }
    @State private var transactionSheet: TransactionSheet?
    
    init(isIncome: Bool? = nil, filter: ExpenseCDFilterTime, tag: String? = nil) {
        self.currentFilter = filter
        let sortDescriptor = NSSortDescriptor(key: "occuredOn", ascending: false)
        let request: NSFetchRequest<ExpenseCD> = ExpenseCD.fetchRequest() as! NSFetchRequest<ExpenseCD>
        request.sortDescriptors = [sortDescriptor]
        request.fetchBatchSize = 50
        if filter == .all {
            let predicate: NSPredicate!
            if let isIncome = isIncome {
                predicate = NSPredicate(format: "type == %@", (isIncome ? TRANS_TYPE_INCOME : TRANS_TYPE_EXPENSE))
            } else if let tag = tag { predicate = NSPredicate(format: "tag == %@", tag) }
            else { predicate = NSPredicate(format: "occuredOn <= %@", NSDate()) }
            request.predicate = predicate
        } else {
            var startDate: NSDate!
            let endDate: NSDate = NSDate()
            if filter == .week { startDate = Date().getLast7Day()! as NSDate }
            else if filter == .month { startDate = Date().getLast30Day()! as NSDate }
            else { startDate = Date().getLast6Month()! as NSDate }
            let predicate: NSPredicate!
            if let isIncome = isIncome {
                predicate = NSPredicate(format: "occuredOn >= %@ AND occuredOn <= %@ AND type == %@", startDate, endDate, (isIncome ? TRANS_TYPE_INCOME : TRANS_TYPE_EXPENSE))
            } else if let tag = tag {
                predicate = NSPredicate(format: "occuredOn >= %@ AND occuredOn <= %@ AND tag == %@", startDate, endDate, tag)
            } else { predicate = NSPredicate(format: "occuredOn >= %@ AND occuredOn <= %@", startDate, endDate) }
            request.predicate = predicate
        }
        fetchRequest = FetchRequest<ExpenseCD>(fetchRequest: request)
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
