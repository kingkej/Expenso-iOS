//
//  AuthenticationViewModel.swift
//  Expenso
//
//  Created by Waseem Akram on 06/03/21.
//

import Foundation
import Combine

class AuthenticationViewModel: ObservableObject {
    
    var cancellableBiometricTask: AnyCancellable? = nil
    
    @Published var didAuthenticate = false
    @Published var showAlert = false
    @Published var alertMessage = String()
        
    func authenticate(){
        didAuthenticate = false
        showAlert = false
        alertMessage = ""
        cancellableBiometricTask = BiometricAuthUtlity.shared.authenticate()
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { completion in
                switch completion {
                case .failure(let error):
                    self.alertMessage = error.description
                    self.showAlert = true
                default: return
                }
            }) { _ in
                self.didAuthenticate = true
            }
    }
    
    deinit {
        cancellableBiometricTask = nil
    }
}
