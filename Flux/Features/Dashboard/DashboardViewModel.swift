import Foundation
import Observation

@Observable
@MainActor
final class DashboardViewModel {
    var coreState: CoreRuntimeState = .stopped
    var coreVersion: String?
    var coreStartedAt: Date?
    var corePort: UInt16 = 0

    var quotaProvidersCount: Int = 0
    var credentialsAvailableCount: Int = 0
    var quotaOKCount: Int = 0
    var quotaProvidersTrend: MetricTrend = .flat
    var credentialsAvailableTrend: MetricTrend = .flat
    var quotaOKTrend: MetricTrend = .flat
    var lastRefreshAt: Date?

    var quotaPressure: Double = 0
    var providerStats: (ok: Int, warn: Int, error: Int) = (0, 0, 0)
    var riskyProviders: [QuotaRiskItem] = []
    var systemAlerts: [String] = []
    var installedAgentsCount: Int = 0
    var providerItems: [ProviderStatusItem] = []
    var agentItems: [AgentIntegrationItem] = []

    var isRefreshing: Bool = false
    var errorMessage: String?

    private let authFileReader: AuthFileReader
    private let quotaAggregator: QuotaAggregator
    private let coreManager: CoreManager
    private let agentDiscoveryService: AgentDiscoveryService

