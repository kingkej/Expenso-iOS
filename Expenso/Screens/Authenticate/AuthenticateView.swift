//
//  AuthenticateView.swift
//  Expenso
//
//  Created by Sameer Nawaz on 16/02/21.
//

import SwiftUI

struct AuthenticateView: View {
    @StateObject private var viewModel = AuthenticationViewModel()
    @State private var didRequestAuthentication = false

    var body: some View {
        Group {
            if viewModel.didAuthenticate {
                ExpensoTabView()
            } else {
                NavigationStack {
                    ScrollView {
                        ContentUnavailableView {
                            Label("\(APP_NAME) is Locked", systemImage: "lock.shield.fill")
                        } description: {
                            Text("Authenticate to view your transactions.")
                        } actions: {
                            Button("Unlock", systemImage: "lock.open") {
                                viewModel.authenticate()
                            }
                            .primaryActionStyle()
                            .controlSize(.large)
                        }
                        .padding(.vertical, 48)
                    }
                    .background(Color(uiColor: .systemGroupedBackground))
                    .navigationTitle(APP_NAME)
                    .navigationBarTitleDisplayMode(.inline)
                    .alert("Unable to Unlock", isPresented: $viewModel.showAlert) {
                        Button("OK", role: .cancel) { }
                    } message: {
                        Text(viewModel.alertMessage)
                    }
                }
            }
        }
        .onAppear {
            guard !didRequestAuthentication, !viewModel.didAuthenticate else { return }
            didRequestAuthentication = true
            viewModel.authenticate()
        }
    }
}

struct AuthenticateView_Previews: PreviewProvider {
    static var previews: some View {
        AuthenticateView()
    }
}
