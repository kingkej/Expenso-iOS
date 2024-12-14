//
//  AddExpenseView.swift
//  Expenso
//
//  Created by Sameer Nawaz on 31/01/21.
//

import SwiftUI
import Pow

struct AddExpenseView: View {
    @Environment(\.presentationMode) var presentationMode: Binding<PresentationMode>
    // CoreData
    @Environment(\.managedObjectContext) var managedObjectContext
    @State private var confirmDelete = false
    @State var showAttachSheet = false
    
    @StateObject var viewModel: AddExpenseViewModel
    
    let typeOptions = [
        DropdownOption(key: TRANS_TYPE_INCOME, val: "Income"),
        DropdownOption(key: TRANS_TYPE_EXPENSE, val: "Expense")
    ]
    
    let tagOptions = [
        DropdownOption(key: TRANS_TAG_TRANSPORT, val: "Transport"),
        DropdownOption(key: TRANS_TAG_FOOD, val: "Food"),
        DropdownOption(key: TRANS_TAG_HOUSING, val: "Housing"),
        DropdownOption(key: TRANS_TAG_INSURANCE, val: "Insurance"),
        DropdownOption(key: TRANS_TAG_MEDICAL, val: "Medical"),
        DropdownOption(key: TRANS_TAG_SAVINGS, val: "Savings"),
        DropdownOption(key: TRANS_TAG_PERSONAL, val: "Personal"),
        DropdownOption(key: TRANS_TAG_ENTERTAINMENT, val: "Entertainment"),
        DropdownOption(key: TRANS_TAG_OTHERS, val: "Others"),
        DropdownOption(key: TRANS_TAG_UTILITIES, val: "Utilities"),
        DropdownOption(key: TRANS_TAG_CAR, val: "Car")
    ]
    let haptics = HapticsHelper.shared
    
    var body: some View {
        NavigationView {
            VStack {
                ScrollView(showsIndicators: false) {
                    TextField("Title", text: $viewModel.title)
                        .promptFrameAndBackground(maxHeight: 55)
                        .padding(.top, 25)
                    
                    TextField("Amount", text: $viewModel.amount)
                        .keyboardType(.decimalPad)
                        .promptFrameAndBackground(maxHeight: 55)
                        .padding(.bottom, 25)
                    
                    // Type Picker
                    HStack {
                        Text("Type")
                        Spacer()
                        Picker("Type", selection: $viewModel.selectedType) {
                            ForEach(typeOptions, id: \.key) { option in
                                Text(option.val).tag(option.key)
                            }
                        }
                        .onChange(of: viewModel.selectedType) { newKey in
                            if let selectedObj = typeOptions.first(where: { $0.key == newKey }) {
                                viewModel.typeTitle = selectedObj.val
                            }
                        }
                    }
                    .promptFrameAndBackground(maxHeight: 50)
                    
                    // Tag Picker
                    HStack {
                        Text("Tag")
                        Spacer()
                        Picker("Tag", selection: $viewModel.selectedTag) {
                            ForEach(tagOptions, id: \.key) { option in
                                Text(option.val).tag(option.key)
                            }
                        }
                        .onChange(of: viewModel.selectedTag) { newKey in
                            if let selectedObj = tagOptions.first(where: { $0.key == newKey }) {
                                viewModel.tagTitle = selectedObj.val
                            }
                        }
                    }
                    .promptFrameAndBackground(maxHeight: 50)
                    
                    HStack {
                        Text("Date")
                        Spacer()
                        DatePicker("PickerView", selection: $viewModel.occuredOn,
                                   displayedComponents: [.date, .hourAndMinute]).labelsHidden()
                    }
                    .promptFrameAndBackground(maxHeight: 50)
                    .padding(.bottom, 25)
                    
                    TextField("Note", text: $viewModel.note)
                        .promptFrameAndBackground(maxHeight: 50)
                    
                    Button(action: { viewModel.attachImage() }) {
                        HStack {
                            Image(systemName: "paperclip")
                            Text("Attach an image")
                        }
                    }
                    .promptFrameAndBackground(maxHeight: 50)
                    .contentShape(Rectangle())
                    .actionSheet(isPresented: $showAttachSheet) {
                        ActionSheet(title: Text("Do you want to remove the attachment?"), buttons: [
                            .default(Text("Remove")) { viewModel.removeImage() },
                            .cancel()
                        ])
                    }
                    
                    if let image = viewModel.imageAttached {
                        Button(action: { showAttachSheet = true }, label: {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(height: 250).frame(maxWidth: .infinity)
                                .background(Color.secondary_color)
                                .cornerRadius(4)
                        })
                    }
                }
                .dismissKeyboardOnTap()
                
                Button(action: {
                    haptics.hardButtonTap()
                    viewModel.saveTransaction(managedObjectContext: managedObjectContext)
                }) {
                    Text(viewModel.getButtText())
                }
                .buttonStyle(CapsuleButtonStyle())
                .padding()
            }
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    Button {
                        haptics.mediumButtonTap()
                        self.presentationMode.wrappedValue.dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
            .navigationTitle("💸 \(viewModel.getButtText())")
        }
        .onReceive(viewModel.$closePresenter) { close in
            if close { self.presentationMode.wrappedValue.dismiss() }
        }
        .alert(isPresented: $confirmDelete,
               content: {
            Alert(title: Text(APP_NAME), message: Text("Are you sure you want to delete this transaction?"),
                  primaryButton: .destructive(Text("Delete")) {
                viewModel.deleteTransaction(managedObjectContext: self.managedObjectContext)
            }, secondaryButton: Alert.Button.cancel(Text("Cancel"), action: { confirmDelete = false })
            )
        })
        .alert(isPresented: $viewModel.showAlert,
               content: { Alert(title: Text(APP_NAME), message: Text(viewModel.alertMsg), dismissButton: .default(Text("OK"))) })
    }
}

//struct AddExpenseView_Previews: PreviewProvider {
//    static var previews: some View {
//        AddExpenseView()
//    }
//}
