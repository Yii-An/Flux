import Foundation
import Observation

@Observable
@MainActor
final class QuotaViewModel {
    var snapshots: [ProviderID: QuotaSnapshot] = [:]
    var providerSnapshots: [ProviderID: ProviderQuotaSnapshot] = [:]
    var lastRefreshAt: Date?
    var isRefreshingAll: Bool = false
    var refreshingProviders: Set<ProviderID> = []
    var refreshingAccounts: [ProviderID: Set<String>] = [:]
    var errorMessage: String?

    private let quotaAggregator: QuotaAggregator

    init(quotaAggregator: QuotaAggregator = .shared) {
        self.quotaAggregator = quotaAggregator
    }

    var isRefreshingAny: Bool {
        if isRefreshingAll { return true }
        if refreshingProviders.isEmpty == false { return true }
        return refreshingAccounts.values.contains(where: { $0.isEmpty == false })
    }

    func isRefreshingAccount(_ provider: ProviderID, _ accountKey: String) -> Bool {
        refreshingAccounts[provider]?.contains(accountKey) == true
    }

    func loadCached() async {
        snapshots = await quotaAggregator.allSnapshots()
        providerSnapshots = await quotaAggregator.allProviderSnapshots()
    }

    func refreshAll() async {
        await refreshAll(force: false)
    }

    func refreshAll(force: Bool) async {
        guard !isRefreshingAll else { return }
        isRefreshingAll = true

        let supportedProviders = ProviderID.allCases.filter(\.descriptor.supportsQuota)
        let newlyRefreshing = Set(supportedProviders).subtracting(refreshingProviders)
        refreshingProviders.formUnion(newlyRefreshing)

        defer {
            isRefreshingAll = false
            refreshingProviders.subtract(newlyRefreshing)
        }

        snapshots = await quotaAggregator.refreshAll(force: force)
        providerSnapshots = await quotaAggregator.allProviderSnapshots()
        lastRefreshAt = Date()
    }

    func refreshProvider(_ provider: ProviderID, force: Bool = false) async {
        guard isRefreshingAll == false else { return }
        guard refreshingProviders.contains(provider) == false else { return }
        refreshingProviders.insert(provider)
        defer { refreshingProviders.remove(provider) }

        snapshots[provider] = await quotaAggregator.refresh(provider: provider, force: force)
        providerSnapshots = await quotaAggregator.allProviderSnapshots()
        lastRefreshAt = Date()
    }

    func refreshAccount(_ provider: ProviderID, accountKey: String, force: Bool = true) async {
        guard isRefreshingAll == false else { return }
        guard refreshingProviders.contains(provider) == false else { return }
        guard isRefreshingAccount(provider, accountKey) == false else { return }

        refreshingAccounts[provider, default: []].insert(accountKey)
        defer {
            refreshingAccounts[provider]?.remove(accountKey)
            if refreshingAccounts[provider]?.isEmpty == true {
                refreshingAccounts[provider] = nil
            }
        }

        _ = await quotaAggregator.refreshAccount(provider: provider, accountKey: accountKey, force: force)
        providerSnapshots = await quotaAggregator.allProviderSnapshots()
        snapshots = await quotaAggregator.allSnapshots()
        lastRefreshAt = Date()
    }

    func visibleProviders() -> [ProviderID] {
        ProviderID.allCases.filter(\.descriptor.supportsQuota)
    }
}
