import Foundation

actor AntigravityQuotaDataSource: QuotaDataSource {
    nonisolated let provider: ProviderKind = .antigravity
    nonisolated let source: FluxQuotaSource = .oauthApi

    private let httpClient: HTTPClient
    private let logger: FluxLogger
    private let urlSession: URLSession
    private let cacheStore: AntigravityProjectCacheStore

    private let tokenURL = URL(string: "https://oauth2.googleapis.com/token")

    private static let fetchAvailableModelsURLs: [URL] = [
        "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
        "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
        "https://daily-cloudcode-pa.sandbox.googleapis.com/v1internal:fetchAvailableModels",
    ].compactMap(URL.init(string:))

    private static let loadCodeAssistURLs: [URL] = [
        "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist",
        "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist",
        "https://daily-cloudcode-pa.sandbox.googleapis.com/v1internal:loadCodeAssist",
        "https://autopush-cloudcode-pa.sandbox.googleapis.com/v1internal:loadCodeAssist",
    ].compactMap(URL.init(string:))

    private static let antigravityUserAgent = "antigravity/1.11.3 Darwin/arm64"

    // Default OAuth client (matches CLIProxyAPI/CLIProxyAPIPlus)
    private static let oauthClientId = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    private static let oauthClientSecret = "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"

    private var subscriptionCache: [String: SubscriptionSnapshot] = [:]
    private var projectIdCache: [String: AntigravityProjectCacheStore.ProjectCacheEntry] = [:]
    private var loadedProjectIdCache: [String: String] = [:]

    init(
        httpClient: HTTPClient = .shared,
        logger: FluxLogger = .shared,
        urlSession: URLSession = .shared,
        cacheStore: AntigravityProjectCacheStore = .shared
    ) {
        self.httpClient = httpClient
        self.logger = logger
        self.urlSession = urlSession
        self.cacheStore = cacheStore
    }

    func beginRefreshCycle() async {
        subscriptionCache = [:]
        projectIdCache = await cacheStore.load()
        loadedProjectIdCache = projectIdCache.mapValues(\.projectId)
    }

    func finishRefreshCycle() async {
        let current = projectIdCache.mapValues(\.projectId)
        guard current != loadedProjectIdCache else {
            await logger.log(
                .debug,
                category: LogCategories.quotaAntigravity,
                metadata: ["entries": .int(current.count)],
                message: "Project cache unchanged, skipping save"
            )
            return
        }

        await logger.log(
            .debug,
            category: LogCategories.quotaAntigravity,
            metadata: ["entries": .int(current.count)],
            message: "Project cache updated, saving..."
        )
        await cacheStore.save(projectIdCache)
    }

    func isAvailable(for credential: any Credential) async -> Bool {
        credential.provider == .antigravity && credential.accessToken.isEmpty == false
    }

    func fetchQuota(for credential: any Credential) async throws -> AccountQuotaReport {
        guard credential.provider == .antigravity else {
            throw FluxError(code: .unsupported, message: "Credential provider mismatch")
        }

        let now = Date()

        var context = AuthContext(
            accountKey: credential.accountKey,
            email: credential.email,
            filePath: credential.filePath,
            accessToken: credential.accessToken,
            refreshToken: credential.refreshToken,
            projectHint: credential.metadata["project_id"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        let payload = try await fetchQuotaPayload(context: &context, now: now)
        return AccountQuotaReport(
            provider: .antigravity,
            accountKey: credential.accountKey,
            email: credential.email,
            plan: payload.plan,
            status: .ok,
            source: .oauthApi,
            fetchedAt: now,
            windows: payload.windows,
            errorMessage: nil
        )
    }

    // MARK: - Core flow

    private struct QuotaPayload: Sendable {
        let plan: String?
        let windows: [QuotaWindow]
    }

    private struct AuthContext: Sendable {
        let accountKey: String
        let email: String?
        let filePath: String?
        var accessToken: String
        let refreshToken: String?
        var projectHint: String?
        var usedCachedProjectId: Bool = false
    }

    private func fetchQuotaPayload(context: inout AuthContext, now: Date) async throws -> QuotaPayload {
        let subscription = await resolveSubscriptionSnapshot(context: &context)
        let plan = subscription?.tier

        var projectId: String? = nil
        var usedCached = false

        if let subscription, let pid = subscription.projectId.nonEmpty {
            projectId = pid
            usedCached = true
        } else if let cached = projectIdCache[context.accountKey], cached.isExpired == false {
            projectId = cached.projectId
            usedCached = true
        } else if let hint = context.projectHint.nonEmpty {
            projectId = hint
            usedCached = false
        }

        context.usedCachedProjectId = usedCached

        var requestPayload: [String: Any] = [:]
        if let projectId, projectId.isEmpty == false {
            requestPayload["project"] = projectId
        }

        let first = await fetchAvailableModelsWithFallback(accessToken: context.accessToken, payload: requestPayload)
        switch first {
        case .success(let response):
            return buildPayload(from: response, plan: plan, now: now)
        case .unauthorized:
            // Requirement: 401 triggers refresh then retry once.
            if let refreshed = await refreshAccessTokenIfPossible(context: context) {
                context.accessToken = refreshed
                let retry = await fetchAvailableModelsWithFallback(accessToken: context.accessToken, payload: requestPayload)
                switch retry {
                case .success(let response):
                    return buildPayload(from: response, plan: plan, now: now)
                case .forbidden:
                    return try await handleForbiddenAfterFetch(context: &context, requestPayload: requestPayload, plan: plan, now: now)
                case .rateLimited:
                    throw FluxError(code: .rateLimited, message: "Request rate limited")
                case .unauthorized:
                    throw FluxError(code: .authError, message: "Request unauthorized")
                case .failed(let message):
                    throw FluxError(code: .networkError, message: message)
                }
            }
            throw FluxError(code: .authError, message: "Request unauthorized")
        case .forbidden:
            return try await handleForbiddenAfterFetch(context: &context, requestPayload: requestPayload, plan: plan, now: now)
        case .rateLimited:
            throw FluxError(code: .rateLimited, message: "Request rate limited")
        case .failed(let message):
            throw FluxError(code: .networkError, message: message)
        }
    }

    private func handleForbiddenAfterFetch(
        context: inout AuthContext,
        requestPayload: [String: Any],
        plan: String?,
        now: Date
    ) async throws -> QuotaPayload {
        // Requirement: 403 triggers projectId refresh only when we used cached projectId.
        guard context.usedCachedProjectId else {
            throw FluxError(code: .networkError, message: "Account has no entitlement (403)")
        }

        await logger.log(.warning, category: LogCategories.quotaAntigravity, metadata: ["account": .string(context.accountKey)], message: "403 with cached projectId; retrying loadCodeAssist")

        let refreshed = await fetchSubscriptionSnapshot(accessToken: context.accessToken, projectHint: context.projectHint)
        if let pid = refreshed?.projectId.nonEmpty {
            projectIdCache[context.accountKey] = AntigravityProjectCacheStore.ProjectCacheEntry(
                projectId: pid,
                ttlSeconds: 7 * 24 * 60 * 60,
                updatedAt: Date(),
                source: .loadCodeAssist
            )

            var retryPayload = requestPayload
            retryPayload["project"] = pid
            let retry = await fetchAvailableModelsWithFallback(accessToken: context.accessToken, payload: retryPayload)
            switch retry {
            case .success(let response):
                return buildPayload(from: response, plan: plan, now: now)
            case .unauthorized:
                throw FluxError(code: .authError, message: "Request unauthorized")
            case .forbidden:
                throw FluxError(code: .networkError, message: "Account has no entitlement (403)")
            case .rateLimited:
                throw FluxError(code: .rateLimited, message: "Request rate limited")
            case .failed(let message):
                throw FluxError(code: .networkError, message: message)
            }
        }

        throw FluxError(code: .networkError, message: "Account has no entitlement (403)")
    }

    // MARK: - Subscription / Project resolution

    private struct SubscriptionSnapshot: Sendable {
        let tier: String?
        let projectId: String?
        let fetchedAt: Date
    }

    private func resolveSubscriptionSnapshot(context: inout AuthContext) async -> SubscriptionSnapshot? {
        if let existing = subscriptionCache[context.accountKey], Date().timeIntervalSince(existing.fetchedAt) < 60 {
            return existing
        }

        if let hint = context.projectHint.nonEmpty {
            let snapshot = SubscriptionSnapshot(tier: nil, projectId: hint, fetchedAt: Date())
            subscriptionCache[context.accountKey] = snapshot
            return snapshot
        }

        if let fetched = await fetchSubscriptionSnapshot(accessToken: context.accessToken, projectHint: nil) {
            subscriptionCache[context.accountKey] = fetched
            if let pid = fetched.projectId.nonEmpty {
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

        let result: FetchResult<LoadCodeAssistResponse> = await performWithFallback(
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
            return SubscriptionSnapshot(tier: response.extractedTier, projectId: response.extractedProjectId, fetchedAt: Date())
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
        if let projectHint {
            let trimmed = projectHint.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty == false {
                payload["cloudaicompanionProject"] = trimmed
                metadata["duetProject"] = trimmed
            }
            payload["metadata"] = metadata
        }

        return (try? JSONSerialization.data(withJSONObject: payload, options: [])) ?? Data("{}".utf8)
    }

    // MARK: - Fetch Available Models

    private enum FetchResult<Payload: Sendable>: Sendable {
        case success(Payload)
        case unauthorized
        case forbidden
        case rateLimited
        case failed(String)
    }

    private func fetchAvailableModelsWithFallback(accessToken: String, payload: [String: Any]) async -> FetchResult<FetchAvailableModelsResponse> {
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
    ) async -> FetchResult<Response> {
        var lastRateLimited = false
        var lastMessage: String?

        for url in urls {
            let request = requestBuilder(url)
            do {
                let (data, response) = try await urlSession.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    lastMessage = "Invalid HTTP response"
                    continue
                }

                switch http.statusCode {
                case 200...299:
                    do {
                        let decoded = try decoder.decode(Response.self, from: data)
                        return .success(decoded)
                    } catch {
                        lastMessage = "Response parse failed"
                        continue
                    }
                case 401:
                    return .unauthorized
                case 403:
                    return .forbidden
                case 429:
                    lastRateLimited = true
                    lastMessage = "Rate limited"
                    continue
                default:
                    lastMessage = "HTTP \(http.statusCode)"
                    continue
                }
            } catch {
                lastMessage = String(describing: error)
                continue
            }
        }

        if lastRateLimited {
            return .rateLimited
        }
        return .failed(lastMessage ?? "Request failed")
    }

    // MARK: - Build output

    private func buildPayload(from response: FetchAvailableModelsResponse, plan: String?, now: Date) -> QuotaPayload {
        var windows: [QuotaWindow] = []

        var overallRemaining: Double?
        var overallResetAt: Date?

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var models: [AntigravityModelSnapshot] = []
        models.reserveCapacity(response.models.count)

        for (modelId, info) in response.models.sorted(by: { $0.key < $1.key }) {
            guard let quota = info.quotaInfo else { continue }

            let remainingFraction = quota.remainingFraction ?? 0

            let resetAt: Date? = {
                guard let reset = quota.resetTime.nonEmpty else { return nil }
                if let date = iso.date(from: reset) { return date }
                iso.formatOptions = [.withInternetDateTime]
                return iso.date(from: reset)
            }()

            overallRemaining = min(overallRemaining ?? remainingFraction, remainingFraction)
            if let resetAt {
                overallResetAt = min(overallResetAt ?? resetAt, resetAt)
            }

            models.append(
                AntigravityModelSnapshot(
                    modelId: modelId,
                    displayName: info.displayName.nonEmpty,
                    remainingFraction: remainingFraction,
                    resetTime: quota.resetTime.nonEmpty,
                    resetAt: resetAt
                )
            )
        }

        if let overallRemaining {
            let remainingPercent = max(0, min(100, overallRemaining * 100))
            windows.append(
                QuotaWindow(
                    id: "antigravity.overall",
                    label: "Overall",
                    unit: .percent,
                    usedPercent: max(0, 100 - remainingPercent),
                    remainingPercent: remainingPercent,
                    used: nil,
                    limit: nil,
                    remaining: nil,
                    resetAt: overallResetAt
                ),
            )
        }

        let groups = buildQuotaGroups(from: models)
        windows.reserveCapacity(windows.count + groups.count)

        for group in groups {
            let remainingPercent = max(0, min(100, group.remainingFraction * 100))
            windows.append(
                QuotaWindow(
                    id: "antigravity.group.\(group.groupId)",
                    label: group.label,
                    unit: .percent,
                    usedPercent: max(0, 100 - remainingPercent),
                    remainingPercent: remainingPercent,
                    used: nil,
                    limit: nil,
                    remaining: nil,
                    resetAt: group.resetAt
                )
            )
        }

        return QuotaPayload(plan: plan.nonEmpty, windows: windows)
    }

    // MARK: - Refresh

    private func refreshAccessTokenIfPossible(context: AuthContext) async -> String? {
        guard let url = tokenURL else { return nil }
        guard let refreshToken = context.refreshToken.nonEmpty else { return nil }

        let clientId = Self.oauthClientId
        let clientSecret = Self.oauthClientSecret

        let body = formURLEncoded([
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", clientId),
            ("client_secret", clientSecret),
        ])

        do {
            let data = try await httpClient.post(
                url: url,
                body: body,
                headers: [
                    "Content-Type": "application/x-www-form-urlencoded",
                    "Accept": "application/json",
                ]
            )

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let response = try decoder.decode(GoogleTokenRefreshResponse.self, from: data)
            guard let token = response.accessToken.nonEmpty else { return nil }

            if let filePath = context.filePath.nonEmpty {
                updateAuthFileAfterRefresh(filePath: filePath, accessToken: token, expiresIn: response.expiresIn)
            }

            return token
        } catch {
            return nil
        }
    }

    private func updateAuthFileAfterRefresh(filePath: String, accessToken: String, expiresIn: Int?) {
        guard let data = FileManager.default.contents(atPath: filePath) else { return }
        guard var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

        json["access_token"] = accessToken
        if let expiresIn {
            json["expires_in"] = expiresIn
        }

        let now = Date()
        json["timestamp"] = Int(now.timeIntervalSince1970 * 1000)
        if let expiresIn, expiresIn > 0 {
            let expiresAt = now.addingTimeInterval(TimeInterval(expiresIn))
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
            // Best-effort.
        }
    }

    private func formURLEncoded(_ pairs: [(String, String)]) -> Data {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?/")
        let encoded = pairs.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }

    private struct AntigravityModelSnapshot: Sendable {
        let modelId: String
        let displayName: String?
        let remainingFraction: Double
        let resetTime: String?
        let resetAt: Date?
    }

    private struct AntigravityQuotaGroupSnapshot: Sendable {
        let groupId: String
        let label: String
        let remainingFraction: Double
        let resetAt: Date?
        let sortKey: String
    }

    private func buildQuotaGroups(from models: [AntigravityModelSnapshot]) -> [AntigravityQuotaGroupSnapshot] {
        guard models.isEmpty == false else { return [] }

        let fingerprintGroups = Dictionary(grouping: models, by: quotaFingerprint(for:))
        let groupedModels: [String: [AntigravityModelSnapshot]]

        if fingerprintGroups.count == 1, models.count > 1 {
            groupedModels = Dictionary(grouping: models, by: fallbackGroupKey(for:))
        } else {
            groupedModels = fingerprintGroups
        }

        var groups: [AntigravityQuotaGroupSnapshot] = []
        groups.reserveCapacity(groupedModels.count)

        for (_, entries) in groupedModels {
            let modelIds = entries.map(\.modelId).sorted()
            guard let sortKey = modelIds.first else { continue }
            let groupId = modelIds.joined(separator: "_")

            let remainingFraction = entries.map(\.remainingFraction).min() ?? 0
            let resetAt = entries.compactMap(\.resetAt).min()

            let label = quotaGroupLabel(modelIds: modelIds, entries: entries)

            groups.append(
                AntigravityQuotaGroupSnapshot(
                    groupId: groupId,
                    label: label,
                    remainingFraction: remainingFraction,
                    resetAt: resetAt,
                    sortKey: sortKey
                )
            )
        }

        groups.sort { $0.sortKey < $1.sortKey }
        return groups
    }

    private func quotaFingerprint(for model: AntigravityModelSnapshot) -> String {
        let reset = model.resetTime ?? ""
        return String(format: "%.6f_%@", locale: Locale(identifier: "en_US_POSIX"), model.remainingFraction, reset)
    }

    private func fallbackGroupKey(for model: AntigravityModelSnapshot) -> String {
        let id = model.modelId.lowercased()
        if id.hasPrefix("gemini-3-pro-") { return "gemini-3-pro" }
        if id.hasPrefix("gemini-2.5-flash-") || id.hasPrefix("gemini-2-5-flash-") { return "gemini-2.5-flash" }
        if id.hasPrefix("claude-") { return "claude" }
        if id.hasPrefix("gpt-") { return "gpt" }
        return model.modelId
    }

    private func quotaGroupLabel(modelIds: [String], entries: [AntigravityModelSnapshot]) -> String {
        if entries.count == 1 {
            return entries[0].displayName ?? entries[0].modelId
        }

        if let prefix = commonDisplayNamePrefix(entries.compactMap(\.displayName)) {
            return prefix
        }

        let lowered = modelIds.map { $0.lowercased() }
        let hasClaude = lowered.contains { $0.hasPrefix("claude-") }
        let hasGPT = lowered.contains { $0.hasPrefix("gpt-") }
        if hasClaude, hasGPT {
            return "Claude/GPT"
        }

        if let prefix = commonModelIdPrefix(modelIds) {
            return humanizeModelId(prefix)
        }

        return modelIds.first ?? "Unknown"
    }

    private func commonDisplayNamePrefix(_ names: [String]) -> String? {
        let trimmed = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard trimmed.isEmpty == false else { return nil }
        if trimmed.count == 1 { return trimmed[0] }

        let tokenized = trimmed.map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
        guard let first = tokenized.first else { return nil }

        var commonCount = 0
        for index in 0..<first.count {
            let token = first[index]
            if token.contains("(") { break }
            if tokenized.dropFirst().allSatisfy({ $0.count > index && $0[index] == token }) {
                commonCount += 1
            } else {
                break
            }
        }

        let prefix = first.prefix(commonCount).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.isEmpty ? nil : prefix
    }

    private func commonModelIdPrefix(_ ids: [String]) -> String? {
        let parts = ids.map { $0.split(separator: "-").map(String.init) }
        guard let first = parts.first, first.isEmpty == false else { return nil }

        var commonCount = 0
        for index in 0..<first.count {
            let token = first[index]
            if parts.dropFirst().allSatisfy({ $0.count > index && $0[index] == token }) {
                commonCount += 1
            } else {
                break
            }
        }

        let prefix = first.prefix(commonCount).joined(separator: "-")
        return prefix.isEmpty ? nil : prefix
    }

    private func humanizeModelId(_ prefix: String) -> String {
        let tokens = prefix.split(separator: "-").map(String.init)
        let normalized: [String] = tokens.map { token in
            if token.lowercased() == "gemini" { return "Gemini" }
            if token.lowercased() == "claude" { return "Claude" }
            if token.lowercased() == "gpt" { return "GPT" }
            if token.contains(".") || token.rangeOfCharacter(from: .decimalDigits) != nil { return token }
            return token.prefix(1).uppercased() + token.dropFirst()
        }
        return normalized.joined(separator: " ")
    }
}

private struct GoogleTokenRefreshResponse: Decodable {
    let accessToken: String?
    let expiresIn: Int?
}

private struct LoadCodeAssistResponse: Decodable, Sendable {
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
                value = trimmed.isEmpty ? nil : trimmed
                return
            }
            let container = try decoder.singleValueContainer()
            if let dict = try? container.decode([String: String].self) {
                let candidates = [dict["id"], dict["projectId"], dict["project"]]
                let extracted = candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
                value = extracted
                return
            }
            value = nil
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

private struct FetchAvailableModelsResponse: Decodable, Sendable {
    let models: [String: ModelInfo]

    struct ModelInfo: Decodable, Sendable {
        let quotaInfo: QuotaInfo?
        let displayName: String?

        enum CodingKeys: String, CodingKey {
            case quotaInfo
            case quota_info
            case displayName
            case display_name
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            quotaInfo = (try? container.decode(QuotaInfo.self, forKey: .quotaInfo))
                ?? (try? container.decode(QuotaInfo.self, forKey: .quota_info))
            displayName = (try? container.decode(String.self, forKey: .displayName))
                ?? (try? container.decode(String.self, forKey: .display_name))
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

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self else { return nil }
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
