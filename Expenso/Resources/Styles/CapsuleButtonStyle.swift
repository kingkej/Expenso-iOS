//
//  Styles.swift
//  Expenso
//
//  Created by Vadim on 11/20/24.
//
import Foundation
import SwiftUI

struct CapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let isIpad = UIDevice.current.userInterfaceIdiom == .pad
        return configuration.label
            .frame(maxWidth: isIpad ? 700 : 343, maxHeight: 20)
            .padding()
            .background(Color.blue)
            .foregroundColor(.white)
            .clipShape(Capsule())
    }
}
