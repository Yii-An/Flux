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
                    error: message,
                    planType: nil,
                    modelQuotas: []
                )
            }

            let bucketDefinitions: [(key: String, id: String, name: String)] = [
                ("five_hour", "claude.five_hour", "5小时"),
                ("seven_day", "claude.seven_day", "7天"),
                ("seven_day_sonnet", "claude.seven_day_sonnet", "Sonnet 7天"),
                ("seven_day_opus", "claude.seven_day_opus", "Opus 7天"),
            ]

            var modelQuotas: [ModelQuota] = []
            for def in bucketDefinitions {
                guard let bucketJSON = json[def.key] as? [String: Any] else { continue }
                guard let utilization = parseDouble(bucketJSON["utilization"]) else { continue }
                let used = max(0, min(100, utilization))
                let resetAt = parseISO8601Date(bucketJSON["resets_at"])
                modelQuotas.append(ModelQuota(
                    modelId: def.id,
                    displayName: def.name,
                    usedPercent: used,
                    remainingPercent: max(0, 100 - used),
                    resetAt: resetAt
                ))
            }

            if let extraJSON = json["extra_usage"] as? [String: Any] {
                let enabled = (extraJSON["is_enabled"] as? Bool) ?? false
                if enabled, let utilization = parseDouble(extraJSON["utilization"]) {
                    let used = max(0, min(100, utilization))
                    modelQuotas.append(ModelQuota(
                        modelId: "claude.extra_usage",
                        displayName: "额外额度",
                        usedPercent: used,
                        remainingPercent: max(0, 100 - used),
                        resetAt: nil
                    ))
                }
            }

            let primaryForSummary = modelQuotas.first(where: { $0.modelId == "claude.seven_day" })
                ?? modelQuotas.first(where: { $0.modelId == "claude.five_hour" })
                ?? modelQuotas.first

            let metrics: QuotaMetrics?
            if let primaryForSummary {
                metrics = QuotaMetrics(
                    used: Int(primaryForSummary.usedPercent.rounded()),
                    limit: 100,
                    remaining: Int(primaryForSummary.remainingPercent.rounded()),
                    resetAt: primaryForSummary.resetAt,
                    unit: .credits
                )
            } else {
                metrics = nil
            }

            return AccountQuota(
                accountKey: accountKey,
                email: file.email,
                kind: .ok,
                quota: metrics,
                lastUpdated: now,
                message: nil,
                error: nil,
                planType: nil,
                modelQuotas: modelQuotas
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
                error: error.message,
                planType: nil,
                modelQuotas: []
            )
        } catch {
            return AccountQuota(
                accountKey: accountKey,
                email: file.email,
                kind: .error,
                quota: nil,
                lastUpdated: now,
                message: nil,
                error: "Claude quota fetch failed".localizedStatic(),
                planType: nil,
                modelQuotas: []
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
