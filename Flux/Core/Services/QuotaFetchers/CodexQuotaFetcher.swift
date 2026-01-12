import Foundation

actor CodexQuotaFetcher: QuotaFetcher {
    nonisolated let providerID: ProviderID = .codex

    private let httpClient: HTTPClient

    init(httpClient: HTTPClient = .shared) {
        self.httpClient = httpClient
    }

    func fetchQuotas(authFiles: [AuthFileInfo]) async -> [String: AccountQuota] {
        let now = Date()
        let candidates = authFiles.filter { $0.provider == .codex }
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

        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            return AccountQuota(
                accountKey: accountKey,
                email: file.email,
                kind: .error,
                quota: nil,
                lastUpdated: now,
                message: nil,
                error: "Invalid Codex usage URL".localizedStatic()
            )
        }

        var accessToken = file.accessToken
        if shouldAttemptRefresh(file: file) {
            if let refreshed = await refreshAccessToken(from: file) {
                accessToken = refreshed
            }
        }

        do {
            let data = try await httpClient.get(
                url: url,
                headers: [
                    "Accept": "application/json",
                    "Authorization": "Bearer \(accessToken)",
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
                    error: "Codex response parse failed".localizedStatic()
                )
            }

            let planType = json["plan_type"] as? String
            let (usedPercent, resetAt) = extractPrimaryWindow(json["rate_limit"] as? [String: Any])

            if let usedPercent {
                let used = max(0, min(100, usedPercent))
                let metrics = QuotaMetrics(
                    used: used,
                    limit: 100,
                    remaining: max(0, 100 - used),
                    resetAt: resetAt,
                    unit: .credits
                )
                let planInfo = planType.map { "plan=\($0)" } ?? "plan=unknown"
                return AccountQuota(
                    accountKey: accountKey,
                    email: file.email,
                    kind: .ok,
                    quota: metrics,
                    lastUpdated: now,
                    message: planInfo,
                    error: nil
                )
            }

            return AccountQuota(
                accountKey: accountKey,
                email: file.email,
                kind: .ok,
                quota: nil,
                lastUpdated: now,
                message: planType,
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
                error: "Codex quota fetch failed".localizedStatic()
            )
        }
    }

    private func shouldAttemptRefresh(file: AuthFileInfo) -> Bool {
        guard file.refreshToken != nil else { return false }
        guard let expiredAt = file.expiredAt else { return false }
        return expiredAt <= Date().addingTimeInterval(60)
    }

    private func refreshAccessToken(from file: AuthFileInfo) async -> String? {
        guard let url = URL(string: "https://auth.openai.com/oauth/token") else { return nil }
        guard let refreshToken = file.refreshToken, !refreshToken.isEmpty else { return nil }

        let clientId = readClientIdHint(filePath: file.filePath)
        var bodyDict: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ]
        if let clientId {
            bodyDict["client_id"] = clientId
        }

        guard let body = try? JSONSerialization.data(withJSONObject: bodyDict, options: []) else { return nil }

        do {
            let data = try await httpClient.post(
                url: url,
                body: body,
                headers: [
                    "Content-Type": "application/json",
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

    private func readClientIdHint(filePath: String) -> String? {
        guard let data = FileManager.default.contents(atPath: filePath) else { return nil }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let value = (json["client_id"] as? String) ?? (json["clientId"] as? String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private func extractPrimaryWindow(_ rateLimit: [String: Any]?) -> (usedPercent: Int?, resetAt: Date?) {
        guard let rateLimit else { return (nil, nil) }
        guard let primary = rateLimit["primary_window"] as? [String: Any] else { return (nil, nil) }

        let usedPercent: Int?
        if let int = primary["used_percent"] as? Int {
            usedPercent = int
        } else if let number = primary["used_percent"] as? NSNumber {
            usedPercent = number.intValue
        } else {
            usedPercent = nil
        }

        let resetAt: Date?
        if let reset = primary["reset_at"] as? Int {
            resetAt = Date(timeIntervalSince1970: TimeInterval(reset))
        } else if let number = primary["reset_at"] as? NSNumber {
            resetAt = Date(timeIntervalSince1970: TimeInterval(number.intValue))
        } else {
            resetAt = nil
        }

        return (usedPercent, resetAt)
    }
}
