import Foundation

actor CodexQuotaDataSource: QuotaDataSource {
    nonisolated let provider: ProviderKind = .codex
    nonisolated let source: FluxQuotaSource = .oauthApi

    private let httpClient: HTTPClient
    private let logger: FluxLogger

    init(httpClient: HTTPClient = .shared, logger: FluxLogger = .shared) {
        self.httpClient = httpClient
        self.logger = logger
    }

    func isAvailable(for credential: any Credential) async -> Bool {
        credential.provider == .codex && credential.accessToken.isEmpty == false
    }

    func fetchQuota(for credential: any Credential) async throws -> AccountQuotaReport {
        guard credential.provider == .codex else {
            throw FluxError(code: .unsupported, message: "Credential provider mismatch")
        }

        let now = Date()
        let accountKey = credential.accountKey
        let email = credential.email

        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            throw FluxError(code: .networkError, message: "Invalid Codex usage URL")
        }

        var accessToken = credential.accessToken
        let chatgptAccountId = credential.metadata["account_id"].nonEmpty

        do {
            let response = try await fetchUsage(url: url, accessToken: accessToken, chatgptAccountId: chatgptAccountId)
            return mapUsage(response, accountKey: accountKey, email: email, fetchedAt: now)
        } catch let error as FluxError where error.code == .authError {
            // Attempt refresh once, then retry.
            guard let refreshed = try? await refreshAndPersistIfPossible(credential: credential) else {
                throw error
            }
            accessToken = refreshed.accessToken
            let response = try await fetchUsage(url: url, accessToken: accessToken, chatgptAccountId: chatgptAccountId)
            return mapUsage(response, accountKey: accountKey, email: email, fetchedAt: now)
        }
    }

    // MARK: - Network / Decode

    private func fetchUsage(url: URL, accessToken: String, chatgptAccountId: String?) async throws -> CodexUsageResponse {
        var headers: [String: String] = [
            "Accept": "application/json",
            "Authorization": "Bearer \(accessToken)",
        ]
        if let chatgptAccountId, chatgptAccountId.isEmpty == false {
            headers["Chatgpt-Account-Id"] = chatgptAccountId
        }

        let data = try await httpClient.get(url: url, headers: headers)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CodexUsageResponse.self, from: data)
    }

    private func mapUsage(_ response: CodexUsageResponse, accountKey: String, email: String?, fetchedAt: Date) -> AccountQuotaReport {
        let windows: [QuotaWindow] = [
            makeWindow(id: "codex.primary_window", label: "5小时限额", window: response.rateLimit?.primaryWindow, now: fetchedAt),
            makeWindow(id: "codex.secondary_window", label: "周限额", window: response.rateLimit?.secondaryWindow, now: fetchedAt),
            makeWindow(id: "codex.code_review", label: "代码审查限额", window: response.codeReviewRateLimit?.primaryWindow, now: fetchedAt),
        ].compactMap { $0 }

        return AccountQuotaReport(
            provider: .codex,
            accountKey: accountKey,
            email: email,
            plan: response.planType.nonEmpty,
            status: .ok,
            source: .oauthApi,
            fetchedAt: fetchedAt,
            windows: windows,
            errorMessage: nil
        )
    }

    private func makeWindow(id: String, label: String, window: CodexUsageResponse.RateLimit.Window?, now: Date) -> QuotaWindow? {
        guard let window else { return nil }

        let usedPercent = window.usedPercent
        let resetAt: Date? = {
            if let epoch = window.resetAt, epoch.isFinite {
                return Date(timeIntervalSince1970: epoch)
            }
            if let seconds = window.resetAfterSeconds, seconds.isFinite {
                return now.addingTimeInterval(seconds)
            }
            return nil
        }()

        if usedPercent == nil, resetAt == nil { return nil }

        let used = usedPercent.map { max(0, min(100, $0)) }
        return QuotaWindow(
            id: id,
            label: label,
            unit: .percent,
            usedPercent: used,
            remainingPercent: used.map { max(0, 100 - $0) },
            used: nil,
            limit: nil,
            remaining: nil,
            resetAt: resetAt
        )
    }

    // MARK: - Refresh + Persistence (writeback)

    private func refreshAndPersistIfPossible(credential: any Credential) async throws -> CLIProxyCredential {
        guard let refreshToken = credential.refreshToken.nonEmpty else {
            throw FluxError(code: .authError, message: "Codex refresh token missing")
        }
        guard let filePath = credential.filePath.nonEmpty else {
            throw FluxError(code: .authError, message: "Codex auth file path missing")
        }

        let clientIdHint = credential.metadata["client_id"].nonEmpty

        guard let url = URL(string: "https://auth.openai.com/oauth/token") else {
            throw FluxError(code: .networkError, message: "Invalid token refresh URL")
        }

        let req = CodexTokenRefreshRequest(
            grantType: "refresh_token",
            refreshToken: refreshToken,
            clientId: clientIdHint
        )
        let encoder = JSONEncoder()
        let body = try encoder.encode(req)

        let data = try await httpClient.post(
            url: url,
            body: body,
            headers: ["Content-Type": "application/json", "Accept": "application/json"]
        )

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let refreshed = try decoder.decode(CodexTokenRefreshResponse.self, from: data)

        guard let newAccessToken = refreshed.accessToken.nonEmpty else {
            throw FluxError(code: .authError, message: "Codex refresh returned empty access token")
        }

        // Update file in-place.
        try persistRefreshedToken(
            filePath: filePath,
            newAccessToken: newAccessToken,
            newRefreshToken: refreshed.refreshToken.nonEmpty,
            expiresIn: refreshed.expiresIn
        )

        await logger.log(.debug, category: LogCategories.quotaCodex, metadata: ["path": .string(filePath)], message: "Codex token refreshed and persisted")

        return CLIProxyAuthFileReader.decodeCredential(from: URL(fileURLWithPath: filePath)) ?? CLIProxyCredential(
            provider: .codex,
            sourceType: .cliProxyAuthDir,
            accountKey: credential.accountKey,
            email: credential.email,
            accessToken: newAccessToken,
            refreshToken: refreshed.refreshToken.nonEmpty ?? credential.refreshToken,
            expiresAt: refreshed.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
            filePath: filePath,
            metadata: credential.metadata
        )
    }

    private func persistRefreshedToken(filePath: String, newAccessToken: String, newRefreshToken: String?, expiresIn: Int?) throws {
        let url = URL(fileURLWithPath: filePath)
        let data = try Data(contentsOf: url)
        guard var json = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw FluxError(code: .parseError, message: "Codex auth file parse failed")
        }

        json["type"] = (json["type"] as? String)?.isEmpty == false ? json["type"] : "codex"
        json["access_token"] = newAccessToken
        if let newRefreshToken {
            json["refresh_token"] = newRefreshToken
        }

        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        json["last_refresh"] = iso.string(from: now)
        if let expiresIn, expiresIn > 0 {
            json["expired"] = iso.string(from: now.addingTimeInterval(TimeInterval(expiresIn)))
        }

        let out = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        try out.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
    }
}

private struct CodexUsageResponse: Decodable, Sendable {
    let planType: String?
    let rateLimit: RateLimit?
    let codeReviewRateLimit: RateLimit?

    struct RateLimit: Decodable, Sendable {
        let primaryWindow: Window?
        let secondaryWindow: Window?

        struct Window: Decodable, Sendable {
            let usedPercent: Double?
            let resetAt: Double?
            let resetAfterSeconds: Double?
        }
    }
}

private struct CodexTokenRefreshRequest: Encodable {
    let grantType: String
    let refreshToken: String
    let clientId: String?

    enum CodingKeys: String, CodingKey {
        case grantType = "grant_type"
        case refreshToken = "refresh_token"
        case clientId = "client_id"
    }
}

private struct CodexTokenRefreshResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int?
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self else { return nil }
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
