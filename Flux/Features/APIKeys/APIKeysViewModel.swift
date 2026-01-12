import Foundation
import Observation

@Observable
@MainActor
final class APIKeysViewModel {
    struct ProviderKeyStatus: Hashable, Sendable {
        var isSet: Bool
        var maskedDisplay: String?
        var last4: String?

        init(isSet: Bool = false, maskedDisplay: String? = nil, last4: String? = nil) {
            self.isSet = isSet
            self.maskedDisplay = maskedDisplay
            self.last4 = last4
        }
    }

    var coreState: CoreRuntimeState = .stopped
    var statuses: [ProviderID: ProviderKeyStatus] = [:]
    var isRefreshing: Bool = false
    var errorMessage: String?

    private let coreManager: CoreManager
    private let keychainStore: KeychainStore

    init(coreManager: CoreManager = .shared, keychainStore: KeychainStore = .shared) {
        self.coreManager = coreManager
        self.keychainStore = keychainStore
    }

    func apiKeyProviders() -> [ProviderID] {
        ProviderID.allCases.filter { $0.descriptor.authKind == .apiKey }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        errorMessage = nil
        coreState = await coreManager.state()

        var statuses: [ProviderID: ProviderKeyStatus] = [:]
        for provider in apiKeyProviders() {
            do {
                let key = try await keychainStore.getProviderAPIKey(for: provider)
                let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let trimmed, !trimmed.isEmpty {
                    statuses[provider] = ProviderKeyStatus(
                        isSet: true,
                        maskedDisplay: maskKey(trimmed),
                        last4: String(trimmed.suffix(4))
                    )
                } else {
                    statuses[provider] = ProviderKeyStatus(isSet: false, maskedDisplay: nil, last4: nil)
                }
            } catch {
                statuses[provider] = ProviderKeyStatus(isSet: false, maskedDisplay: nil, last4: nil)
                errorMessage = String(describing: error)
            }
        }

        self.statuses = statuses
    }

    func startCore() async {
        await coreManager.start()
        await refresh()
    }

    func setProviderAPIKey(_ apiKey: String, for provider: ProviderID) async {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            try await keychainStore.setProviderAPIKey(trimmed, for: provider)
            statuses[provider] = ProviderKeyStatus(isSet: true, maskedDisplay: maskKey(trimmed), last4: String(trimmed.suffix(4)))
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func deleteProviderAPIKey(for provider: ProviderID) async {
        do {
            try await keychainStore.deleteProviderAPIKey(for: provider)
            statuses[provider] = ProviderKeyStatus(isSet: false, maskedDisplay: nil, last4: nil)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func copyProviderAPIKey(for provider: ProviderID) async {
        errorMessage = nil

        do {
            let key = try await keychainStore.getProviderAPIKey(for: provider)
            guard let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                errorMessage = "API key is not set.".localizedStatic()
                return
            }
            Pasteboard.copy(key)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func status(for provider: ProviderID) -> ProviderKeyStatus {
        statuses[provider] ?? ProviderKeyStatus()
    }

    private func maskKey(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let hasSKPrefix = trimmed.hasPrefix("sk-")
        let body = hasSKPrefix ? String(trimmed.dropFirst(3)) : trimmed
        let visiblePrefix = String(body.prefix(4))
        let obscured = "••••••••••••••••"

        if hasSKPrefix {
            return "sk-\(visiblePrefix)\(obscured)"
        }

        return "\(visiblePrefix)\(obscured)"
    }
}
