import Foundation

actor QuotaAggregator {
    static let shared = QuotaAggregator(fetchers: defaultFetchers())

    private let settingsStore: SettingsStore
    private let cliProxyAuthScanner: CLIProxyAuthScanner
    private let logger: FluxLogger

    private var fetchersByProvider: [ProviderID: any QuotaFetcher]

    private var cache: [ProviderID: [String: AccountQuota]] = [:]
    private var lastRefresh: Date?
    private var lastProviderRefresh: [ProviderID: Date] = [:]
    private var missingFetcherProviders: Set<ProviderID> = []

    private var refreshIntervalSeconds: Int = 60

    private let minProviderRefreshInterval: TimeInterval = 30

    init(
        settingsStore: SettingsStore = .shared,
        cliProxyAuthScanner: CLIProxyAuthScanner = CLIProxyAuthScanner(),
        fetchers: [any QuotaFetcher] = [],
        logger: FluxLogger = .shared
    ) {
        self.settingsStore = settingsStore
        self.cliProxyAuthScanner = cliProxyAuthScanner
        self.fetchersByProvider = Dictionary(uniqueKeysWithValues: fetchers.map { ($0.providerID, $0) })
        self.logger = logger
    }

    private static func defaultFetchers() -> [any QuotaFetcher] {
        [
            ClaudeQuotaFetcher(),
            CodexQuotaFetcher(),
            AntigravityQuotaFetcher(),
            GeminiCLIQuotaFetcher(),
            CopilotQuotaFetcher(),
        ]
    }

    func setFetchers(_ fetchers: [any QuotaFetcher]) {
        fetchersByProvider = Dictionary(uniqueKeysWithValues: fetchers.map { ($0.providerID, $0) })
    }

    func refreshAll(force: Bool = false) async -> [ProviderID: QuotaSnapshot] {
        await updateRefreshIntervalSeconds()

        let now = Date()
        let supportedProviders = ProviderID.allCases.filter(\.descriptor.supportsQuota)
        let hasUnloadedSupportedProvider = supportedProviders.contains { provider in
            cache[provider] == nil && missingFetcherProviders.contains(provider) == false
        }

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
            return allSnapshots()
        }

        let authFiles = await cliProxyAuthScanner.scanAuthFiles()
        if authFiles.isEmpty {
            await logger.log(.debug, category: LogCategories.quotaAggregator, metadata: ["count": .int(0)], message: "scanAuthFiles")
        } else {
            var counts: [AuthFileProvider: Int] = [:]
            for file in authFiles {
                counts[file.provider, default: 0] += 1
            }
            let summary = counts
                .sorted(by: { $0.key.rawValue < $1.key.rawValue })
                .map { "\($0.key.rawValue)=\($0.value)" }
                .joined(separator: " ")
            await logger.log(
                .debug,
                category: LogCategories.quotaAggregator,
                metadata: ["count": .int(authFiles.count), "providers": .string(summary)],
                message: "scanAuthFiles"
            )
        }

        let providers = ProviderID.allCases
        var refreshedProviders: Set<ProviderID> = []
        var nextCache: [ProviderID: [String: AccountQuota]] = cache
        var nextMissingFetcherProviders: Set<ProviderID> = missingFetcherProviders

        await withTaskGroup(of: (ProviderID, [String: AccountQuota]?).self) { group in
            for provider in providers {
                if provider.descriptor.supportsQuota == false {
                    refreshedProviders.insert(provider)
                    nextCache[provider] = [:]
                    continue
                }

                if force == false, isRateLimited(provider: provider, now: now), cache[provider] != nil {
                    continue
                }

                guard let fetcher = fetchersByProvider[provider] else {
                    refreshedProviders.insert(provider)
                    nextMissingFetcherProviders.insert(provider)
                    continue
                }

                group.addTask {
                    let accounts = await fetcher.fetchQuotas(authFiles: authFiles)
                    return (provider, accounts)
                }
            }

            for await (provider, accounts) in group {
                if let accounts {
                    nextCache[provider] = accounts
                }
                refreshedProviders.insert(provider)
            }
        }

        for provider in refreshedProviders {
            lastProviderRefresh[provider] = now
        }

        cache = nextCache
        missingFetcherProviders = nextMissingFetcherProviders
        lastRefresh = now
        return allSnapshots()
    }

    func refreshProvider(provider: ProviderID, force: Bool = false) async -> [String: AccountQuota] {
        let now = Date()

        if provider.descriptor.supportsQuota == false {
            cache[provider] = [:]
            lastProviderRefresh[provider] = now
            return [:]
        }

        if force == false, isRateLimited(provider: provider, now: now), let cached = cache[provider] {
            return cached
        }

        guard let fetcher = fetchersByProvider[provider] else {
            missingFetcherProviders.insert(provider)
            cache[provider] = [:]
            lastProviderRefresh[provider] = now
            return [:]
        }

        let authFiles = await cliProxyAuthScanner.scanAuthFiles()
        let accounts = await fetcher.fetchQuotas(authFiles: authFiles)
        cache[provider] = accounts
        missingFetcherProviders.remove(provider)
        lastProviderRefresh[provider] = now
        return accounts
    }

    func refresh(provider: ProviderID, force: Bool = false) async -> QuotaSnapshot {
        _ = await refreshProvider(provider: provider, force: force)
        return snapshot(for: provider, now: Date())
    }

    func getSnapshot(for provider: ProviderID) -> QuotaSnapshot? {
        guard cache[provider] != nil || missingFetcherProviders.contains(provider) else { return nil }
        return snapshot(for: provider, now: Date())
    }

    func allSnapshots() -> [ProviderID: QuotaSnapshot] {
        var results: [ProviderID: QuotaSnapshot] = [:]
        for provider in ProviderID.allCases {
            results[provider] = snapshot(for: provider, now: Date())
        }
        return results
    }

    func allProviderSnapshots() -> [ProviderID: ProviderQuotaSnapshot] {
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

        if missingFetcherProviders.contains(provider) {
            return QuotaSnapshot(provider: provider, fetchedAt: now, kind: .unsupported, message: "Quota fetcher not implemented".localizedStatic())
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
