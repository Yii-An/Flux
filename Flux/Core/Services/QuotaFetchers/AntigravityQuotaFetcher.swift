import Foundation

actor AntigravityQuotaFetcher: QuotaFetcher {
    nonisolated let providerID: ProviderID = .antigravity

    private let httpClient: HTTPClient

    private let quotaURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels")
    private let tokenURL = URL(string: "https://oauth2.googleapis.com/token")

    init(httpClient: HTTPClient = .shared) {
        self.httpClient = httpClient
    }

    func fetchQuotas(authFiles: [AuthFileInfo]) async -> [String: AccountQuota] {
        let now = Date()
        let candidates = authFiles.filter { $0.provider == .antigravity }
        guard !candidates.isEmpty else { return [:] }

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

        guard let url = quotaURL else {
            return AccountQuota(
                accountKey: accountKey,
                email: file.email,
                kind: .error,
                quota: nil,
                lastUpdated: now,
                message: nil,
                error: "Invalid Antigravity quota URL".localizedStatic()
            )
        }

        var accessToken = file.accessToken
        if shouldAttemptRefresh(file: file) {
            if let refreshed = await refreshAccessToken(from: file) {
                accessToken = refreshed
            }
        }

        do {
            let body = try JSONSerialization.data(withJSONObject: [:], options: [])
            let data = try await httpClient.post(
                url: url,
                body: body,
                headers: [
                    "Authorization": "Bearer \(accessToken)",
                    "User-Agent": "antigravity/1.0 (Flux macOS)",
                    "Content-Type": "application/json",
                    "Accept": "application/json",
                ]
            )

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return AccountQuota(
                    accountKey: accountKey,
                    email: file.email,
                    kind: .error,
                    quota: nil,
                    lastUpdated: now,
                    message: nil,
                    error: "Antigravity response parse failed".localizedStatic()
                )
            }

            let (percentRemaining, resetAt) = extractWorstRemaining(json: json)
            if let percentRemaining {
                let remaining = max(0, min(100, Int(percentRemaining.rounded())))
                let used = max(0, 100 - remaining)
                let metrics = QuotaMetrics(
                    used: used,
                    limit: 100,
                    remaining: remaining,
                    resetAt: resetAt,
                    unit: .credits
                )
                return AccountQuota(
                    accountKey: accountKey,
                    email: file.email,
                    kind: .ok,
                    quota: metrics,
                    lastUpdated: now,
                    message: nil,
                    error: nil
                )
            }

            return AccountQuota(
                accountKey: accountKey,
                email: file.email,
                kind: .ok,
                quota: nil,
                lastUpdated: now,
                message: nil,
                error: nil
            )
        } catch let error as FluxError {
            let kind: QuotaSnapshotKind = (error.code == .authError) ? .authMissing : .error
            return AccountQuota(
                accountKey: accountKey,
                email: file.email,
                kind: kind,
                quota: nil,
                lastUpdated: now,
                message: nil,
                error: error.message
            )
        } catch {
            return AccountQuota(
                accountKey: accountKey,
                email: file.email,
                kind: .error,
                quota: nil,
                lastUpdated: now,
                message: nil,
                error: "Antigravity quota fetch failed".localizedStatic()
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
        let clientId = extra.clientId
        let clientSecret = extra.clientSecret

        var params: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ]
        if let clientId {
            params["client_id"] = clientId
        }
        if let clientSecret {
            params["client_secret"] = clientSecret
        }

        let form = params
            .map { "\($0.key)=\(urlEncode($0.value))" }
            .joined(separator: "&")

        do {
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
                return token
            }
            return nil
        } catch {
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

    private func urlEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    private func normalizedAccountKey(file: AuthFileInfo) -> String {
        if let email = file.email, !email.isEmpty { return email }
        return file.filename
    }
}
