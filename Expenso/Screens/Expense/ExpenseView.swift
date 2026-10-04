//
//  ExpenseView.swift
//  Expenso
//
//  Created by Sameer Nawaz on 31/01/21.
//

import SwiftUI
import CoreData

/// A stable presentation host keeps sheets alive when a transaction row disappears.
enum TransactionSheet: Identifiable {
    case details(ExpenseCD), summary(Bool), category(String)

    var id: String {
        switch self {
        case .details(let expense): return "details-\(expense.objectID.uriRepresentation().absoluteString)"
        case .summary(let income): return "summary-\(income)"
        case .category(let tag): return "category-\(tag)"
        }
    }
}

struct TransactionSheetView: View {
    let destination: TransactionSheet
    let filter: ExpenseCDFilterTime

    var body: some View {
        Group {
            switch destination {
            case .details(let expense): ExpenseDetailedView(expenseObj: expense)
            case .summary(let income): ExpenseFilterView(isIncome: income, defaultFilter: filter)
            case .category(let tag): ExpenseFilterView(categTag: tag, defaultFilter: filter)
            }
        }
        .expenseSheetStyle()
    }
}

struct ExpenseView: View {
    private enum Sheet: String, Identifiable {
        case add, settings, about
        var id: String { rawValue }
    }
    @State private var filter: ExpenseCDFilterTime = .month
    @State private var sheet: Sheet?

    var body: some View {
        NavigationStack {
            ExpenseMainView(filter: filter)
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle("Dashboard")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
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
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        Spacer()
                        Button {
                            HapticsHelper.shared.hardButtonTap()
                            sheet = .add
                        } label: { Label("Add Transaction", systemImage: "plus") }
                        .primaryActionStyle()
                    }
                    .padding(.horizontal, 20).padding(.vertical, 12)
                }
                .sheet(item: $sheet) { destination in
                    Group {
                        switch destination {
                        case .add: AddExpenseView(viewModel: AddExpenseViewModel())
                        case .settings: ExpenseSettingsView()
                        case .about: AboutView()
                        }
                    }
                    .expenseSheetStyle()
                }
        }
    }
}

struct ExpenseMainView: View {
    var filter: ExpenseCDFilterTime
    var fetchRequest: FetchRequest<ExpenseCD>
    var expense: FetchedResults<ExpenseCD> { fetchRequest.wrappedValue }
    @AppStorage(CurrencySettings.key) private var baseCurrency = "RUB"
    
    @State private var transactionSheet: TransactionSheet?
    
    let haptics = HapticsHelper.shared
    
    init(filter: ExpenseCDFilterTime) {
        let sortDescriptor = NSSortDescriptor(key: "occuredOn", ascending: false)
        self.filter = filter
        let request: NSFetchRequest<ExpenseCD> = ExpenseCD.fetchRequest() as! NSFetchRequest<ExpenseCD>
        request.sortDescriptors = [sortDescriptor]
        request.fetchBatchSize = 50
        if filter == .all {
            // No predicate for overall filter
        } else {
            var startDate: NSDate!
            let endDate: NSDate = NSDate()
            if filter == .week { startDate = Date().getLast7Day()! as NSDate }
            else if filter == .month { startDate = Date().getLast30Day()! as NSDate }
            else { startDate = Date().getLast6Month()! as NSDate }
            let predicate = NSPredicate(format: "occuredOn >= %@ AND occuredOn <= %@", startDate, endDate)
            request.predicate = predicate
        }
        fetchRequest = FetchRequest<ExpenseCD>(fetchRequest: request)
    }
    
