import SwiftUI

@main
struct FluxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var currentPage: NavigationPage = .dashboard

    var body: some Scene {
        Window("Flux", id: "main") {
            FluxRootView(currentPage: $currentPage)
        }
        .defaultPosition(.center)
        .defaultSize(width: 980, height: 720)
        Settings {
            EmptyView()
        }
    }
}
