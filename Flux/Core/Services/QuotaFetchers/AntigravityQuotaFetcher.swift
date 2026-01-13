import Foundation

actor AntigravityQuotaFetcher: QuotaFetcher {
    nonisolated let providerID: ProviderID = .antigravity

    private let httpClient: HTTPClient
    private let logger: FluxLogger

    private let tokenURL = URL(string: "https://oauth2.googleapis.com/token")

    private static let fetchAvailableModelsURLs: [URL] = [
        "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
        "https://daily-cloudcode-pa.sandbox.googleapis.com/v1internal:fetchAvailableModels",
        "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
    ].compactMap(URL.init(string:))

    private static let loadCodeAssistURLs: [URL] = [
        "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist",
        "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist",
        "https://daily-cloudcode-pa.sandbox.googleapis.com/v1internal:loadCodeAssist",
        "https://autopush-cloudcode-pa.sandbox.googleapis.com/v1internal:loadCodeAssist",
    ].compactMap(URL.init(string:))

    private static let antigravityUserAgent = "antigravity/1.11.3 Darwin/arm64"

    private static let oauthClientId = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    private static let oauthClientSecret = "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"

    private let cacheStore: AntigravityProjectCacheStore
    private let urlSession: URLSession

    private var subscriptionCache: [String: SubscriptionSnapshot] = [:]
    private var projectIdCache: [String: AntigravityProjectCacheStore.ProjectCacheEntry] = [:]

    init(
        httpClient: HTTPClient = .shared,
        logger: FluxLogger = .shared,
        cacheStore: AntigravityProjectCacheStore = .shared,
        urlSession: URLSession = .shared
    ) {
        self.httpClient = httpClient
        self.logger = logger
        self.cacheStore = cacheStore
        self.urlSession = urlSession
    }

    // MARK: - Public

    func beginRefreshCycle() async {
        subscriptionCache = [:]
        projectIdCache = await cacheStore.load()
    }

    func fetchQuotas(authFiles: [AuthFileInfo]) async -> [String: AccountQuota] {
        await beginRefreshCycle()

        let now = Date()
        let candidates = authFiles.filter { $0.provider == .antigravity }
        guard !candidates.isEmpty else { return [:] }

        await logger.log(.debug, category: LogCategories.quotaAntigravity, metadata: ["authFiles": .int(candidates.count)], message: "scan auth files")

        var results: [String: AccountQuota] = [:]
        await withTaskGroup(of: (String, AccountQuota).self) { group in
            for file in candidates {
                group.addTask {
                    let quota = await self.fetchQuota(for: file, now: now)
                    return (quota.accountKey, quota)
                }
            }

            for await (key, quota) in group {
                results[key] = quota
            }
        }

        await cacheStore.save(projectIdCache)
        return results
    }

    // MARK: - Result Types

    enum QuotaFetchResult<Payload: Sendable>: Sendable {
        case success(Payload)
        case unauthorized
        case forbidden
        case rateLimited
        case failed(String)
    }

    struct AntigravityAuthContext: Sendable {
        let accountKey: String
        let file: AuthFileInfo
        var accessToken: String
        var projectHint: String?
        var resolvedProjectId: String?
        var usedCachedPid: Bool
        var didRefreshToken: Bool

        init(accountKey: String, file: AuthFileInfo, accessToken: String) {
            self.accountKey = accountKey
            self.file = file
            self.accessToken = accessToken
            self.projectHint = nil
            self.resolvedProjectId = nil
            self.usedCachedPid = false
            self.didRefreshToken = false
        }
    }

    struct SubscriptionSnapshot: Sendable {
        let tier: String?
        let projectId: String?
        let fetchedAt: Date
    }

    struct ProjectCacheEntry: Sendable {
        let projectId: String
        let source: AntigravityProjectCacheStore.ProjectCacheEntry.Source
    }

    // MARK: - Strongly typed responses

    struct LoadCodeAssistResponse: Decodable, Sendable {
        let cloudaicompanionProject: ProjectRef?
        let currentTier: Tier?
        let paidTier: Tier?
        let userStatus: UserStatus?

        struct Tier: Decodable, Sendable {
            let id: String?
            let name: String?
        }

        struct UserStatus: Decodable, Sendable {
            let userTier: Tier?
        }

        struct ProjectRef: Decodable, Sendable {
            let value: String?

            init(from decoder: Decoder) throws {
                if let string = try? decoder.singleValueContainer().decode(String.self) {
                    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.value = trimmed.isEmpty ? nil : trimmed
                    return
                }

                let container = try decoder.singleValueContainer()
                if let dict = try? container.decode([String: String].self) {
                    let candidates = [dict["id"], dict["projectId"], dict["project"]]
                    let extracted = candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
                    self.value = extracted
                    return
                }

                self.value = nil
            }
        }

        var extractedProjectId: String? {
            cloudaicompanionProject?.value
        }

        var extractedTier: String? {
            let paid = paidTier?.id ?? paidTier?.name
            let current = currentTier?.id ?? currentTier?.name
            let user = userStatus?.userTier?.id ?? userStatus?.userTier?.name
            return paid ?? current ?? user
        }
    }

    struct FetchAvailableModelsResponse: Decodable, Sendable {
        let models: [String: ModelInfo]

        struct ModelInfo: Decodable, Sendable {
            let quotaInfo: QuotaInfo?

            enum CodingKeys: String, CodingKey {
                case quotaInfo
                case quota_info
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                quotaInfo = (try? container.decode(QuotaInfo.self, forKey: .quotaInfo)) ?? (try? container.decode(QuotaInfo.self, forKey: .quota_info))
            }
        }

        struct QuotaInfo: Decodable, Sendable {
            let remainingFraction: Double?
            let resetTime: String?

            enum CodingKeys: String, CodingKey {
                case remainingFraction
                case remaining_fraction
                case remaining
                case resetTime
                case reset_time
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)

                let remainingRaw =
                    (try? container.decode(Double.self, forKey: .remainingFraction))
                    ?? (try? container.decode(Double.self, forKey: .remaining_fraction))
                    ?? (try? container.decode(Double.self, forKey: .remaining))

                if let remainingRaw {
                    if remainingRaw > 1, remainingRaw <= 100 {
                        remainingFraction = remainingRaw / 100.0
                    } else {
                        remainingFraction = min(1, max(0, remainingRaw))
                    }
                } else {
                    remainingFraction = nil
                }

                resetTime =
                    (try? container.decode(String.self, forKey: .resetTime))
                    ?? (try? container.decode(String.self, forKey: .reset_time))
            }
        }
    }

    // MARK: - Core fetch per account

    private func fetchQuota(for file: AuthFileInfo, now: Date) async -> AccountQuota {
        let accountKey = normalizedAccountKey(file: file)

        var accessToken = file.accessToken

        var context = AntigravityAuthContext(accountKey: accountKey, file: file, accessToken: accessToken)
        context.projectHint = readProjectHint(filePath: file.filePath)

        if let hint = context.projectHint {
            await logger.log(.debug, category: LogCategories.quotaAntigravity, metadata: ["projectHint": .string(hint)], message: "found project hint")
        }

        // Note: token refresh is only forced on 401 by requirement, but we keep
        // the existing pre-refresh logic as best effort (does not violate semantics).
        if shouldAttemptRefresh(file: file), let refreshed = await refreshAccessToken(from: file) {
            context.accessToken = refreshed
        }

        let result = await fetchQuotaResult(context: &context)

        switch result {
        case .success(let payload):
            return AccountQuota(
                accountKey: accountKey,
                email: file.email,
                kind: .ok,
                quota: payload.metrics,
                lastUpdated: now,
                message: nil,
                error: nil,
                planType: payload.planType,
                modelQuotas: payload.modelQuotas
            )
        case .unauthorized:
            return AccountQuota(
                accountKey: accountKey,
                email: file.email,
                kind: .authMissing,
                quota: nil,
                lastUpdated: now,
                message: nil,
                error: "Request unauthorized".localizedStatic(),
                planType: nil,
                modelQuotas: []
            )
        case .forbidden:
            return AccountQuota(
                accountKey: accountKey,
                email: file.email,
                kind: .error,
                quota: nil,
                lastUpdated: now,
                message: nil,
                error: "Account has no entitlement (403)".localizedStatic(),
                planType: nil,
                modelQuotas: []
            )
        case .rateLimited:
            return AccountQuota(
                accountKey: accountKey,
                email: file.email,
                kind: .error,
                quota: nil,
                lastUpdated: now,
                message: nil,
                error: "Request rate limited".localizedStatic(),
                planType: nil,
                modelQuotas: []
            )
        case .failed(let message):
            return AccountQuota(
                accountKey: accountKey,
                email: file.email,
                kind: .error,
                quota: nil,
                lastUpdated: now,
                message: nil,
                error: message,
                planType: nil,
                modelQuotas: []
            )
        }
    }

    private struct QuotaPayload: Sendable {
        let planType: AccountPlanType?
        let modelQuotas: [ModelQuota]
        let metrics: QuotaMetrics?
    }

    private func fetchQuotaResult(context: inout AntigravityAuthContext) async -> QuotaFetchResult<QuotaPayload> {
        // Resolve subscription/projectId with cache priority:
        // subscriptionCache > persistent project cache > authFileHint > loadCodeAssist
        let subscription = await resolveSubscriptionSnapshot(context: &context)

        let planType = subscription?.tier.map(mapPlanType) ?? .unknown

        var pidToUse: String?
        var usedCachedPid = false

        if let subscription, let pid = subscription.projectId {
            pidToUse = pid
            usedCachedPid = true
        } else if let cached = projectIdCache[context.accountKey] {
            pidToUse = cached.projectId
            usedCachedPid = true
            await logger.debug("Antigravity: hit persistent project cache", category: "Quota.Antigravity")
        } else if let hint = context.projectHint {
            pidToUse = hint
            usedCachedPid = false
        }

        context.resolvedProjectId = pidToUse
        context.usedCachedPid = usedCachedPid

        var payload: [String: Any] = [:]
        if let pidToUse, !pidToUse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["project"] = pidToUse
        }

        // 1st attempt: fetchAvailableModels with fallback endpoints
        let firstFetch = await fetchAvailableModelsWithFallback(accessToken: context.accessToken, payload: payload)

        switch firstFetch {
        case .success(let response):
            return .success(buildPayload(from: response, planType: planType))
        case .unauthorized:
            // Requirement: 401 triggers refresh if refreshToken exists; retry once.
            guard let refreshed = await refreshAccessToken(from: context.file) else {
                return .unauthorized
            }
            context.accessToken = refreshed
            context.didRefreshToken = true

            let retry = await fetchAvailableModelsWithFallback(accessToken: context.accessToken, payload: payload)
            switch retry {
            case .success(let response):
                return .success(buildPayload(from: response, planType: planType))
            case .forbidden:
                return await handleForbiddenAfterFetch(context: &context, usedCachedPid: usedCachedPid, payload: payload, planType: planType)
            case .rateLimited:
                return .rateLimited
            case .unauthorized:
                return .unauthorized
            case .failed(let message):
                return .failed(message)
            }
        case .forbidden:
            return await handleForbiddenAfterFetch(context: &context, usedCachedPid: usedCachedPid, payload: payload, planType: planType)
        case .rateLimited:
            return .rateLimited
        case .failed(let message):
            return .failed(message)
        }
    }

    private func handleForbiddenAfterFetch(
        context: inout AntigravityAuthContext,
        usedCachedPid: Bool,
        payload: [String: Any],
        planType: AccountPlanType?
    ) async -> QuotaFetchResult<QuotaPayload> {
        // 403 fallback rule:
        // If we used persistent cached projectId and got 403, refresh projectId via loadCodeAssist and retry once.
        guard usedCachedPid else {
            return .forbidden
        }

        await logger.warning("Antigravity: 403 with cached projectId, retrying loadCodeAssist", category: "Quota.Antigravity")

        let refreshedSubscription = await fetchSubscriptionSnapshot(accessToken: context.accessToken, projectHint: context.projectHint)
        if let refreshedSubscription, let newPid = refreshedSubscription.projectId {
            projectIdCache[context.accountKey] = AntigravityProjectCacheStore.ProjectCacheEntry(
                projectId: newPid,
                ttlSeconds: 7 * 24 * 60 * 60,
                updatedAt: Date(),
                source: .loadCodeAssist
            )

            var retryPayload = payload
            retryPayload["project"] = newPid

            let retry = await fetchAvailableModelsWithFallback(accessToken: context.accessToken, payload: retryPayload)
            switch retry {
            case .success(let response):
                return .success(buildPayload(from: response, planType: planType))
            case .unauthorized:
                return .unauthorized
            case .forbidden:
                return .forbidden
            case .rateLimited:
                return .rateLimited
            case .failed(let message):
                return .failed(message)
            }
        }

        return .forbidden
    }

    // MARK: - Subscription & caches

    private func resolveSubscriptionSnapshot(context: inout AntigravityAuthContext) async -> SubscriptionSnapshot? {
        if let cached = subscriptionCache[context.accountKey] {
            return cached
        }

        if let persistent = projectIdCache[context.accountKey] {
            let snapshot = SubscriptionSnapshot(tier: nil, projectId: persistent.projectId, fetchedAt: persistent.updatedAt)
            subscriptionCache[context.accountKey] = snapshot
            await logger.debug("Antigravity: using persisted projectId cache", category: "Quota.Antigravity")
            return snapshot
        }

        if let hint = context.projectHint {
            let snapshot = SubscriptionSnapshot(tier: nil, projectId: hint, fetchedAt: Date())
            subscriptionCache[context.accountKey] = snapshot
            return snapshot
        }

        if let fetched = await fetchSubscriptionSnapshot(accessToken: context.accessToken, projectHint: nil) {
            subscriptionCache[context.accountKey] = fetched
            if let pid = fetched.projectId {
                projectIdCache[context.accountKey] = AntigravityProjectCacheStore.ProjectCacheEntry(
                    projectId: pid,
                    ttlSeconds: 7 * 24 * 60 * 60,
                    updatedAt: Date(),
                    source: .loadCodeAssist
                )
            }
            return fetched
        }

        return nil
    }

    private func fetchSubscriptionSnapshot(accessToken: String, projectHint: String?) async -> SubscriptionSnapshot? {
        let payload = buildLoadCodeAssistPayload(projectHint: projectHint)

        let decoder = JSONDecoder()

        let result: QuotaFetchResult<LoadCodeAssistResponse> = await performWithFallback(
            urls: Self.loadCodeAssistURLs,
            requestBuilder: { url in
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.timeoutInterval = 15
                request.httpBody = payload
                request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                request.setValue(Self.antigravityUserAgent, forHTTPHeaderField: "User-Agent")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                return request
            },
            decoder: decoder
        )

        switch result {
        case .success(let response):
            let snapshot = SubscriptionSnapshot(tier: response.extractedTier, projectId: response.extractedProjectId, fetchedAt: Date())
            if let pid = snapshot.projectId {
                projectIdCache["unknown"] = projectIdCache["unknown"]
                // Persist per-account project id is handled by resolveSubscriptionSnapshot (accountKey aware).
                _ = pid
            }
            return snapshot
        default:
            return nil
        }
    }

    private func buildLoadCodeAssistPayload(projectHint: String?) -> Data {
        var metadata: [String: Any] = [
            "ideType": "ANTIGRAVITY",
            "platform": "PLATFORM_UNSPECIFIED",
            "pluginType": "GEMINI",
        ]

        var payload: [String: Any] = ["metadata": metadata]
        if let projectHint, projectHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            payload["cloudaicompanionProject"] = projectHint
            metadata["duetProject"] = projectHint
            payload["metadata"] = metadata
        }

        return (try? JSONSerialization.data(withJSONObject: payload, options: [])) ?? Data("{}".utf8)
    }

    // MARK: - Requests with fallback

    private func fetchAvailableModelsWithFallback(accessToken: String, payload: [String: Any]) async -> QuotaFetchResult<FetchAvailableModelsResponse> {
        let body = (try? JSONSerialization.data(withJSONObject: payload, options: [])) ?? Data("{}".utf8)
        let decoder = JSONDecoder()

        return await performWithFallback(
            urls: Self.fetchAvailableModelsURLs,
            requestBuilder: { url in
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.timeoutInterval = 15
                request.httpBody = body
                request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                request.setValue(Self.antigravityUserAgent, forHTTPHeaderField: "User-Agent")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                return request
            },
            decoder: decoder
        )
    }

    private func performWithFallback<Response: Decodable & Sendable>(
        urls: [URL],
        requestBuilder: @Sendable (URL) -> URLRequest,
        decoder: JSONDecoder
    ) async -> QuotaFetchResult<Response> {
        var lastRateLimited: Bool = false
        var lastMessage: String?

        for url in urls {
            let request = requestBuilder(url)
            do {
                let (data, response) = try await urlSession.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    lastMessage = "Invalid HTTP response".localizedStatic()
                    continue
                }

                let status = http.statusCode

                if status == 401 {
                    return .unauthorized
                }
                if status == 403 {
                    return .forbidden
                }
                if status == 429 {
                    lastRateLimited = true
                    lastMessage = "Request rate limited".localizedStatic()
                    continue
                }
                if (500...599).contains(status) {
                    lastMessage = "HTTP request failed".localizedStatic()
                    continue
                }
                guard (200...299).contains(status) else {
                    lastMessage = "HTTP request failed".localizedStatic()
                    continue
                }

                do {
                    let decoded = try decoder.decode(Response.self, from: data)
                    return .success(decoded)
                } catch {
                    lastMessage = "Failed to parse response".localizedStatic()
                    continue
                }
            } catch {
                lastMessage = "Network request failed".localizedStatic()
                continue
            }
        }

        if lastRateLimited {
            return .rateLimited
        }
        return .failed(lastMessage ?? "Antigravity request failed".localizedStatic())
    }

    // MARK: - Build payload / grouping (preserved)

    private func buildPayload(from response: FetchAvailableModelsResponse, planType: AccountPlanType?) -> QuotaPayload {
        let json = convertToLegacyJSON(response)
        let groupQuotas = buildGroupedModelQuotas(json: json)
        let summary = summarize(groupQuotas)
        return QuotaPayload(planType: planType, modelQuotas: groupQuotas, metrics: summary.metrics)
    }

    private func convertToLegacyJSON(_ response: FetchAvailableModelsResponse) -> [String: Any] {
        var models: [String: Any] = [:]
        for (modelId, info) in response.models {
            var modelDict: [String: Any] = [:]
            if let quotaInfo = info.quotaInfo {
                var qi: [String: Any] = [:]
                if let fraction = quotaInfo.remainingFraction { qi["remainingFraction"] = fraction }
                if let reset = quotaInfo.resetTime { qi["resetTime"] = reset }
                modelDict["quotaInfo"] = qi
            }
            models[modelId] = modelDict
        }
        return ["models": models]
    }

    // MARK: - Existing helpers preserved (token refresh + grouping)

    private func shouldAttemptRefresh(file: AuthFileInfo) -> Bool {
        guard file.refreshToken != nil else { return false }
        guard let expiredAt = file.expiredAt else { return false }
        return expiredAt <= Date().addingTimeInterval(60)
    }

    private func refreshAccessToken(from file: AuthFileInfo) async -> String? {
        guard let tokenURL else { return nil }
        guard let refreshToken = file.refreshToken, !refreshToken.isEmpty else { return nil }

        let extra = readTokenRefreshHints(filePath: file.filePath)
        let clientId = extra.clientId ?? Self.oauthClientId
        let clientSecret = extra.clientSecret ?? Self.oauthClientSecret

        let params: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId,
            "client_secret": clientSecret,
        ]

        let form = params
            .map { "\($0.key)=\(formEncode($0.value))" }
            .joined(separator: "&")

        do {
            await logger.debug("Antigravity: refreshing access token", category: "Quota.Antigravity")
            let data = try await httpClient.post(
                url: tokenURL,
                body: Data(form.utf8),
                headers: [
                    "Content-Type": "application/x-www-form-urlencoded",
                    "Accept": "application/json",
                ]
            )

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            if let token = json["access_token"] as? String, !token.isEmpty {
                updateAuthFileAfterRefresh(filePath: file.filePath, accessToken: token, expiresIn: parseDouble(json["expires_in"]))
                return token
            }
            return nil
        } catch let error as FluxError {
            await logger.warning("Antigravity: token refresh failed (\(error.code.rawValue)) \(error.message) \(error.details ?? "")", category: "Quota.Antigravity")
            return nil
        } catch {
            await logger.warning("Antigravity: token refresh failed \(String(describing: error))", category: "Quota.Antigravity")
            return nil
        }
    }

    private func readTokenRefreshHints(filePath: String) -> (clientId: String?, clientSecret: String?) {
        guard let data = FileManager.default.contents(atPath: filePath) else { return (nil, nil) }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return (nil, nil) }
        let clientId = (json["client_id"] as? String) ?? (json["clientId"] as? String)
        let clientSecret = (json["client_secret"] as? String) ?? (json["clientSecret"] as? String)
        return (clientId?.trimmingCharacters(in: .whitespacesAndNewlines), clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func parseDouble(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String, let double = Double(string) { return double }
        return nil
    }

    private func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func normalizedAccountKey(file: AuthFileInfo) -> String {
        if let email = file.email, !email.isEmpty { return email }
        return file.filename
    }

    private func updateAuthFileAfterRefresh(filePath: String, accessToken: String, expiresIn: Double?) {
        guard let data = FileManager.default.contents(atPath: filePath) else { return }
        guard var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

        json["access_token"] = accessToken
        if let expiresIn {
            json["expires_in"] = Int(expiresIn.rounded())
        }

        let now = Date()
        json["timestamp"] = Int(now.timeIntervalSince1970 * 1000)
        if let seconds = expiresIn, seconds > 0 {
            let expiresAt = now.addingTimeInterval(seconds)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            json["expired"] = formatter.string(from: expiresAt)
        }

        guard let updated = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else { return }
        do {
            let url = URL(fileURLWithPath: filePath)
            try updated.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
        } catch {
            // Best-effort persistence.
        }
    }

    private func readProjectHint(filePath: String) -> String? {
        guard let data = FileManager.default.contents(atPath: filePath) else { return nil }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }

        let candidates: [Any?] = [
            json["project"],
            json["projectId"],
            json["project_id"],
            json["cloudaicompanionProject"],
            json["cloudaicompanion_project"],
        ]
        for candidate in candidates {
            if let extracted = extractProjectId(candidate) { return extracted }
        }
        return nil
    }

    private func extractProjectId(_ raw: Any?) -> String? {
        if let string = raw as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let dict = raw as? [String: Any] {
            if let id = dict["id"] as? String {
                let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            if let value = dict["projectId"] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            if let value = dict["project"] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }
        return nil
    }

    // MARK: - Grouping logic preserved from previous implementation

    private struct GroupAccumulator {
        var minRemainingFraction: Double?
        var earliestResetAt: Date?
    }

    private func buildGroupedModelQuotas(json: [String: Any]) -> [ModelQuota] {
        let modelsDict: [String: Any]?
        if let dict = json["models"] as? [String: Any] {
            modelsDict = dict
        } else if let list = json["models"] as? [[String: Any]] {
            modelsDict = Dictionary(uniqueKeysWithValues: list.compactMap { item in
                let modelId = (item["modelName"] as? String) ?? (item["modelId"] as? String) ?? (item["id"] as? String)
                guard let modelId else { return nil }
                return (modelId, item)
            })
        } else {
            modelsDict = nil
        }

        guard let models = modelsDict else { return [] }

        var groups: [String: GroupAccumulator] = [:]

        for (modelId, value) in models {
            guard let modelDict = value as? [String: Any] else { continue }
            let displayName = modelDict["displayName"] as? String
            guard let quotaInfo = modelDict["quotaInfo"] as? [String: Any] ?? modelDict["quota_info"] as? [String: Any] else { continue }

            let remainingRaw = quotaInfo["remainingFraction"] ?? quotaInfo["remaining_fraction"] ?? quotaInfo["remaining"]
            var remainingFraction = parseDouble(remainingRaw)
            if let fraction = remainingFraction, fraction > 1, fraction <= 100 {
                remainingFraction = fraction / 100.0
            }
            if let fraction = remainingFraction {
                remainingFraction = min(1, max(0, fraction))
            }

            let resetString = (quotaInfo["resetTime"] as? String) ?? (quotaInfo["reset_time"] as? String)
            let resetAt = resetString.flatMap(parseISO8601Date)

            let groupName = groupNameForModel(modelId: modelId, displayName: displayName)

            var accumulator = groups[groupName] ?? GroupAccumulator(minRemainingFraction: nil, earliestResetAt: nil)

            let effectiveFraction: Double?
            if let remainingFraction {
                effectiveFraction = remainingFraction
            } else if resetAt != nil {
                effectiveFraction = 0
            } else {
                effectiveFraction = nil
            }

            if let effectiveFraction {
                accumulator.minRemainingFraction = min(accumulator.minRemainingFraction ?? effectiveFraction, effectiveFraction)
            }

            if let resetAt {
                accumulator.earliestResetAt = min(accumulator.earliestResetAt ?? resetAt, resetAt)
            }

            groups[groupName] = accumulator
        }

        let preferredOrder: [String] = [
            "Claude/GPT",
            "Gemini 3 Pro",
            "Gemini 2.5 Flash",
            "Gemini 2.5 Flash Lite",
            "Gemini 2.5 CU",
            "Gemini 3 Flash",
            "Gemini 3 Pro Image",
        ]

        func sortKey(_ name: String) -> (Int, String) {
            if let index = preferredOrder.firstIndex(of: name) { return (index, name) }
            return (preferredOrder.count, name)
        }

        return groups
            .sorted(by: { sortKey($0.key) < sortKey($1.key) })
            .compactMap { (name, acc) -> ModelQuota? in
                guard let fraction = acc.minRemainingFraction ?? (acc.earliestResetAt != nil ? 0 : nil) else { return nil }
                let remainingPercent = max(0, min(100, fraction * 100))
                return ModelQuota(
                    modelId: name,
                    displayName: name,
                    usedPercent: max(0, 100 - remainingPercent),
                    remainingPercent: remainingPercent,
                    resetAt: acc.earliestResetAt
                )
            }
    }

    private func groupNameForModel(modelId: String, displayName: String?) -> String {
        let lower = modelId.lowercased()

        if lower.hasPrefix("claude-") {
            return "Claude/GPT"
        }
        if lower.hasPrefix("gemini-3-pro-image") {
            return "Gemini 3 Pro Image"
        }
        if lower.hasPrefix("gemini-3-pro") {
            return "Gemini 3 Pro"
        }
        if lower.hasPrefix("gemini-2.5-flash-lite") {
            return "Gemini 2.5 Flash Lite"
        }
        if lower.hasPrefix("gemini-2.5-flash") {
            return "Gemini 2.5 Flash"
        }
        if lower.hasPrefix("gemini-2.5-cu") {
            return "Gemini 2.5 CU"
        }
        if lower.hasPrefix("gemini-3-flash") {
            return "Gemini 3 Flash"
        }

        return displayName ?? modelId
    }

    private struct SummaryResult {
        let metrics: QuotaMetrics?
    }

    private func summarize(_ modelQuotas: [ModelQuota]) -> SummaryResult {
        guard modelQuotas.isEmpty == false else { return SummaryResult(metrics: nil) }

        let worst = modelQuotas.min(by: { $0.remainingPercent < $1.remainingPercent })
        guard let worst else { return SummaryResult(metrics: nil) }

        let remaining = Int(worst.remainingPercent.rounded())
        let used = Int(worst.usedPercent.rounded())

        let metrics = QuotaMetrics(
            used: max(0, min(100, used)),
            limit: 100,
            remaining: max(0, min(100, remaining)),
            resetAt: worst.resetAt,
            unit: .credits
        )
        return SummaryResult(metrics: metrics)
    }

    private func parseISO8601Date(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: trimmed) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }

    private func mapPlanType(_ value: String) -> AccountPlanType {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty { return .unknown }
        if normalized.contains("enterprise") { return .enterprise }
        if normalized.contains("team") { return .team }
        if normalized.contains("pro") || normalized.contains("ultra") { return .pro }
        if normalized.contains("plus") { return .plus }
        if normalized.contains("free") || normalized.contains("guest") { return .free }
        return .unknown
    }
}
