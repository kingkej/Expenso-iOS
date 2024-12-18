//
//  ExpenseDetailedView.swift
//  Expenso
//
//  Created by Sameer Nawaz on 31/01/21.
//

import SwiftUI

struct ExpenseDetailedView: View {
    
    @Environment(\.presentationMode) var presentationMode: Binding<PresentationMode>
    // CoreData
    @Environment(\.managedObjectContext) var managedObjectContext
    
    @ObservedObject private var viewModel: ExpenseDetailedViewModel
    @AppStorage(UD_EXPENSE_CURRENCY) var CURRENCY: String = ""
    
    @State private var confirmDelete = false
    
    init(expenseObj: ExpenseCD) {
        viewModel = ExpenseDetailedViewModel(expenseObj: expenseObj)
    }
    @State private var expenseToEdit: ExpenseCD?
    let haptics = HapticsHelper.shared
    
    var body: some View {
        NavigationView {
            VStack {
                ScrollView(showsIndicators: false) {
                    
                    VStack(spacing: 24) {
                        ExpenseDetailedListView(title: "Title", description: viewModel.expenseObj.title ?? "")
                        ExpenseDetailedListView(title: "Amount", description: "\(CURRENCY)\(viewModel.expenseObj.amount)")
                        ExpenseDetailedListView(title: "Transaction type", description: viewModel.expenseObj.type == TRANS_TYPE_INCOME ? "Income" : "Expense" )
                        ExpenseDetailedListView(title: "Tag", description: getTransTagTitle(transTag: viewModel.expenseObj.tag ?? ""))
                        ExpenseDetailedListView(title: "When", description: getDateFormatter(date: viewModel.expenseObj.occuredOn, format: "EEEE, dd MMM hh:mm a"))
                        if let note = viewModel.expenseObj.note, note != "" {
                            ExpenseDetailedListView(title: "Note", description: note)
                        }
                        if let data = viewModel.expenseObj.imageAttached {
                            VStack(spacing: 8) {
                                HStack { TextView(text: "Attachment", type: .caption).foregroundColor(Color.init(hex: "828282")); Spacer() }
                                Image(uiImage: UIImage(data: data)!)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(height: 250).frame(maxWidth: .infinity)
                                    .background(Color.secondary_color)
                                    .cornerRadius(4)
                            }
                        }
                    }.padding(16)
                    
                    Spacer().frame(height: 24)
                    Spacer()
                }
                .alert(isPresented: $confirmDelete,
                       content: {
                    Alert(title: Text(APP_NAME), message: Text("Are you sure you want to delete this transaction?"),
                          primaryButton: .destructive(Text("Delete")) {
                        viewModel.deleteNote(managedObjectContext: managedObjectContext)
                    }, secondaryButton: Alert.Button.cancel(Text("Cancel"), action: { confirmDelete = false })
                    )
                })
            }
            .navigationTitle("Details")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        haptics.mediumButtonTap()
                        presentationMode.wrappedValue.dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        haptics.mediumButtonTap()
                        expenseToEdit = viewModel.expenseObj
                    } label: {
                        Image(systemName: "pencil")
                    }
                    
                    Button {
                        haptics.mediumButtonTap()
                        confirmDelete = true
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
            .sheet(item: $expenseToEdit) { expense in
                AddExpenseView(viewModel: AddExpenseViewModel(expenseObj: viewModel.expenseObj))
            }
        }
    }
}

struct ExpenseDetailedListView: View {
    
    var title: String
    var description: String
    
    var body: some View {
        VStack(spacing: 8) {
            HStack { TextView(text: title, type: .caption).foregroundColor(Color.init(hex: "828282")); Spacer() }
            HStack { TextView(text: description, type: .body_1).foregroundColor(Color.text_primary_color); Spacer() }
        }
    }
}

//struct ExpenseDetailedView_Previews: PreviewProvider {
//    static var previews: some View {
//        ExpenseDetailedView()
//    }
//}
