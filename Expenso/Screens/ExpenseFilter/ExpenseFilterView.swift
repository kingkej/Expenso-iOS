//
//  ExpenseFilterView.swift
//  Expenso
//
//  Created by Sameer Nawaz on 31/01/21.
//

import SwiftUI
import CoreData

struct ExpenseFilterView: View {
    
    @Environment(\.presentationMode) var presentationMode: Binding<PresentationMode>
    // CoreData
    @Environment(\.managedObjectContext) var managedObjectContext
    @FetchRequest(fetchRequest: ExpenseCD.getAllExpenseData(sortBy: ExpenseCDSort.occuredOn, ascending: false)) var expense: FetchedResults<ExpenseCD>
    
    @State var filter: ExpenseCDFilterTime = .month
    @State var showingActionSheet = false
    @State private var showFilterDialog = false
    var isIncome: Bool?
    var categTag: String?
    
    init(isIncome: Bool? = nil, categTag: String? = nil, defaultFilter: ExpenseCDFilterTime = .month) {
        self.isIncome = isIncome
        self.categTag = categTag
        _filter = State(initialValue: defaultFilter)
    }
    
    var body: some View {
        NavigationView {
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
                    }.padding(.horizontal, 8).padding(.top, 0)
                }
                .navigationTitle("⚡ Aloki")
                .confirmationDialog("Select a filter", isPresented: $showFilterDialog, titleVisibility: .visible) {
                    Button("Overall") { filter = .all }
                    Button("Last 7 days") { filter = .week }
                    Button("Last 30 days") { filter = .month }
                    Button("Cancel", role: .cancel) {}
                }
            }
        }
}

struct ExpenseFilterChartView: View {
    
    var isIncome: Bool
    var type: String
    var fetchRequest: FetchRequest<ExpenseCD>
    var expense: FetchedResults<ExpenseCD> { fetchRequest.wrappedValue }
    @AppStorage(UD_EXPENSE_CURRENCY) var CURRENCY: String = ""
    
    private func getTotalValue() -> Double {
        var value = Double(0)
        for i in expense { value += i.amount }
        return value
    }
    
    private func getChartModel() -> [ChartModel] {
        
        var transactions = [String: Double]()
        for i in expense {
            guard let tag = i.tag else { continue }
            if let value = transactions[tag] {
                transactions[tag] = value + i.amount
            } else { transactions[tag] = i.amount }
        }
        
        var models = [ChartModel]()
        for i in transactions {
            models.append(ChartModel(transType: getTransTagTitle(transTag: i.key), transAmount: i.value))
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
                Text("Total \(isIncome ? "Income" : "Expense") - \(CURRENCY)\(formatAmount(getTotalValue()))")
                PieChartView(entries: ChartModel.getTransaction(transactions: getChartModel()))
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
    @State private var pickedExpense: ExpenseCD?
    
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
            ForEach(self.fetchRequest.wrappedValue) { expenseObj in
                Button(action: {
                    pickedExpense = expenseObj
                }) {
                    ExpenseTransView(expenseObj: expenseObj, currentFilter: currentFilter)
                }
            }
        }
        .sheet(item: $pickedExpense) { expenseObj in
            ExpenseDetailedView(expenseObj: expenseObj)
        }
    }
}

struct ExpenseFilterView_Previews: PreviewProvider {
    static var previews: some View {
        ExpenseFilterView(isIncome: true)
    }
}
