import Foundation

actor QuotaAggregator {
    static let shared = QuotaAggregator()

    private let settingsStore: SettingsStore
    private let logger: FluxLogger

    private var cache: [ProviderID: [String: AccountQuota]] = [:]
    private var lastRefresh: Date?
    private var lastProviderRefresh: [ProviderID: Date] = [:]
    private var lastAccountRefresh: [ProviderID: [String: Date]] = [:]

    private var refreshIntervalSeconds: Int = 60

    private let minProviderRefreshInterval: TimeInterval = 30
    private let minAccountRefreshInterval: TimeInterval = 5
    private let quotaEngine: QuotaEngine

    init(
        settingsStore: SettingsStore = .shared,
        quotaEngine: QuotaEngine = .shared,
        logger: FluxLogger = .shared
    ) {
        self.settingsStore = settingsStore
        self.quotaEngine = quotaEngine
        self.logger = logger
    }

    func refreshAll(force: Bool = false) async -> [ProviderID: QuotaSnapshot] {
        await updateRefreshIntervalSeconds()

        let now = Date()
        let supportedProviders = ProviderID.allCases.filter(\.descriptor.supportsQuota)
        let hasUnloadedSupportedProvider = supportedProviders.contains { cache[$0] == nil }

        if let lastRefresh,
           !cache.isEmpty,
           now.timeIntervalSince(lastRefresh) < TimeInterval(refreshIntervalSeconds),
           force == false,
           hasUnloadedSupportedProvider == false {
            await logger.log(
                .debug,
                category: LogCategories.quotaAggregator,
                metadata: [
                    "force": .bool(force),
                    "ageSec": .int(Int(now.timeIntervalSince(lastRefresh))),
                    "intervalSec": .int(refreshIntervalSeconds),
                ],
                message: "refreshAll skipped (cached)"
            )
            return await allSnapshots()
        }

        let report = await quotaEngine.refreshAll(force: force)
        apply(report: report, now: now)
        lastRefresh = now
        return await allSnapshots()
    }

    func refreshProvider(provider: ProviderID, force: Bool = false) async -> [String: AccountQuota] {
        let now = Date()

        if provider.descriptor.supportsQuota == false {
            cache[provider] = [:]
            lastProviderRefresh[provider] = now
            return [:]
        }

        if force == false, isRateLimited(provider: provider, now: now), let cached = cache[provider] { return cached }

        guard let kind = mapProviderKind(provider) else {
            cache[provider] = [:]
            lastProviderRefresh[provider] = now
            return [:]
        }

        let providerReport = await quotaEngine.refresh(provider: kind, force: force)
        apply(providerReport: providerReport, now: now)
        lastProviderRefresh[provider] = now
        return cache[provider] ?? [:]
    }

    func refreshAccount(provider: ProviderID, accountKey: String, force: Bool = false) async -> AccountQuota? {
        await loadCachedIfNeeded()

        let now = Date()

        if provider.descriptor.supportsQuota == false {
            cache[provider] = [:]
            lastProviderRefresh[provider] = now
            return nil
        }

        if let last = lastAccountRefresh[provider]?[accountKey],
           now.timeIntervalSince(last) < minAccountRefreshInterval {
            return cache[provider]?[accountKey]
        }

        guard let kind = mapProviderKind(provider) else { return nil }

        let report = await quotaEngine.refreshAccount(provider: kind, accountKey: accountKey, force: force)
        let mapped = mapAccountQuota(report)

        cache[provider, default: [:]][accountKey] = mapped

        lastAccountRefresh[provider, default: [:]][accountKey] = report.fetchedAt
        lastProviderRefresh[provider] = report.fetchedAt

        return mapped
    }

    func refresh(provider: ProviderID, force: Bool = false) async -> QuotaSnapshot {
        _ = await refreshProvider(provider: provider, force: force)
        return snapshot(for: provider, now: Date())
    }

    func getSnapshot(for provider: ProviderID) async -> QuotaSnapshot? {
        await loadCachedIfNeeded()
        guard cache[provider] != nil else { return nil }
        return snapshot(for: provider, now: Date())
    }

    func allSnapshots() async -> [ProviderID: QuotaSnapshot] {
        await loadCachedIfNeeded()
        var results: [ProviderID: QuotaSnapshot] = [:]
        for provider in ProviderID.allCases {
            results[provider] = snapshot(for: provider, now: Date())
        }
        return results
    }

    func allProviderSnapshots() async -> [ProviderID: ProviderQuotaSnapshot] {
        await loadCachedIfNeeded()
        let now = Date()
        var results: [ProviderID: ProviderQuotaSnapshot] = [:]
        for provider in ProviderID.allCases {
            let fetchedAt = lastProviderRefresh[provider] ?? .distantPast
            let accounts = cache[provider] ?? [:]
            results[provider] = ProviderQuotaSnapshot(provider: provider, accounts: accounts, fetchedAt: fetchedAt == .distantPast ? now : fetchedAt)
        }
        return results
    }

    private func isRateLimited(provider: ProviderID, now: Date) -> Bool {
        guard let last = lastProviderRefresh[provider] else { return false }
        return now.timeIntervalSince(last) < minProviderRefreshInterval
    }

    private func snapshot(for provider: ProviderID, now: Date) -> QuotaSnapshot {
        if provider.descriptor.supportsQuota == false {
            return QuotaSnapshot(provider: provider, fetchedAt: now, kind: .unsupported, message: "Quota not supported".localizedStatic())
        }

        guard let accounts = cache[provider] else {
            return QuotaSnapshot(provider: provider, fetchedAt: now, kind: .loading, message: "Not loaded".localizedStatic())
        }

        if accounts.isEmpty {
            return QuotaSnapshot(provider: provider, fetchedAt: now, kind: .authMissing, message: "Credentials missing".localizedStatic())
        }

        let sorted = accounts.values.sorted { ($0.email ?? $0.accountKey) < ($1.email ?? $1.accountKey) }

        if let firstError = sorted.first(where: { $0.kind == .error }) {
            return QuotaSnapshot(provider: provider, fetchedAt: now, kind: .error, metrics: firstError.quota, message: firstError.error)
        }

        if let firstAuthMissing = sorted.first(where: { $0.kind == .authMissing }) {
            return QuotaSnapshot(provider: provider, fetchedAt: now, kind: .authMissing, metrics: firstAuthMissing.quota, message: firstAuthMissing.error)
        }

        if let firstUnsupported = sorted.first(where: { $0.kind == .unsupported }) {
            return QuotaSnapshot(provider: provider, fetchedAt: now, kind: .unsupported, metrics: firstUnsupported.quota, message: firstUnsupported.message)
        }

        if let best = selectMostConstrainedAccount(sorted) {
            let message = best.email ?? best.accountKey
            return QuotaSnapshot(provider: provider, fetchedAt: now, kind: .ok, metrics: best.quota, message: message)
        }

        return QuotaSnapshot(provider: provider, fetchedAt: now, kind: .ok, message: "\(accounts.count) accounts")
    }

    private func loadCachedIfNeeded() async {
        guard cache.isEmpty else { return }
        if let report = await quotaEngine.loadCachedReport() {
            apply(report: report, now: Date())
        }
    }

    private func apply(report: QuotaReport, now: Date) {
        for providerReport in report.providers {
            apply(providerReport: providerReport, now: now)
        }
        lastRefresh = report.generatedAt
    }

    private func apply(providerReport: ProviderQuotaReport, now: Date) {
        guard let providerID = mapProviderID(providerReport.provider) else { return }

        var accounts: [String: AccountQuota] = [:]
        for account in providerReport.accounts {
            let mapped = mapAccountQuota(account)
            accounts[mapped.accountKey] = mapped
        }

        cache[providerID] = accounts
        lastProviderRefresh[providerID] = providerReport.fetchedAt
    }

    private func mapAccountQuota(_ report: AccountQuotaReport) -> AccountQuota {
        let kind: QuotaSnapshotKind = switch report.status {
        case .ok: .ok
        case .authMissing: .authMissing
        case .error: .error
        case .stale: .loading
        case .loading: .loading
        }

        let modelQuotas: [ModelQuota] = report.windows.compactMap { window in
            guard let used = window.usedPercent, let remaining = window.remainingPercent else { return nil }
            return ModelQuota(
                modelId: window.id,
                displayName: window.label,
                usedPercent: used,
                remainingPercent: remaining,
                resetAt: window.resetAt
            )
        }

        let metrics: QuotaMetrics? = summarize(modelQuotas)

        let planType = report.plan.flatMap(mapPlanType) ?? .unknown

        return AccountQuota(
            accountKey: report.accountKey,
            email: report.email,
            kind: kind,
            quota: metrics,
            lastUpdated: report.fetchedAt,
            message: report.plan ?? report.email,
            error: report.errorMessage,
            planType: planType,
            modelQuotas: modelQuotas
        )
    }

    private func summarize(_ modelQuotas: [ModelQuota]) -> QuotaMetrics? {
        guard modelQuotas.isEmpty == false else { return nil }
        let worst = modelQuotas.min(by: { $0.remainingPercent < $1.remainingPercent })
        guard let worst else { return nil }

        return QuotaMetrics(
            used: Int(worst.usedPercent.rounded()),
            limit: 100,
            remaining: Int(worst.remainingPercent.rounded()),
            resetAt: worst.resetAt,
            unit: .credits
        )
    }

    private func mapPlanType(_ value: String) -> AccountPlanType {
        switch normalizePlanType(value) {
        case "free", "guest":
            return .free
        case "plus":
            return .plus
        case "pro":
            return .pro
        case "team":
            return .team
        case "enterprise":
            return .enterprise
        default:
            return .unknown
        }
    }

    private func normalizePlanType(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }

    private func mapProviderID(_ kind: ProviderKind) -> ProviderID? {
        switch kind {
        case .antigravity: .antigravity
        case .codex: .codex
        case .geminiCLI: .geminiCLI
        }
    }

    private func mapProviderKind(_ provider: ProviderID) -> ProviderKind? {
        switch provider {
        case .antigravity: .antigravity
        case .codex: .codex
        case .geminiCLI: .geminiCLI
        default: nil
        }
    }

    private func selectMostConstrainedAccount(_ accounts: [AccountQuota]) -> AccountQuota? {
        let okAccounts = accounts.filter { $0.kind == .ok }
        guard !okAccounts.isEmpty else { return nil }

        func remainingRatio(_ metrics: QuotaMetrics?) -> Double? {
            guard let used = metrics?.used, let limit = metrics?.limit, limit > 0 else { return nil }
            let remaining = max(0, limit - used)
            return Double(remaining) / Double(limit)
        }

        return okAccounts.min { lhs, rhs in
            let l = remainingRatio(lhs.quota) ?? 1
            let r = remainingRatio(rhs.quota) ?? 1
            if l != r { return l < r }
            return (lhs.email ?? lhs.accountKey) < (rhs.email ?? rhs.accountKey)
        }
    }

    private func updateRefreshIntervalSeconds() async {
        do {
            let settings = try await settingsStore.load()
            if settings.refreshIntervalSeconds <= 0 {
                refreshIntervalSeconds = 300
            } else {
                refreshIntervalSeconds = max(5, settings.refreshIntervalSeconds)
            }
        } catch {
            // Keep last known refreshIntervalSeconds
        }
    }
}
