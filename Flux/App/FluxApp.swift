import SwiftUI

@main
struct FluxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var currentPage: NavigationPage = .dashboard

    var body: some Scene {
        WindowGroup {
            FluxRootView(currentPage: $currentPage)
        }
        Settings {
            EmptyView()
        }
    }
}
