import SwiftUI

enum TextView_Type {
    case h1, h2, h3, h4, h5, h6
    case subtitle_1, subtitle_2, body_1, body_2, button, caption, overline

    var font: Font {
        switch self {
        case .h1, .h2, .h3, .h4: return .largeTitle.weight(.bold)
        case .h5: return .title.weight(.semibold)
        case .h6: return .title2.weight(.semibold)
        case .subtitle_1: return .headline
        case .subtitle_2: return .subheadline.weight(.semibold)
        case .body_1: return .body
        case .body_2: return .subheadline
        case .button: return .headline
        case .caption: return .caption
        case .overline: return .caption.weight(.semibold)
        }
    }
}

struct TextView: View {
    var text: String
    var type: TextView_Type
    var lineLimit: Int = 0
    var body: some View {
        Text(text).font(type.font).lineLimit(lineLimit == 0 ? nil : lineLimit)
    }
}