    var body: some View {
        ScrollView(showsIndicators: false) {
            if fetchRequest.wrappedValue.isEmpty {
                ContentUnavailableView("No Transactions", systemImage: "tray",
                    description: Text("Add a transaction to start tracking your balance."))
                    .padding(.top, 60)
            } else {
                VStack(spacing: 16) {
                    TextView(text: "TOTAL BALANCE", type: .overline)
                        .foregroundStyle(.primary)
                        .padding(.top, 30)
                    TextView(text: Money.totalLabel(expense, base: baseCurrency, balance: true), type: .h5)
                        .foregroundStyle(.primary)
                        .padding(.bottom, 30)
                }.frame(maxWidth: .infinity)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
                
                HStack(spacing: 8) {
                    Button(action: {
                        haptics.lightButtonTap()
                        transactionSheet = .summary(true)
                    }) {
                        ExpenseModelView(isIncome: true, filter: filter)
                    }
                    Button(action: {
                        haptics.lightButtonTap()
                        transactionSheet = .summary(false)
                    }) {
                        ExpenseModelView(isIncome: false, filter: filter)
                    }
                }
                .frame(maxWidth: .infinity)
                .buttonStyle(.plain)
                
                Spacer().frame(height: 16)
                
                HStack {
                    Label("Recent Transactions", systemImage: "list.bullet.rectangle").font(.headline).foregroundStyle(.primary)
                    Spacer()
                }.padding(4)
                
                LazyVStack(spacing: 8) {
                    ForEach(self.fetchRequest.wrappedValue) { expenseObj in
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
        .sheet(item: $transactionSheet) { destination in
            TransactionSheetView(destination: destination, filter: filter)
        }
    }
}

struct ExpenseModelView: View {
    
    var isIncome: Bool
    var type: String
    var fetchRequest: FetchRequest<ExpenseCD>
    var expense: FetchedResults<ExpenseCD> { fetchRequest.wrappedValue }
    @AppStorage(CurrencySettings.key) private var baseCurrency = "RUB"
    
    init(isIncome: Bool, filter: ExpenseCDFilterTime, categTag: String? = nil) {
        self.isIncome = isIncome
        self.type = isIncome ? TRANS_TYPE_INCOME : TRANS_TYPE_EXPENSE
        let sortDescriptor = NSSortDescriptor(key: "occuredOn", ascending: false)
        if filter == .all {
            var predicate: NSPredicate!
            if let tag = categTag {
                predicate = NSPredicate(format: "type == %@ AND tag == %@", type, tag)
            } else { predicate = NSPredicate(format: "type == %@", type) }
            fetchRequest = FetchRequest<ExpenseCD>(entity: ExpenseCD.entity(), sortDescriptors: [sortDescriptor], predicate: predicate)
        } else {
            var startDate: NSDate!
            let endDate: NSDate = NSDate()
            if filter == .week { startDate = Date().getLast7Day()! as NSDate }
            else if filter == .month { startDate = Date().getLast30Day()! as NSDate }
            else { startDate = Date().getLast6Month()! as NSDate }
            var predicate: NSPredicate!
            if let tag = categTag {
                predicate = NSPredicate(format: "occuredOn >= %@ AND occuredOn <= %@ AND type == %@ AND tag == %@", startDate, endDate, type, tag)
            } else { predicate = NSPredicate(format: "occuredOn >= %@ AND occuredOn <= %@ AND type == %@", startDate, endDate, type) }
            fetchRequest = FetchRequest<ExpenseCD>(entity: ExpenseCD.entity(), sortDescriptors: [sortDescriptor], predicate: predicate)
        }
    }
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Spacer()
                Image(systemName: isIncome ? "arrow.down.left" : "arrow.up.right").font(.title2.weight(.semibold)).foregroundStyle(isIncome ? Color.green : Color.red).padding(12)
            }
            HStack{
                TextView(text: isIncome ? "INCOME" : "EXPENSE", type: .overline)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 12)
            HStack {
                TextView(text: Money.totalLabel(expense, base: baseCurrency), type: .h5, lineLimit: 1)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
    }
}

struct ExpenseTransView: View {
    @Environment(\.appAccentColor) private var accentColor
    @ObservedObject var expenseObj: ExpenseCD
    var currentFilter: ExpenseCDFilterTime
    var onSelect: () -> Void
    var onCategory: (String) -> Void
    @AppStorage(CurrencySettings.key) private var baseCurrency = "RUB"

    var body: some View {
        HStack(spacing: 12) {
            Button {
                onCategory(expenseObj.tag ?? TRANS_TAG_OTHERS)
            } label: {
                Image(systemName: transactionSymbol(for: expenseObj.tag ?? ""))
                    .font(.title3).frame(width: 48, height: 48)
                    .background(accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View \(getTransTagTitle(transTag: expenseObj.tag ?? "")) transactions")

            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(expenseObj.title ?? "").font(.headline).lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(expenseObj.type == TRANS_TYPE_INCOME ? "+" : "−")\(expenseObj.originalAmountLabel)")
                            .font(.headline).monospacedDigit()
                            .foregroundStyle(expenseObj.type == TRANS_TYPE_INCOME ? Color.green : Color.primary)
                    }
                    if expenseObj.originalCurrency != baseCurrency {
                        Text("In base: \(expenseObj.convertedAmountLabel(in: baseCurrency))")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    HStack {
                        Text(getTransTagTitle(transTag: expenseObj.tag ?? ""))
                        Spacer()
                        Text(getDateFormatter(date: expenseObj.occuredOn, format: "MMM dd, yyyy"))
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.primary)
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
}

struct ExpenseView_Previews: PreviewProvider {
    static var previews: some View {
        ExpenseView()
    }
}
