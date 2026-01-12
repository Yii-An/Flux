import Foundation

actor ClaudeQuotaFetcher: QuotaFetcher {
    nonisolated let providerID: ProviderID = .claude

    private let httpClient: HTTPClient

    init(httpClient: HTTPClient = .shared) {
        self.httpClient = httpClient
    }

    func fetchQuotas(authFiles: [AuthFileInfo]) async -> [String: AccountQuota] {
        let now = Date()

        let candidates = authFiles.filter { $0.provider == .claude }
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

        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            return AccountQuota(
                accountKey: accountKey,
                email: file.email,
                kind: .error,
                quota: nil,
                lastUpdated: now,
                message: nil,
                error: "Invalid Claude usage URL".localizedStatic()
            )
        }

        do {
            let data = try await httpClient.get(
                url: url,
                headers: [
                    "Accept": "application/json",
                    "Authorization": "Bearer \(file.accessToken)",
                    "anthropic-beta": "oauth-2025-04-20",
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
                    error: "Claude response parse failed".localizedStatic()
                )
            }

            if let apiErrorType = (json["type"] as? String), apiErrorType == "error" {
                let errorType = ((json["error"] as? [String: Any])?["type"] as? String) ?? "unknown"
                let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? "Claude API error".localizedStatic()
                let kind: QuotaSnapshotKind = (errorType == "authentication_error") ? .authMissing : .error
                return AccountQuota(
                    accountKey: accountKey,
                    email: file.email,
                    kind: kind,
                    quota: nil,
                    lastUpdated: now,
                    message: nil,
                    error: message
                )
            }

            let buckets = ["seven_day", "five_hour", "seven_day_sonnet", "seven_day_opus"]
            for bucket in buckets {
                guard let bucketJSON = json[bucket] as? [String: Any] else { continue }
                guard let utilization = parseDouble(bucketJSON["utilization"]) else { continue }
                let used = max(0, min(100, Int(utilization.rounded())))
                let resetAt = parseISO8601Date(bucketJSON["resets_at"])
                let metrics = QuotaMetrics(
                    used: used,
                    limit: 100,
                    remaining: max(0, 100 - used),
                    resetAt: resetAt,
                    unit: .credits
                )
                return AccountQuota(
                    accountKey: accountKey,
                    email: file.email,
                    kind: .ok,
                    quota: metrics,
                    lastUpdated: now,
                    message: "bucket=\(bucket)",
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
                error: "Claude quota fetch failed".localizedStatic()
            )
        }
    }

    private func parseDouble(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }

    private func parseISO8601Date(_ value: Any?) -> Date? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
