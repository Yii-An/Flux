import SwiftUI

@MainActor
final class AppViewModel: ObservableObject {
    @Published var isProxyRunning = false
}