    init(
        authFileReader: AuthFileReader = .shared,
        quotaAggregator: QuotaAggregator = .shared,
        coreManager: CoreManager = .shared,
        agentDiscoveryService: AgentDiscoveryService = .shared
    ) {
        self.authFileReader = authFileReader
        self.quotaAggregator = quotaAggregator
        self.coreManager = coreManager
        self.agentDiscoveryService = agentDiscoveryService
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        await refreshCoreMetadata()

        let previousQuotaProvidersCount = quotaProvidersCount
        let previousCredentialsAvailableCount = credentialsAvailableCount
        let previousQuotaOKCount = quotaOKCount

        let quotaProviders = ProviderID.allCases.filter(\.descriptor.supportsQuota)
        quotaProvidersCount = quotaProviders.count

        var availableCount = 0
        await withTaskGroup(of: Bool.self) { group in
            for provider in quotaProviders {
                group.addTask { [authFileReader] in
                    let state = await authFileReader.authState(for: provider)
                    if case .available = state { return true }
                    return false
                }
            }
            for await isAvailable in group {
                if isAvailable { availableCount += 1 }
            }
        }
        credentialsAvailableCount = availableCount

        let snapshots = await quotaAggregator.refreshAll()

        var quotaOKCountLocal = 0
        var providerStatsLocal = (ok: 0, warn: 0, error: 0)
        var riskyProvidersLocal: [QuotaRiskItem] = []
        var maxPercentUsed: Double = 0
        var providerItemsLocal: [ProviderStatusItem] = []

        for provider in quotaProviders {
            let snapshot = snapshots[provider]

            if let snapshot {
                providerItemsLocal.append(ProviderStatusItem(
                    providerID: provider,
                    kind: snapshot.kind,
                    percentUsed: nil,
                    message: snapshot.message
                ))

                if snapshot.kind == .ok {
                    quotaOKCountLocal += 1

                    if let metrics = snapshot.metrics {
                        var percentUsed: Double?

                        if let used = metrics.used, let limit = metrics.limit, limit > 0 {
                            percentUsed = Double(used) / Double(limit)
                        } else if let remaining = metrics.remaining, let limit = metrics.limit, limit > 0 {
                            percentUsed = 1 - Double(remaining) / Double(limit)
                        }

                        if let percent = percentUsed {
                            if let index = providerItemsLocal.firstIndex(where: { $0.providerID == provider }) {
                                providerItemsLocal[index] = ProviderStatusItem(
                                    providerID: provider,
                                    kind: snapshot.kind,
                                    percentUsed: percent,
                                    message: snapshot.message
                                )
                            }

                            if percent >= 0.85 {
                                providerStatsLocal.warn += 1
                            } else {
                                providerStatsLocal.ok += 1
                            }

                            if percent > maxPercentUsed {
                                maxPercentUsed = percent
                            }

                            var remaining: Int? = metrics.remaining
                            if remaining == nil, let used = metrics.used, let limit = metrics.limit {
                                remaining = limit - used
                            }

                            riskyProvidersLocal.append(QuotaRiskItem(
                                providerID: provider,
                                displayNameKey: provider.descriptor.displayNameKey,
                                percentUsed: percent,
                                used: metrics.used,
                                limit: metrics.limit,
                                remaining: remaining,
                                resetAt: metrics.resetAt
                            ))
                        } else {
                            providerStatsLocal.ok += 1
                        }
                    }
                } else if snapshot.kind == .authMissing {
                    providerStatsLocal.warn += 1
                } else if snapshot.kind == .error {
                    providerStatsLocal.error += 1
                }
            } else {
                providerItemsLocal.append(ProviderStatusItem(
                    providerID: provider,
                    kind: .loading,
                    percentUsed: nil,
                    message: nil
                ))
            }
        }

        quotaOKCount = quotaOKCountLocal
        providerStats = providerStatsLocal
        riskyProviders = riskyProvidersLocal.sorted { $0.percentUsed > $1.percentUsed }.prefix(3).map { $0 }
        quotaPressure = maxPercentUsed

        quotaProvidersTrend = trend(for: quotaProvidersCount, comparedTo: previousQuotaProvidersCount)
        credentialsAvailableTrend = trend(for: credentialsAvailableCount, comparedTo: previousCredentialsAvailableCount)
        quotaOKTrend = trend(for: quotaOKCount, comparedTo: previousQuotaOKCount)
        lastRefreshAt = Date()

        var alerts: [String] = []

        if case .notInstalled = coreState {
            alerts.append("Core is not installed")
        } else if !coreState.isRunning {
            alerts.append("Core is not running")
        }

        if providerStats.error > 0 {
            alerts.append("Some providers failed to fetch quota")
        }

        if quotaPressure >= 0.90 {
            alerts.append("Quota is almost exhausted")
        }

        if providerStats.warn > 0 {
            alerts.append("Some providers need attention")
        }

        systemAlerts = alerts

        let agentStatuses = await agentDiscoveryService.detectAll(forceRefresh: false)
        installedAgentsCount = agentStatuses.values.filter { $0.isInstalled }.count
        agentItems = AgentID.allCases.map { agentID in
            let status = agentStatuses[agentID]
            return AgentIntegrationItem(
                agentID: agentID,
                isInstalled: status?.isInstalled ?? false,
                version: status?.version
            )
        }

        providerItems = providerItemsLocal.sorted { lhs, rhs in
            let l = severity(for: lhs.kind)
            let r = severity(for: rhs.kind)
            if l != r { return l > r }
            return lhs.providerID.rawValue < rhs.providerID.rawValue
        }
    }

    func toggleCore() async {
        await refreshCoreMetadata()
        if coreState.isRunning {
            await coreManager.stop()
        } else {
            await coreManager.start()
        }
        await refreshCoreMetadata()
    }

    private func refreshCoreMetadata() async {
        coreState = await coreManager.state()
        coreStartedAt = await coreManager.startedAtDate()
        coreVersion = (try? await CoreVersionManager.shared.activeVersion())?.version
        corePort = await coreManager.port()
    }

    private func trend(for value: Int, comparedTo previous: Int) -> MetricTrend {
        if value > previous { return .up }
        if value < previous { return .down }
        return .flat
    }

    private func severity(for kind: QuotaSnapshotKind) -> Int {
        switch kind {
        case .error:
            return 3
        case .authMissing:
            return 2
        case .ok:
            return 1
        case .loading, .unsupported:
            return 0
        }
    }
}
