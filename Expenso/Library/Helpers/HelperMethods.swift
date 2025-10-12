//
//  HelperMethods.swift
//  Expenso
//
//  Created by Sameer Nawaz on 31/01/21.
//

import UIKit

public func keyboardEndEditing() {
    UIApplication.shared.connectedScenes
        .filter {$0.activationState == .foregroundActive}
        .map {$0 as? UIWindowScene}
        .compactMap({$0})
        .first?.windows
        .filter {$0.isKeyWindow}
        .first?.endEditing(true)
}

public func topMostViewController(base: UIViewController? = {
    if let scene = UIApplication.shared.connectedScenes
        .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
       let window = scene.windows.first(where: { $0.isKeyWindow }) {
        return window.rootViewController
    }
    return UIApplication.shared.windows.first?.rootViewController
}()) -> UIViewController? {
    if let nav = base as? UINavigationController {
        return topMostViewController(base: nav.visibleViewController)
    }
    if let tab = base as? UITabBarController, let selected = tab.selectedViewController {
        return topMostViewController(base: selected)
    }
    if let presented = base?.presentedViewController {
        return topMostViewController(base: presented)
    }
    return base
}
