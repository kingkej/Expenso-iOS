import Foundation

enum PaymentMethod: String, CaseIterable, Sendable {
    case card
    case crypto
    case cash

    var title: String {
        switch self {
        case .card: return "Card"
        case .crypto: return "Crypto"
        case .cash: return "Cash"
        }
    }
}
