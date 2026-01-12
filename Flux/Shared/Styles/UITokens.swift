import SwiftUI

enum UITokens {
    enum Radius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 10
        static let large: CGFloat = 12
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
    }

    enum Animation {
        static let hover = SwiftUI.Animation.easeInOut(duration: 0.2)
        static let transition = SwiftUI.Animation.spring(response: 0.3, dampingFraction: 0.7)
    }

    static let sidebarWidth: CGFloat = 260
    static let minWindowWidth: CGFloat = 800
    static let minWindowHeight: CGFloat = 600
}
