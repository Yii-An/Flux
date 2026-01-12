import SwiftUI

struct FluxRootContainerView: View {
    @State private var currentPage: NavigationPage

    init(initialPage: NavigationPage = .dashboard) {
        _currentPage = State(initialValue: initialPage)
    }

    var body: some View {
        FluxRootView(currentPage: $currentPage)
    }
}
