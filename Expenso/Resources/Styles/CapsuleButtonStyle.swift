import SwiftUI

struct CapsuleButtonStyle: ButtonStyle {
    @Environment(\.appAccentColor) private var accentColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding().frame(maxWidth: .infinity)
            .background(accentColor).foregroundStyle(.white).clipShape(.capsule)
    }
}

struct PrimaryActionStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.buttonStyle(.glassProminent).buttonBorderShape(.capsule).controlSize(.large)
        } else {
            content.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
        }
    }
}

extension View {
    func primaryActionStyle() -> some View { modifier(PrimaryActionStyle()) }
    func expenseSheetStyle() -> some View {
        presentationDetents([.fraction(0.8), .large]).presentationDragIndicator(.visible)
    }
}

func transactionSymbol(for tag: String) -> String {
    switch tag {
    case TRANS_TAG_TRANSPORT: return "tram.fill"
    case TRANS_TAG_FOOD: return "fork.knife"
    case TRANS_TAG_HOUSING: return "house.fill"
    case TRANS_TAG_INSURANCE: return "shield.fill"
    case TRANS_TAG_MEDICAL: return "cross.case.fill"
    case TRANS_TAG_SAVINGS: return "banknote.fill"
    case TRANS_TAG_PERSONAL: return "person.fill"
    case TRANS_TAG_ENTERTAINMENT: return "popcorn.fill"
    case TRANS_TAG_UTILITIES: return "bolt.fill"
    case TRANS_TAG_CAR: return "car.fill"
    case TRANS_TAG_TRAVEL: return "airplane"
    default: return "square.grid.2x2.fill"
    }
}
