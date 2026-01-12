import SwiftUI

extension Font {
    static func dinBold(size: CGFloat) -> Font {
        .custom("DIN-Bold", size: size)
    }

    static func dinBold(size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
        .custom("DIN-Bold", size: size, relativeTo: style)
    }

    static func dinNumber(_ style: Font.TextStyle) -> Font {
        switch style {
        case .largeTitle:
            return dinBold(size: 34, relativeTo: style)
        case .title:
            return dinBold(size: 28, relativeTo: style)
        case .title2:
            return dinBold(size: 22, relativeTo: style)
        case .title3:
            return dinBold(size: 20, relativeTo: style)
        case .headline:
            return dinBold(size: 17, relativeTo: style)
        case .subheadline:
            return dinBold(size: 15, relativeTo: style)
        case .body:
            return dinBold(size: 17, relativeTo: style)
        case .callout:
            return dinBold(size: 16, relativeTo: style)
        case .footnote:
            return dinBold(size: 13, relativeTo: style)
        case .caption:
            return dinBold(size: 12, relativeTo: style)
        case .caption2:
            return dinBold(size: 11, relativeTo: style)
        @unknown default:
            return dinBold(size: 17, relativeTo: .body)
        }
    }
}

