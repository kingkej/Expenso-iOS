//
//  DismissKeyboard.swift
//  Expenso
//
//  Created by Sameer Nawaz on 31/01/21.
//

import SwiftUI

public extension View {
    func dismissKeyboardOnTap() -> some View {
        modifier(DismissKeyboardOnTap())
    }
}

public struct DismissKeyboardOnTap: ViewModifier {
    
    public func body(content: Content) -> some View {
        #if os(macOS)
        return content
        #else
        return content.background(KeyboardDismissObserver().allowsHitTesting(false))
        #endif
    }
    
}

#if !os(macOS)
/// Observe outside taps without consuming button actions or the text editor's
/// selection and paste gestures. The observer follows its actual scene window.
private struct KeyboardDismissObserver: UIViewRepresentable {
    func makeUIView(context: Context) -> ObserverView { ObserverView() }
    func updateUIView(_ uiView: ObserverView, context: Context) { }
    static func dismantleUIView(_ uiView: ObserverView, coordinator: ()) { uiView.detach() }

    final class ObserverView: UIView, UIGestureRecognizerDelegate {
        private weak var observedWindow: UIWindow?
        private lazy var outsideTap: UITapGestureRecognizer = {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            return recognizer
        }()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            guard let window else { return }
            observedWindow = window
            window.addGestureRecognizer(outsideTap)
        }

        func detach() {
            observedWindow?.removeGestureRecognizer(outsideTap)
            observedWindow = nil
        }

        @objc private func dismissKeyboard() { observedWindow?.endEditing(true) }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var touchedView = touch.view
            var containsControl = false
            var isNavigationTitle = false
            while let view = touchedView {
                if view is UITextField || view is UITextView || view is UIButton { return false }
                if view is UIControl { containsControl = true }
                if view is UINavigationBar { isNavigationTitle = true }
                touchedView = view.superview
            }
            // Navigation titles are controls too, but act as an outside area.
            // Other controls (including native edit-menu actions) keep their
            // responder until their own action finishes.
            return !containsControl || isNavigationTitle
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
}
#endif
