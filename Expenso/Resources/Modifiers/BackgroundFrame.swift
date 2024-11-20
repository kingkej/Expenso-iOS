//
//  BackgroundFrame.swift
//  Expenso
//
//  Created by Vadim on 11/20/24.
//
import SwiftUI
import Foundation

struct FrameAndBackgroundModifier: ViewModifier {
    let isIpad = UIDevice.current.userInterfaceIdiom == .pad
    let cornerRadius: CGFloat
    let maxWidth: CGFloat
    let maxHeight: CGFloat
    
    var optimizedMaxWidth: CGFloat {
        if !isIpad {
            return maxWidth
        } else {
            return maxWidth * 2
        }
    }
    
    var optimizedMaxHeight: CGFloat {
        if !isIpad {
            return maxHeight
        } else {
            return maxHeight * 2
        }
    }

    func body(content: Content) -> some View {
        content
            .padding()
            .frame(maxWidth: optimizedMaxWidth, maxHeight: optimizedMaxHeight)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension View {
    func promptFrameAndBackground(maxWidth: CGFloat = 330, maxHeight: CGFloat = 100, cornerRadius: CGFloat = 25) -> some View {
        self.modifier(FrameAndBackgroundModifier(cornerRadius: cornerRadius, maxWidth: maxWidth, maxHeight: maxHeight))
    }
}
