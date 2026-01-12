import Foundation

enum FluxNavigation {
    static let notification = Notification.Name("FluxNavigation.Navigate")
    static let pageUserInfoKey = "page"

    static func navigate(to page: NavigationPage) {
        NotificationCenter.default.post(
            name: notification,
            object: nil,
            userInfo: [pageUserInfoKey: page.rawValue]
        )
    }
}

