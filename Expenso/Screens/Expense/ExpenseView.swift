//
//  ExpenseView.swift
//  Expenso
//
//  Created by Sameer Nawaz on 31/01/21.
//

import SwiftUI
import ExtraLottie
import FluidGradient

struct ExpenseView: View {
    @Environment(\.presentationMode) var presentationMode: Binding<PresentationMode>
    @Environment(\.managedObjectContext) var managedObjectContext
    @FetchRequest(fetchRequest: ExpenseCD.getAllExpenseData(sortBy: ExpenseCDSort.occuredOn, ascending: false)) var expense: FetchedResults<ExpenseCD>
    
    @State private var filter: ExpenseCDFilterTime = .month
    @State private var activeSheet: ActiveSheet? = nil
    
    @State private var displayAbout = false
    @State private var displaySettings = false
    @State private var showAddExpenseSheet = false
    
    let haptics = HapticsHelper.shared
    
    enum ActiveSheet: Identifiable {
        case filter
        case options
        
        var id: Int {
            switch self {
            case .filter: return 1
            case .options: return 2
            }
        }
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                VStack {
                    ExpenseMainView(filter: filter)
                    Spacer()
                }
                
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button(action: {
                            haptics.hardButtonTap()
                            showAddExpenseSheet = true
                        }) {
                            Image(systemName: "plus")
                                .resizable()
                                .foregroundColor(.black)
                                .frame(width: 28.0, height: 28.0)
                        }
                        .padding()
                        .background(Color.defaultLightGradient)
                        .cornerRadius(35)
                    }
                }
                .padding()
            }
            .navigationTitle("⚡ Dashboard")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        haptics.lightButtonTap()
                        activeSheet = .options
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    
                    Button {
                        haptics.lightButtonTap()
                        activeSheet = .filter
                    } label: {
                        Image(systemName: "contextualmenu.and.cursorarrow")
                    }
                }
            }
            .sheet(isPresented: $showAddExpenseSheet) {
                AddExpenseView(viewModel: AddExpenseViewModel())
            }
            .sheet(isPresented: $displayAbout) {
                
            }
            .sheet(isPresented: $displaySettings) {
                ExpenseSettingsView()
            }
            .onChange(of: showAddExpenseSheet) { newValue in
                if newValue == false {
                    managedObjectContext.refreshAllObjects()
                }
            }
            .actionSheet(item: $activeSheet) { sheet in
                switch sheet {
                case .filter:
                    return ActionSheet(title: Text("Select a filter"), buttons: [
                        .default(Text("Overall")) { filter = .all },
                        .default(Text("Last 7 days")) { filter = .week },
                        .default(Text("Last 30 days")) { filter = .month },
                        .cancel()
                    ])
                case .options:
                    return ActionSheet(title: Text("Select an option"), buttons: [
                        .default(Text("About")) { self.displayAbout = true },
                        .default(Text("Settings")) { self.displaySettings = true },
                        .cancel()
                    ])
                }
            }
            .ignoresSafeArea(.container, edges: .bottom)
        }
    }
}

struct ExpenseMainView: View {
    var filter: ExpenseCDFilterTime
    var fetchRequest: FetchRequest<ExpenseCD>
    var expense: FetchedResults<ExpenseCD> { fetchRequest.wrappedValue }
    @AppStorage(UD_EXPENSE_CURRENCY) var CURRENCY: String = ""
    
    @State private var pickedExpense: ExpenseCD?
    @State private var showDetailedExpenseSheet = false
    
    @State private var showingExprenseFilerSheet = false
    @State private var showingIncomeFilerSheet = false
    
    let haptics = HapticsHelper.shared
    
    init(filter: ExpenseCDFilterTime) {
        let sortDescriptor = NSSortDescriptor(key: "occuredOn", ascending: false)
        self.filter = filter
        if filter == .all {
            fetchRequest = FetchRequest<ExpenseCD>(entity: ExpenseCD.entity(), sortDescriptors: [sortDescriptor])
        } else {
            var startDate: NSDate!
            let endDate: NSDate = NSDate()
            if filter == .week { startDate = Date().getLast7Day()! as NSDate }
            else if filter == .month { startDate = Date().getLast30Day()! as NSDate }
            else { startDate = Date().getLast6Month()! as NSDate }
            let predicate = NSPredicate(format: "occuredOn >= %@ AND occuredOn <= %@", startDate, endDate)
            fetchRequest = FetchRequest<ExpenseCD>(entity: ExpenseCD.entity(), sortDescriptors: [sortDescriptor], predicate: predicate)
        }
    }
    
    private func getTotalBalance() -> String {
        var value = Double(0)
        for i in expense {
            if i.type == TRANS_TYPE_INCOME { value += i.amount }
            else if i.type == TRANS_TYPE_EXPENSE { value -= i.amount }
        }
        return "\(String(format: "%.2f", value))"
    }
    
