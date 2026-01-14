import Foundation

actor QuotaEngine {
    static let shared = QuotaEngine()

    private let httpClient: HTTPClient
    private let cacheStore: QuotaCacheStore
    private let inFlight: InFlightDeduplicator
    private let logger: FluxLogger

    private var authDirWatcher: CLIProxyAuthDirWatcher?

    private var cachedReport: QuotaReport?
    private var providerBackoff: [ProviderKind: BackoffState] = [:]

    private let codexDataSource: CodexQuotaDataSource
    private let geminiCLIDataSource: GeminiCLIQuotaDataSource
    private let antigravityDataSource: AntigravityQuotaDataSource
    private let antigravityRefreshLock = AsyncLock(name: "quota.refresh.antigravity")

    private struct BackoffState: Sendable {
        var failures: Int
        var nextAllowedAt: Date
    }

    init(
        httpClient: HTTPClient = .shared,
        cacheStore: QuotaCacheStore = QuotaCacheStore(),
        inFlight: InFlightDeduplicator = InFlightDeduplicator(),
        logger: FluxLogger = .shared
    ) {
        self.httpClient = httpClient
        self.cacheStore = cacheStore
        self.inFlight = inFlight
        self.logger = logger

        self.codexDataSource = CodexQuotaDataSource(httpClient: httpClient, logger: logger)
        self.geminiCLIDataSource = GeminiCLIQuotaDataSource(httpClient: httpClient, logger: logger)
        self.antigravityDataSource = AntigravityQuotaDataSource(httpClient: httpClient, logger: logger)
    }

    func startWatchingAuthDirIfNeeded() {
        guard authDirWatcher == nil else { return }

        authDirWatcher = CLIProxyAuthDirWatcher { [weak self] in
            guard let self else { return }
            Task {
                await self.logger.log(.debug, category: LogCategories.auth, message: "CLIProxy auth dir changed; refreshing quota")
                _ = await self.refreshAll(force: false)
            }
        }
        authDirWatcher?.start()
    }

    func stopWatchingAuthDir() {
        authDirWatcher?.stop()
        authDirWatcher = nil
    }

    func loadCachedReport() async -> QuotaReport? {
        if let cachedReport { return cachedReport }
        let loaded = await cacheStore.load()
        cachedReport = loaded
        return loaded
    }

    func refreshAll(force: Bool) async -> QuotaReport {
        startWatchingAuthDirIfNeeded()

        do {
            return try await inFlight.run(key: "quota.refreshAll") { [weak self] in
                guard let self else {
                    return QuotaReport(generatedAt: Date(), providers: [])
                }
                return await self.performRefreshAll(force: force)
            }
        } catch {
            if let cachedReport {
                return cachedReport
            }
            return QuotaReport(generatedAt: Date(), providers: [])
        }
    }

    func refresh(provider: ProviderKind, force: Bool) async -> ProviderQuotaReport {
        startWatchingAuthDirIfNeeded()

        let key = "quota.refresh.\(provider.rawValue)"
        do {
            return try await inFlight.run(key: key) { [weak self] in
                guard let self else {
                    return ProviderQuotaReport(provider: provider, fetchedAt: Date(), accounts: [])
                }
                let report = await self.performRefreshAll(force: force)
                return report.providers.first(where: { $0.provider == provider }) ?? ProviderQuotaReport(provider: provider, fetchedAt: report.generatedAt, accounts: [])
            }
        } catch {
            let fallback = cachedReport?.providers.first(where: { $0.provider == provider })
            return fallback ?? ProviderQuotaReport(provider: provider, fetchedAt: Date(), accounts: [])
        }
    }

    func refreshAccount(provider: ProviderKind, accountKey: String, force: Bool = false) async -> AccountQuotaReport {
        startWatchingAuthDirIfNeeded()

        let credentials = CLIProxyAuthFileReader.listCredentials()
        guard let credential = credentials.first(where: { $0.provider == provider && $0.accountKey == accountKey }) else {
            return AccountQuotaReport(
                provider: provider,
                accountKey: accountKey,
                email: nil,
                plan: nil,
                status: .authMissing,
                source: .oauthApi,
                fetchedAt: Date(),
                windows: [],
                errorMessage: "Auth file not found"
            )
        }

        let now = Date()
        if force == false, isBackedOff(provider: provider, now: now) {
            return cachedAccountReport(provider: provider, accountKey: accountKey, credential: credential, now: now)
        }

        let dedupeKey = "quota.refresh.\(provider.rawValue).\(accountKey)"

        let dataSource = dataSource(for: provider)
        let antigravity = antigravityDataSource
        let antigravityLock = antigravityRefreshLock

        do {
            return try await inFlight.run(key: dedupeKey) {
                if provider == .antigravity {
                    return await antigravityLock.withLock {
                        let now = Date()
                        await antigravity.beginRefreshCycle()

                        let report: AccountQuotaReport
                        do {
                            report = try await dataSource.fetchQuota(for: credential)
                        } catch let error as FluxError {
                            let status: FluxQuotaStatus = error.code == .authError ? .authMissing : .error
                            report = AccountQuotaReport(
                                provider: provider,
                                accountKey: accountKey,
                                email: credential.email,
                                plan: nil,
                                status: status,
                                source: .oauthApi,
                                fetchedAt: now,
                                windows: [],
                                errorMessage: error.message
                            )
                        } catch {
                            report = AccountQuotaReport(
                                provider: provider,
                                accountKey: accountKey,
                                email: credential.email,
                                plan: nil,
                                status: .error,
                                source: .oauthApi,
                                fetchedAt: now,
                                windows: [],
                                errorMessage: "\(provider.displayName) quota fetch failed"
                            )
                        }

                        await antigravity.finishRefreshCycle()
                        return report
                    }
                }

                let now = Date()
                do {
                    return try await dataSource.fetchQuota(for: credential)
                } catch let error as FluxError {
                    let status: FluxQuotaStatus = error.code == .authError ? .authMissing : .error
                    return AccountQuotaReport(
                        provider: provider,
                        accountKey: accountKey,
                        email: credential.email,
                        plan: nil,
                        status: status,
                        source: .oauthApi,
                        fetchedAt: now,
                        windows: [],
                        errorMessage: error.message
                    )
                } catch {
                    return AccountQuotaReport(
                        provider: provider,
                        accountKey: accountKey,
                        email: credential.email,
                        plan: nil,
                        status: .error,
                        source: .oauthApi,
                        fetchedAt: now,
                        windows: [],
                        errorMessage: "\(provider.displayName) quota fetch failed"
                    )
                }
            }
        } catch {
            return AccountQuotaReport(
                provider: provider,
                accountKey: accountKey,
                email: credential.email,
                plan: nil,
                status: .error,
                source: .oauthApi,
                fetchedAt: Date(),
                windows: [],
                errorMessage: error.localizedDescription
            )
        }
    }

    // MARK: - Internals

    private func dataSource(for provider: ProviderKind) -> any QuotaDataSource {
        switch provider {
        case .codex:
            return codexDataSource
        case .geminiCLI:
            return geminiCLIDataSource
        case .antigravity:
            return antigravityDataSource
        }
    }

    private func cachedAccountReport(
        provider: ProviderKind,
        accountKey: String,
        credential: CLIProxyCredential,
        now: Date
    ) -> AccountQuotaReport {
        guard let cachedProvider = cachedReport?.providers.first(where: { $0.provider == provider }),
              var cachedAccount = cachedProvider.accounts.first(where: { $0.accountKey == accountKey })
        else {
            return AccountQuotaReport(
                provider: provider,
                accountKey: accountKey,
                email: credential.email,
                plan: nil,
                status: .stale,
                source: .oauthApi,
                fetchedAt: now,
                windows: [],
                errorMessage: "Backed off"
            )
        }

        if cachedAccount.status == .ok {
            cachedAccount.status = .stale
        }
        return cachedAccount
    }

    private func performRefreshAll(force: Bool) async -> QuotaReport {
        let now = Date()
        let credentials = CLIProxyAuthFileReader.listCredentials()

        var providers: [ProviderQuotaReport] = []
        providers.reserveCapacity(ProviderKind.allCases.count)

        for provider in ProviderKind.allCases {
            let providerCredentials = credentials.filter { $0.provider == provider }

            if force == false, isBackedOff(provider: provider, now: now) {
                if let cached = cachedReport?.providers.first(where: { $0.provider == provider }) {
                    let staleAccounts = cached.accounts.map { account in
                        var copy = account
                        if copy.status == .ok { copy.status = .stale }
                        return copy
                    }
                    providers.append(ProviderQuotaReport(provider: provider, fetchedAt: cached.fetchedAt, accounts: staleAccounts))
                } else {
                    providers.append(ProviderQuotaReport(provider: provider, fetchedAt: now, accounts: []))
                }
                continue
            }

            let dataSource: any QuotaDataSource = switch provider {
            case .codex: codexDataSource
            case .geminiCLI: geminiCLIDataSource
            case .antigravity: antigravityDataSource
            }

            if provider == .antigravity {
                await antigravityDataSource.beginRefreshCycle()
            }

            let accounts = await fetchAccounts(
                provider: provider,
                credentials: providerCredentials,
                dataSource: dataSource,
                now: now
            )
            providers.append(ProviderQuotaReport(provider: provider, fetchedAt: now, accounts: accounts))

            if provider == .antigravity {
                await antigravityDataSource.finishRefreshCycle()
            }
        }

        let report = QuotaReport(generatedAt: now, providers: providers)
        cachedReport = report
        await cacheStore.save(report)
        return report
    }

    private func fetchAccounts(
        provider: ProviderKind,
        credentials: [CLIProxyCredential],
        dataSource: any QuotaDataSource,
        now: Date
    ) async -> [AccountQuotaReport] {
        guard credentials.isEmpty == false else { return [] }

        var results: [AccountQuotaReport] = []
        results.reserveCapacity(credentials.count)

        await withTaskGroup(of: AccountQuotaReport.self) { group in
            for credential in credentials {
                group.addTask {
                    do {
                        return try await dataSource.fetchQuota(for: credential)
                    } catch let error as FluxError {
                        let status: FluxQuotaStatus = error.code == .authError ? .authMissing : .error
                        return AccountQuotaReport(
                            provider: provider,
                            accountKey: credential.accountKey,
                            email: credential.email,
                            plan: nil,
                            status: status,
                            source: .oauthApi,
                            fetchedAt: now,
                            windows: [],
                            errorMessage: error.message
                        )
                    } catch {
                        return AccountQuotaReport(
                            provider: provider,
                            accountKey: credential.accountKey,
                            email: credential.email,
                            plan: nil,
                            status: .error,
                            source: .oauthApi,
                            fetchedAt: now,
                            windows: [],
                            errorMessage: "\(provider.displayName) quota fetch failed"
                        )
                    }
                }
            }

            for await report in group {
                results.append(report)
            }
        }

        if results.contains(where: { $0.status == .error }) {
            registerFailure(provider: provider, kind: .error, now: now)
        } else if results.contains(where: { $0.status == .authMissing }) {
            registerFailure(provider: provider, kind: .authMissing, now: now)
        } else {
            resetBackoff(provider: provider)
        }

        return results.sorted(by: { ($0.email ?? $0.accountKey) < ($1.email ?? $1.accountKey) })
    }

    private enum FailureKind {
        case authMissing
        case error
    }

    private func isBackedOff(provider: ProviderKind, now: Date) -> Bool {
        guard let state = providerBackoff[provider] else { return false }
        return now < state.nextAllowedAt
    }

    private func registerFailure(provider: ProviderKind, kind: FailureKind, now: Date) {
        let baseSeconds: TimeInterval = {
            switch kind {
            case .authMissing: return 30
            case .error: return 60
            }
        }()

        var state = providerBackoff[provider] ?? BackoffState(failures: 0, nextAllowedAt: now)
        state.failures = min(state.failures + 1, 6)
        let delay = min(baseSeconds * pow(2.0, Double(state.failures - 1)), 10 * 60)
        state.nextAllowedAt = now.addingTimeInterval(delay)
        providerBackoff[provider] = state
    }

    private func resetBackoff(provider: ProviderKind) {
        providerBackoff[provider] = nil
    }
}

private actor AsyncLock {
    private var isLocked: Bool = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let name: String

    init(name: String) {
        self.name = name
    }

    func withLock<T: Sendable>(_ operation: @escaping @Sendable () async -> T) async -> T {
        await acquire()
        let result = await operation()
        release()
        return result
    }

    private func acquire() async {
        if isLocked {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
            return
        }
        isLocked = true
    }

    private func release() {
        if waiters.isEmpty {
            isLocked = false
            return
        }
        let next = waiters.removeFirst()
        next.resume()
    }
}
