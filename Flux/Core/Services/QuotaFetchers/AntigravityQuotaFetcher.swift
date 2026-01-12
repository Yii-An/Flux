import Foundation

actor AntigravityQuotaFetcher: QuotaFetcher {
    nonisolated let providerID: ProviderID = .antigravity

    private let httpClient: HTTPClient

    private let tokenURL = URL(string: "https://oauth2.googleapis.com/token")
    private let logger: FluxLogger

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

    // Matches Quotio + CLIProxyAPI public constants.
    private static let oauthClientId = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    private static let oauthClientSecret = "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"

    init(httpClient: HTTPClient = .shared, logger: FluxLogger = .shared) {
        self.httpClient = httpClient
        self.logger = logger
    }

    func fetchQuotas(authFiles: [AuthFileInfo]) async -> [String: AccountQuota] {
        let now = Date()
        let candidates = authFiles.filter { $0.provider == .antigravity }
        guard !candidates.isEmpty else { return [:] }

        await logger.debug("Antigravity: scanning \(candidates.count) auth file(s)", category: "Quota.Antigravity")

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

        return results
    }

    private func fetchQuota(for file: AuthFileInfo, now: Date) async -> AccountQuota {
        let accountKey = normalizedAccountKey(file: file)

        var accessToken = file.accessToken
        if shouldAttemptRefresh(file: file) {
            if let refreshed = await refreshAccessToken(from: file) {
                accessToken = refreshed
            }
        }

        do {
            let initialProjectHint = readProjectHint(filePath: file.filePath)
            if let initialProjectHint {
                await logger.debug("Antigravity: found project hint \(initialProjectHint)", category: "Quota.Antigravity")
            }

            let subscription = await fetchSubscription(accessToken: accessToken, projectHint: initialProjectHint)
            let planType = subscription.tier.map(mapPlanType) ?? .unknown

            var quotaPayload: [String: Any] = [:]
            let resolvedProjectId = (subscription.projectId ?? initialProjectHint)
            if let projectId = resolvedProjectId, projectId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                quotaPayload["project"] = projectId
            }

            let json = try await fetchAvailableModels(
                accessToken: accessToken,
                payload: quotaPayload
            )

            let groupQuotas = buildGroupedModelQuotas(json: json)
            if groupQuotas.isEmpty {
                let keys = Array(json.keys).sorted().joined(separator: ", ")
                await logger.warning("Antigravity: models parsed empty; top-level keys=[\(keys)]", category: "Quota.Antigravity")
            }
            let summary = summarize(groupQuotas)

            return AccountQuota(
                accountKey: accountKey,
                email: file.email,
                kind: .ok,
                quota: summary.metrics,
                lastUpdated: now,
                message: nil,
                error: nil,
                planType: planType,
                modelQuotas: groupQuotas
            )
        } catch let error as FluxError {
            let kind: QuotaSnapshotKind = (error.code == .authError) ? .authMissing : .error
            await logger.error("Antigravity: fetch failed (\(error.code.rawValue)) \(error.message) \(error.details ?? "")", category: "Quota.Antigravity")
            return AccountQuota(
                accountKey: accountKey,
                email: file.email,
                kind: kind,
                quota: nil,
                lastUpdated: now,
                message: nil,
                error: error.message,
                planType: nil,
                modelQuotas: []
            )
        } catch {
            await logger.error("Antigravity: fetch failed \(String(describing: error))", category: "Quota.Antigravity")
            return AccountQuota(
                accountKey: accountKey,
                email: file.email,
                kind: .error,
                quota: nil,
                lastUpdated: now,
                message: nil,
                error: "Antigravity quota fetch failed".localizedStatic(),
                planType: nil,
                modelQuotas: []
            )
        }
    }

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

    private func extractWorstRemaining(json: [String: Any]) -> (percentRemaining: Double?, resetAt: Date?) {
        guard let models = json["models"] as? [String: Any] else { return (nil, nil) }

        var minFraction: Double?
        var earliestReset: Date?

        for (_, value) in models {
            guard let modelDict = value as? [String: Any] else { continue }
            guard let quotaInfo = modelDict["quotaInfo"] as? [String: Any] ?? modelDict["quota_info"] as? [String: Any] else { continue }

            let remainingFraction = parseDouble(quotaInfo["remainingFraction"] ?? quotaInfo["remaining_fraction"])
            if let remainingFraction {
                minFraction = min(minFraction ?? remainingFraction, remainingFraction)
            }

            if let resetString = quotaInfo["resetTime"] as? String ?? quotaInfo["reset_time"] as? String,
               let resetDate = parseISO8601Date(resetString) {
                earliestReset = min(earliestReset ?? resetDate, resetDate)
            }
        }

        if let minFraction {
            return (percentRemaining: minFraction * 100.0, resetAt: earliestReset)
        }
        return (nil, earliestReset)
    }

    private func parseDouble(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String, let double = Double(string) { return double }
        return nil
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
            // Best-effort persistence; quota fetching still works with in-memory token.
        }
    }

    private struct SubscriptionResult: Sendable {
        let tier: String?
        let projectId: String?
    }

    private func fetchSubscription(accessToken: String) async -> SubscriptionResult {
        await fetchSubscription(accessToken: accessToken, projectHint: nil)
    }

    private func fetchSubscription(accessToken: String, projectHint: String?) async -> SubscriptionResult {
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

        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return SubscriptionResult(tier: nil, projectId: nil)
        }

        for url in Self.loadCodeAssistURLs {
            do {
                await logger.debug("Antigravity: loadCodeAssist -> \(url.absoluteString)", category: "Quota.Antigravity")
                let data = try await httpClient.post(
                    url: url,
                    body: body,
                    headers: [
                        "Authorization": "Bearer \(accessToken)",
                        "User-Agent": Self.antigravityUserAgent,
                        "Content-Type": "application/json",
                        "Accept": "application/json",
                    ]
                )

                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    await logger.warning("Antigravity: loadCodeAssist parse failed \(url.absoluteString)", category: "Quota.Antigravity")
                    continue
                }

                let projectId = extractProjectId(json["cloudaicompanionProject"] ?? json["cloudaicompanion_project"])

                let paidTier = json["paidTier"] as? [String: Any]
                let currentTier = json["currentTier"] as? [String: Any]
                let userStatus = json["userStatus"] as? [String: Any]
                let userTier = userStatus?["userTier"] as? [String: Any]

                let tierId =
                    (paidTier?["id"] as? String)
                    ?? (currentTier?["id"] as? String)
                    ?? (userTier?["id"] as? String)
                let tierName =
                    (paidTier?["name"] as? String)
                    ?? (currentTier?["name"] as? String)
                    ?? (userTier?["name"] as? String)

                let tier = tierId ?? tierName

                await logger.debug("Antigravity: loadCodeAssist ok tier=\(tier ?? "nil") projectId=\(projectId ?? "nil")", category: "Quota.Antigravity")
                return SubscriptionResult(tier: tier, projectId: projectId)
            } catch let error as FluxError {
                await logger.warning("Antigravity: loadCodeAssist failed \(url.absoluteString) (\(error.code.rawValue)) \(error.message) \(error.details ?? "")", category: "Quota.Antigravity")
                continue
            } catch {
                await logger.warning("Antigravity: loadCodeAssist failed \(url.absoluteString) \(String(describing: error))", category: "Quota.Antigravity")
                continue
            }
        }

        return SubscriptionResult(tier: nil, projectId: nil)
    }

    private func fetchAvailableModels(accessToken: String, payload: [String: Any]) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: payload, options: [])

        var lastError: FluxError?
        for url in Self.fetchAvailableModelsURLs {
            do {
                await logger.debug("Antigravity: fetchAvailableModels -> \(url.absoluteString) payloadKeys=\(payload.keys.sorted())", category: "Quota.Antigravity")
                let data = try await httpClient.post(
                    url: url,
                    body: body,
                    headers: [
                        "Authorization": "Bearer \(accessToken)",
                        "User-Agent": Self.antigravityUserAgent,
                        "Content-Type": "application/json",
                        "Accept": "application/json",
                    ]
                )
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    await logger.warning("Antigravity: fetchAvailableModels parse failed \(url.absoluteString)", category: "Quota.Antigravity")
                    continue
                }
                return json
            } catch let error as FluxError {
                lastError = error
                await logger.warning("Antigravity: fetchAvailableModels failed \(url.absoluteString) (\(error.code.rawValue)) \(error.message) \(error.details ?? "")", category: "Quota.Antigravity")
                continue
            } catch {
                await logger.warning("Antigravity: fetchAvailableModels failed \(url.absoluteString) \(String(describing: error))", category: "Quota.Antigravity")
                continue
            }
        }

        if let lastError { throw lastError }
        throw FluxError(code: .networkError, message: "Antigravity request failed", details: "No available endpoint succeeded")
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
}