    var body: some View {
        ScrollView(showsIndicators: false) {
            if fetchRequest.wrappedValue.isEmpty {
                ExtraLottieView(animationName: "empty-face")
                    .frame(
                        width: 300, height: 300)
                VStack {
                    TextView(text: "No Transaction Yet!", type: .h6).foregroundColor(Color.text_primary_color)
                    TextView(text: "Add a transaction and it will show up here", type: .body_1).foregroundColor(Color.text_secondary_color).padding(.top, 2)
                }.padding(.horizontal)
            } else {
                VStack(spacing: 16) {
                    TextView(text: "TOTAL BALANCE", type: .overline)
                        .foregroundStyle(.black)
                        .padding(.top, 30)
                    TextView(text: "\(CURRENCY)\(getTotalBalance())", type: .h5)
                        .foregroundStyle(.black)
                        .padding(.bottom, 30)
                }.frame(maxWidth: .infinity)
                    .background(FluidGradient(blobs: [.cyan.opacity(0.4), .purple.opacity(0.4)],
                                                                      speed: 0.05,
                                                                      blur: 0.75)
                        .background(Color.defaultLightGradient))
                    .cornerRadius(10)
                
                HStack(spacing: 8) {
                    Button(action: {
                        haptics.lightButtonTap()
                        showingIncomeFilerSheet = true
                    }) {
                        ExpenseModelView(isIncome: true, filter: filter)
                    }
                    Button(action: {
                        haptics.lightButtonTap()
                        showingExprenseFilerSheet = true
                    }) {
                        ExpenseModelView(isIncome: false, filter: filter)
                    }
                }
                .frame(maxWidth: .infinity)
                
                Spacer().frame(height: 16)
                
                HStack {
                    TextView(text: "Recent Transaction", type: .subtitle_1).foregroundColor(Color.text_primary_color)
                    Spacer()
                }.padding(4)
                
                ForEach(self.fetchRequest.wrappedValue) { expenseObj in
                    Button(action: {
                        haptics.hardButtonTap()
                        pickedExpense = expenseObj
                    })
                    {
                        ExpenseTransView(expenseObj: expenseObj)
                    }
                }
                .sheet(item: $pickedExpense) { expenseObj in
                    ExpenseDetailedView(expenseObj: expenseObj)
                }
                .sheet(isPresented: $showingExprenseFilerSheet) {
                    ExpenseFilterView(isIncome: false)
                }
                .sheet(isPresented: $showingIncomeFilerSheet) {
                    ExpenseFilterView(isIncome: true)
                }
            }
            
            Spacer().frame(height: 150)
            
        }.padding(.horizontal, 8).padding(.top, 0)
    }
}

struct ExpenseModelView: View {
    
    var isIncome: Bool
    var type: String
    var fetchRequest: FetchRequest<ExpenseCD>
    var expense: FetchedResults<ExpenseCD> { fetchRequest.wrappedValue }
    @AppStorage(UD_EXPENSE_CURRENCY) var CURRENCY: String = ""
    var gradientBlobs: [Color] {
        if isIncome { return [.green.opacity(0.3), .mint.opacity(0.3)] }
        else { return [.red.opacity(0.5), .orange.opacity(0.4)] }
    }
    
    private func getTotalValue() -> String {
        var value = Double(0)
        for i in expense { value += i.amount }
        return "\(String(format: "%.2f", value))"
    }
    
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
                Image(isIncome ? "income_icon" : "expense_icon").resizable().frame(width: 40.0, height: 40.0).padding(12)
            }
            HStack{
                TextView(text: isIncome ? "INCOME" : "EXPENSE", type: .overline)
                    .foregroundStyle(.black)
                Spacer()
            }
            .padding(.horizontal, 12)
            HStack {
                TextView(text: "\(CURRENCY)\(getTotalValue())", type: .h5, lineLimit: 1)
                    .foregroundStyle(.black)
                Spacer()
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 12)
        .background(FluidGradient(blobs: gradientBlobs, speed: 0.05, blur: 0.75)
            .background(Color.defaultLightGradient))
        .cornerRadius(10)
    }
}

struct ExpenseTransView: View {
    @ObservedObject var expenseObj: ExpenseCD
    @AppStorage(UD_EXPENSE_CURRENCY) var CURRENCY: String = ""
    @State private var showingExprenseFilterSheet = false
    
    var body: some View {
        HStack {
            Button(action: {
                showingExprenseFilterSheet = true
            }) {
                Text(getTransTagEmoji(transTag: expenseObj.tag ?? ""))
                    .padding(16)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextView(text: expenseObj.title ?? "", type: .subtitle_1, lineLimit: 1).foregroundColor(Color.text_primary_color)
                    Spacer()
                    TextView(text: "\(expenseObj.type == TRANS_TYPE_INCOME ? "+" : "-")\(CURRENCY)\(expenseObj.amount)", type: .subtitle_1)
                        .foregroundColor(expenseObj.type == TRANS_TYPE_INCOME ? Color.main_green : Color.main_red)
                }
                HStack {
                    TextView(text: getTransTagTitle(transTag: expenseObj.tag ?? ""), type: .body_2).foregroundColor(Color.text_primary_color)
                    Spacer()
                    TextView(text: getDateFormatter(date: expenseObj.occuredOn, format: "MMM dd, yyyy"), type: .body_2).foregroundColor(Color.text_primary_color)
                }
            }.padding(.leading, 4)
            
            Spacer()
            
        }
        .padding(8)
        .background(
            .ultraThinMaterial // This applies a blur effect to the background
        )
        .cornerRadius(10)
        .sheet(isPresented: $showingExprenseFilterSheet) {
            ExpenseFilterView(categTag: expenseObj.tag)
        }
    }
}

struct ExpenseView_Previews: PreviewProvider {
    static var previews: some View {
        ExpenseView()
    }
}
