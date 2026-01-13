import Foundation

actor CopilotQuotaFetcher: QuotaFetcher {
    nonisolated let providerID: ProviderID = .copilot

    private let httpClient: HTTPClient
    private let logger: FluxLogger

    init(httpClient: HTTPClient = .shared, logger: FluxLogger = .shared) {
        self.httpClient = httpClient
        self.logger = logger
    }

    func fetchQuotas(authFiles: [AuthFileInfo]) async -> [String: AccountQuota] {
        let now = Date()

        let candidates = authFiles.filter { $0.provider == .copilot }
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
        let accountKey = file.email ?? file.filename
        let token = file.accessToken

        guard let url = URL(string: "https://api.github.com/copilot_internal/user") else {
            return AccountQuota(
                accountKey: accountKey,
                email: file.email,
                kind: .error,
                quota: nil,
                lastUpdated: now,
                message: nil,
                error: "Invalid Copilot entitlement URL".localizedStatic()
            )
        }

        do {
            let data = try await httpClient.get(
                url: url,
                headers: [
                    "Accept": "application/vnd.github+json",
                    "Authorization": "Bearer \(token)",
                    "X-GitHub-Api-Version": "2022-11-28",
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
                    error: "Copilot response parse failed".localizedStatic()
                )
            }

            let plan = (json["copilot_plan"] as? String)
                ?? (json["access_type_sku"] as? String)

            let resetAt = parseResetDate(from: json)

            if let metrics = extractQuotaMetrics(from: json, resetAt: resetAt) {
                await logger.log(.debug, category: LogCategories.quotaCopilot, metadata: ["account": .string(accountKey)], message: "parsed quota_snapshots")
                return AccountQuota(
                    accountKey: accountKey,
                    email: file.email,
                    kind: .ok,
                    quota: metrics,
                    lastUpdated: now,
                    message: plan,
                    error: nil
                )
            }

            return AccountQuota(
                accountKey: accountKey,
                email: file.email,
                kind: .ok,
                quota: nil,
                lastUpdated: now,
                message: plan,
                error: nil
            )
        } catch let error as FluxError {
            if error.code == .authError {
                return AccountQuota(
                    accountKey: accountKey,
                    email: file.email,
                    kind: .authMissing,
                    quota: nil,
                    lastUpdated: now,
                    message: nil,
                    error: error.message
                )
            }
            return AccountQuota(
                accountKey: accountKey,
                email: file.email,
                kind: .error,
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
                error: "Copilot quota fetch failed".localizedStatic()
            )
        }
    }

    private func extractQuotaMetrics(from json: [String: Any], resetAt: Date?) -> QuotaMetrics? {
        guard let snapshots = json["quota_snapshots"] as? [String: Any] else { return nil }

        let preferred = ["premium_interactions", "chat", "completions"]
        for key in preferred {
            guard let snapshot = snapshots[key] as? [String: Any] else { continue }

            if let remaining = parseInt(snapshot["remaining"]), let entitlement = parseInt(snapshot["entitlement"]) {
                let used = max(0, entitlement - remaining)
                return QuotaMetrics(
                    used: used,
                    limit: entitlement,
                    remaining: remaining,
                    resetAt: resetAt,
                    unit: .requests
                )
            }

            if let percentRemaining = parseDouble(snapshot["percent_remaining"]) {
                let remaining = max(0, min(100, Int(percentRemaining.rounded())))
                let used = max(0, 100 - remaining)
                return QuotaMetrics(
                    used: used,
                    limit: 100,
                    remaining: remaining,
                    resetAt: resetAt,
                    unit: .credits
                )
            }
        }

        return nil
    }

    private func parseResetDate(from json: [String: Any]) -> Date? {
        let keys = ["quota_reset_date_utc", "quota_reset_date", "limited_user_reset_date"]
        for key in keys {
            if let date = parseDate(json[key]) {
                return date
            }
        }
        return nil
    }

    private func parseInt(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String, let int = Int(string) { return int }
        return nil
    }

    private func parseDouble(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String, let double = Double(string) { return double }
        return nil
    }

    private func parseDate(_ value: Any?) -> Date? {
        guard let string = value as? String, !string.isEmpty else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: string) {
            return date
        }

        let dateOnlyFormatter = DateFormatter()
        dateOnlyFormatter.dateFormat = "yyyy-MM-dd"
        return dateOnlyFormatter.date(from: string)
    }
}
