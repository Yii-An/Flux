import Foundation
import Observation

@Observable
@MainActor
final class QuotaViewModel {
    var snapshots: [ProviderID: QuotaSnapshot] = [:]
    var providerSnapshots: [ProviderID: ProviderQuotaSnapshot] = [:]
    var lastRefreshAt: Date?
    var isRefreshing: Bool = false
    var errorMessage: String?

    private let quotaAggregator: QuotaAggregator

    init(quotaAggregator: QuotaAggregator = .shared) {
        self.quotaAggregator = quotaAggregator
    }

    func loadCached() async {
        snapshots = await quotaAggregator.allSnapshots()
        providerSnapshots = await quotaAggregator.allProviderSnapshots()
    }

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        snapshots = await quotaAggregator.refreshAll()
        providerSnapshots = await quotaAggregator.allProviderSnapshots()
        lastRefreshAt = Date()
    }

    func visibleProviders() -> [ProviderID] {
        ProviderID.allCases.filter(\.descriptor.supportsQuota)
    }
}
