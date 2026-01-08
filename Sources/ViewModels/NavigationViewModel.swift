import SwiftUI

@MainActor
final class NavigationViewModel: ObservableObject {
    @Published var selection: SidebarItem? = .overview
}
