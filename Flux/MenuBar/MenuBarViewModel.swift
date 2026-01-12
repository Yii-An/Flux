import Foundation
import Observation

@Observable
@MainActor
final class MenuBarViewModel {
    struct QuotaItem: Identifiable, Hashable {
        var id: ProviderID { providerID }
        let providerID: ProviderID
        let snapshot: QuotaSnapshot
    }

    var quotaItems: [QuotaItem] = []
    var isLoading: Bool = false
    var totalUsedDisplay: String = "—"

    private let quotaAggregator: QuotaAggregator

    private var didLoad: Bool = false

    init(quotaAggregator: QuotaAggregator = .shared) {
        self.quotaAggregator = quotaAggregator
    }

    func load() async {
        guard !didLoad else { return }
        didLoad = true

        await loadCached()
        await refresh()
    }

    func loadCached() async {
        let snapshots = await quotaAggregator.allSnapshots()
        apply(snapshots: snapshots)
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let snapshots = await quotaAggregator.refreshAll()
        apply(snapshots: snapshots)
    }

    private func apply(snapshots: [ProviderID: QuotaSnapshot]) {
        let providers = ProviderID.allCases.filter(\.descriptor.supportsQuota)

        quotaItems = providers.map { provider in
            let snapshot = snapshots[provider] ?? QuotaSnapshot(provider: provider, kind: .loading, message: "Not loaded".localizedStatic())
            return QuotaItem(providerID: provider, snapshot: snapshot)
        }

        totalUsedDisplay = headerSummary(for: quotaItems)
    }

    private func headerSummary(for items: [QuotaItem]) -> String {
        let total = items.count
        guard total > 0 else { return "—" }
        let ok = items.filter { $0.snapshot.kind == .ok }.count
        return "\(ok)/\(total)"
    }
}
