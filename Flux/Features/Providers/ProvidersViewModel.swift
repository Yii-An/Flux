import Foundation
import Observation

@Observable
@MainActor
final class ProvidersViewModel {
    typealias ProviderAuthState = AuthFileReader.ProviderAuthState

    struct ProviderGroup: Identifiable, Hashable {
        var id: ProviderID { providerID }
        let providerID: ProviderID
        let name: String
        let credentialCount: Int
        let authState: ProviderAuthState
    }

    var authStates: [ProviderID: ProviderAuthState] = [:]
    var expandedStates: [ProviderID: Bool] = Dictionary(uniqueKeysWithValues: ProviderID.allCases.map { ($0, true) })
    var isRefreshing: Bool = false
    var errorMessage: String?
    var lastUpdatedAt: Date?

    private let authFileReader: AuthFileReader

    init(authFileReader: AuthFileReader = .shared) {
        self.authFileReader = authFileReader
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        errorMessage = nil
        ensureExpandedDefaults()

        var authStates: [ProviderID: ProviderAuthState] = [:]
        await withTaskGroup(of: (ProviderID, ProviderAuthState).self) { group in
            for provider in ProviderID.allCases {
                group.addTask { [authFileReader] in
                    let state = await authFileReader.authState(for: provider)
                    return (provider, state)
                }
            }

            for await (provider, state) in group {
                authStates[provider] = state
            }
        }

        self.authStates = authStates
        lastUpdatedAt = Date()
    }

    func groupedProviders() -> [ProviderGroup] {
        ProviderID.allCases.map { provider in
            let auth = authState(for: provider)
            return ProviderGroup(
                providerID: provider,
                name: provider.displayName,
                credentialCount: credentialCount(for: auth),
                authState: auth
            )
        }
    }

    func authState(for provider: ProviderID) -> ProviderAuthState {
        authStates[provider] ?? .missing
    }

    func isExpanded(_ provider: ProviderID) -> Bool {
        expandedStates[provider] ?? true
    }

    func setExpanded(_ expanded: Bool, for provider: ProviderID) {
        expandedStates[provider] = expanded
    }

    private func ensureExpandedDefaults() {
        for provider in ProviderID.allCases where expandedStates[provider] == nil {
            expandedStates[provider] = true
        }
    }

    private func credentialCount(for state: ProviderAuthState) -> Int {
        switch state {
        case .available:
            return 1
        case .missing, .unsupported, .error:
            return 0
        }
    }
}
