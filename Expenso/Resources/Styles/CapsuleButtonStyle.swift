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
}

func transactionSymbol(for tag: String) -> String {
    CategoryCatalog.symbol(for: tag)
}
