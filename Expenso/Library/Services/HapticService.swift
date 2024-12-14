//
//  HapticService.swift
//  Expenso
//
//  Created by Vadim on 12/12/24.
//
import Foundation
import SwiftUI


enum HapticsIntensity: CGFloat {
    case buttonTapLight = 0.3
    case buttonTapMedium = 0.4
    case buttonTapHard = 0.5
    case cellTap = 0.2
    case barButtonTap = 0.25
    case segmentValueChange = 0.45
}

class HapticsHelper {
    private let impactFeedbackGenerator = UIImpactFeedbackGenerator()
    private let notificationFeedbackGenerator = UINotificationFeedbackGenerator()
    static let shared = HapticsHelper()

    init() {
        impactFeedbackGenerator.prepare()
        notificationFeedbackGenerator.prepare()
    }

    func lightButtonTap() {
        impactFeedbackGenerator.impactOccurred(intensity: HapticsIntensity.buttonTapLight.rawValue)
    }

    func mediumButtonTap() {
        impactFeedbackGenerator.impactOccurred(intensity: HapticsIntensity.buttonTapMedium.rawValue)
    }

    func hardButtonTap() {
        impactFeedbackGenerator.impactOccurred(intensity: HapticsIntensity.buttonTapHard.rawValue)
    }

    func cellTap() {
        impactFeedbackGenerator.impactOccurred(intensity: HapticsIntensity.cellTap.rawValue)
    }

    func barButtonTap() {
        impactFeedbackGenerator.impactOccurred(intensity: HapticsIntensity.barButtonTap.rawValue)
    }

    func segmentChangedValue() {
        impactFeedbackGenerator.impactOccurred(intensity: HapticsIntensity.segmentValueChange.rawValue)
    }

    func success() {
        notificationFeedbackGenerator.notificationOccurred(.success)
    }

    func warning() {
        notificationFeedbackGenerator.notificationOccurred(.warning)
    }

    func error() {
        notificationFeedbackGenerator.notificationOccurred(.error)
    }
}
