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
            var headers: [String: String] = [
                "Accept": "application/json",
                "Authorization": "Bearer \(accessToken)",
            ]

            let idTokenClaims = readCodexIDTokenClaims(filePath: file.filePath)
            let chatgptAccountId = resolveChatgptAccountId(file: file, idTokenClaims: idTokenClaims)
            if let chatgptAccountId, !chatgptAccountId.isEmpty {
                headers["Chatgpt-Account-Id"] = chatgptAccountId
            }

            let data = try await httpClient.get(
                url: url,
                headers: headers
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

            let planTypeRaw = (json["plan_type"] as? String) ?? (json["planType"] as? String)
            let planType = normalizePlanType(planTypeRaw) ?? normalizePlanType(idTokenClaims?.planType)
            let accountPlanType = planType.map(mapPlanType) ?? .unknown

            let rateLimit = json["rate_limit"] as? [String: Any]
            let codeReviewLimit = json["code_review_rate_limit"] as? [String: Any]

            let primaryWindow = parseCodexWindow(rateLimit?["primary_window"] as? [String: Any], now: now)
            let secondaryWindow = parseCodexWindow(rateLimit?["secondary_window"] as? [String: Any], now: now)
            let codeReviewWindow = parseCodexWindow(codeReviewLimit?["primary_window"] as? [String: Any], now: now)

            var modelQuotas: [ModelQuota] = []
            if let quota = buildCodexModelQuota(id: "codex.primary_window", name: "5小时限额", window: primaryWindow) {
                modelQuotas.append(quota)
            }
            if let quota = buildCodexModelQuota(id: "codex.secondary_window", name: "周限额", window: secondaryWindow) {
                modelQuotas.append(quota)
            }
            if let quota = buildCodexModelQuota(id: "codex.code_review", name: "代码审查限额", window: codeReviewWindow) {
                modelQuotas.append(quota)
            }

            let primaryUsedPercent = primaryWindow.usedPercent

            if let primaryUsedPercent {
                let used = max(0, min(100, Int(primaryUsedPercent.rounded())))
                let metrics = QuotaMetrics(
                    used: used,
                    limit: 100,
                    remaining: max(0, 100 - used),
                    resetAt: primaryWindow.resetAt,
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
                    error: nil,
                    planType: accountPlanType,
                    modelQuotas: modelQuotas
                )
            }

            return AccountQuota(
                accountKey: accountKey,
                email: file.email,
                kind: .ok,
                quota: nil,
                lastUpdated: now,
                message: planType,
                error: nil,
                planType: accountPlanType,
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
                error: "Codex quota fetch failed".localizedStatic(),
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

    private struct CodexIDTokenClaims: Sendable {
        let accountId: String?
        let planType: String?
    }

    private struct CodexWindow: Sendable {
        let usedPercent: Double?
        let resetAt: Date?
    }

    private func buildCodexModelQuota(id: String, name: String, window: CodexWindow) -> ModelQuota? {
        guard let usedPercent = window.usedPercent ?? (window.resetAt != nil ? 100.0 : nil) else { return nil }
        let used = max(0, min(100, usedPercent))
        return ModelQuota(
            modelId: id,
            displayName: name,
            usedPercent: used,
            remainingPercent: max(0, 100 - used),
            resetAt: window.resetAt
        )
    }

    private func parseCodexWindow(_ dict: [String: Any]?, now: Date) -> CodexWindow {
        guard let dict else { return CodexWindow(usedPercent: nil, resetAt: nil) }

        let usedPercent = parseDouble(dict["used_percent"] ?? dict["usedPercent"])

        let resetAt: Date?
        if let reset = parseDouble(dict["reset_at"] ?? dict["resetAt"]) {
            resetAt = Date(timeIntervalSince1970: reset)
        } else if let resetAfter = parseDouble(dict["reset_after_seconds"] ?? dict["resetAfterSeconds"]) {
            resetAt = now.addingTimeInterval(resetAfter)
        } else {
            resetAt = nil
        }

        return CodexWindow(usedPercent: usedPercent, resetAt: resetAt)
    }

    private func resolveChatgptAccountId(file: AuthFileInfo, idTokenClaims: CodexIDTokenClaims?) -> String? {
        if let id = file.accountId, id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return id
        }
        return idTokenClaims?.accountId
    }

    private func mapPlanType(_ value: String) -> AccountPlanType {
        switch normalizePlanType(value) {
        case "free", "guest":
            return .free
        case "plus":
            return .plus
        case "pro":
            return .pro
        case "team":
            return .team
        case "enterprise":
            return .enterprise
        default:
            return .unknown
        }
    }

    private func normalizePlanType(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }

    private func parseDouble(_ value: Any?) -> Double? {
        if let double = value as? Double, double.isFinite { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String, let parsed = Double(string), parsed.isFinite { return parsed }
        return nil
    }

    private func readCodexIDTokenClaims(filePath: String) -> CodexIDTokenClaims? {
        guard let data = FileManager.default.contents(atPath: filePath) else { return nil }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }

        let idToken = (json["id_token"] as? String) ?? (json["idToken"] as? String)
        guard let idToken, let payload = decodeJWTPayload(idToken) else { return nil }

        let auth = payload["https://api.openai.com/auth"] as? [String: Any]
        let accountId = (auth?["chatgpt_account_id"] as? String) ?? (payload["chatgpt_account_id"] as? String)
        let planType = (auth?["chatgpt_plan_type"] as? String) ?? (payload["chatgpt_plan_type"] as? String)
        return CodexIDTokenClaims(accountId: accountId, planType: planType)
    }

    private func decodeJWTPayload(_ jwt: String) -> [String: Any]? {
        let segments = jwt.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        let payloadSegment = String(segments[1])
        guard let decoded = decodeBase64URL(payloadSegment) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any] else { return nil }
        return json
    }

    private func decodeBase64URL(_ input: String) -> Data? {
        var base64 = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - (base64.count % 4)) % 4
        base64 += String(repeating: "=", count: padding)
        return Data(base64Encoded: base64)
    }
}
