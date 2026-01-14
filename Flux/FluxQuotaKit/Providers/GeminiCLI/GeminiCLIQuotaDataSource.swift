import Foundation

actor GeminiCLIQuotaDataSource: QuotaDataSource {
    nonisolated let provider: ProviderKind = .geminiCLI
    nonisolated let source: FluxQuotaSource = .oauthApi

    private let httpClient: HTTPClient
    private let logger: FluxLogger

    init(httpClient: HTTPClient = .shared, logger: FluxLogger = .shared) {
        self.httpClient = httpClient
        self.logger = logger
    }

    func isAvailable(for credential: any Credential) async -> Bool {
        credential.provider == .geminiCLI && credential.accessToken.isEmpty == false
    }

    func fetchQuota(for credential: any Credential) async throws -> AccountQuotaReport {
        guard credential.provider == .geminiCLI else {
            throw FluxError(code: .unsupported, message: "Credential provider mismatch")
        }

        let now = Date()

        guard let projectId = credential.metadata["project_id"].nonEmpty else {
            throw FluxError(code: .authError, message: "Gemini CLI project_id missing")
        }

        guard let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota") else {
            throw FluxError(code: .networkError, message: "Invalid Gemini CLI quota URL")
        }

        do {
            let response = try await fetchQuotaResponse(url: url, accessToken: credential.accessToken, projectId: projectId)
            let windows = buildWindows(from: response, now: now)
            return AccountQuotaReport(
                provider: .geminiCLI,
                accountKey: credential.accountKey,
                email: credential.email,
                plan: nil,
                status: .ok,
                source: .oauthApi,
                fetchedAt: now,
                windows: windows,
                errorMessage: nil
            )
        } catch let error as FluxError where error.code == .authError {
            guard credential.refreshToken.nonEmpty != nil else { throw error }

            // Attempt refresh once (requires client_id/client_secret in auth file metadata), then retry.
            let refreshed = try await refreshAndPersistIfPossible(credential: credential)
            let response = try await fetchQuotaResponse(url: url, accessToken: refreshed.accessToken, projectId: projectId)
            let windows = buildWindows(from: response, now: now)
            return AccountQuotaReport(
                provider: .geminiCLI,
                accountKey: refreshed.accountKey,
                email: refreshed.email,
                plan: nil,
                status: .ok,
                source: .oauthApi,
                fetchedAt: now,
                windows: windows,
                errorMessage: nil
            )
        }
    }

    private func fetchQuotaResponse(url: URL, accessToken: String, projectId: String) async throws -> RetrieveUserQuotaResponse {
        let body = try JSONEncoder().encode(RetrieveUserQuotaRequest(project: projectId))
        let data = try await httpClient.post(
            url: url,
            body: body,
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Content-Type": "application/json",
                "Accept": "application/json",
            ]
        )

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(RetrieveUserQuotaResponse.self, from: data)
    }

    private func buildWindows(from response: RetrieveUserQuotaResponse, now: Date) -> [QuotaWindow] {
        var byModel: [String: BucketAccumulator] = [:]

        for bucket in response.buckets ?? [] {
            guard let modelId = bucket.modelId.nonEmpty else { continue }

            let resetAt = bucket.resetTime.flatMap(parseISO8601Date)

            var remainingFraction = bucket.remainingFraction
            if remainingFraction == nil {
                if let amount = bucket.remainingAmount, amount <= 0 {
                    remainingFraction = 0
                } else if resetAt != nil {
                    remainingFraction = 0
                }
            }

            var acc = byModel[modelId] ?? BucketAccumulator(minRemainingFraction: nil, earliestResetAt: nil)
            if let remainingFraction {
                acc.minRemainingFraction = min(acc.minRemainingFraction ?? remainingFraction, remainingFraction)
            }
            if let resetAt {
                acc.earliestResetAt = min(acc.earliestResetAt ?? resetAt, resetAt)
            }
            byModel[modelId] = acc
        }

        var windows: [QuotaWindow] = []
        windows.reserveCapacity(byModel.count + 1)

        let overallRemaining = byModel.values.compactMap(\.minRemainingFraction).min()
        if let overallRemaining {
            let remainingPercent = max(0, min(100, overallRemaining * 100))
            windows.append(
                QuotaWindow(
                    id: "gemini.overall",
                    label: "Overall",
                    unit: .percent,
                    usedPercent: max(0, 100 - remainingPercent),
                    remainingPercent: remainingPercent,
                    used: nil,
                    limit: nil,
                    remaining: nil,
                    resetAt: byModel.values.compactMap(\.earliestResetAt).min()
                )
            )
        }

        let modelWindows = byModel
            .sorted(by: { $0.key < $1.key })
            .compactMap { (modelId, acc) -> QuotaWindow? in
                guard let remainingFraction = acc.minRemainingFraction ?? (acc.earliestResetAt != nil ? 0 : nil) else { return nil }
                let remainingPercent = max(0, min(100, remainingFraction * 100))
                let usedPercent = max(0, 100 - remainingPercent)
                return QuotaWindow(
                    id: "gemini.\(modelId)",
                    label: modelId,
                    unit: .percent,
                    usedPercent: usedPercent,
                    remainingPercent: remainingPercent,
                    used: nil,
                    limit: nil,
                    remaining: nil,
                    resetAt: acc.earliestResetAt
                )
            }

        windows.append(contentsOf: modelWindows)
        return windows
    }

    // MARK: - Refresh + Persistence (best-effort)

    private func refreshAndPersistIfPossible(credential: any Credential) async throws -> CLIProxyCredential {
        guard let refreshToken = credential.refreshToken.nonEmpty else {
            throw FluxError(code: .authError, message: "Gemini CLI refresh token missing")
        }
        guard let filePath = credential.filePath.nonEmpty else {
            throw FluxError(code: .authError, message: "Gemini CLI auth file path missing")
        }
        guard let clientId = credential.metadata["client_id"].nonEmpty,
              let clientSecret = credential.metadata["client_secret"].nonEmpty else {
            throw FluxError(code: .authError, message: "Gemini CLI client_id/client_secret missing (cannot refresh)")
        }

        guard let url = URL(string: "https://oauth2.googleapis.com/token") else {
            throw FluxError(code: .networkError, message: "Invalid Google token URL")
        }

        let body = formURLEncoded([
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", clientId),
            ("client_secret", clientSecret),
        ])

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
        let refreshed = try decoder.decode(GoogleTokenRefreshResponse.self, from: data)
        guard let newAccessToken = refreshed.accessToken.nonEmpty else {
            throw FluxError(code: .authError, message: "Gemini CLI refresh returned empty access token")
        }

        try persistRefreshedToken(filePath: filePath, newAccessToken: newAccessToken, expiresIn: refreshed.expiresIn)
        await logger.log(.debug, category: LogCategories.quotaGeminiCLI, metadata: ["path": .string(filePath)], message: "Gemini CLI token refreshed and persisted")

        return CLIProxyAuthFileReader.decodeCredential(from: URL(fileURLWithPath: filePath)) ?? CLIProxyCredential(
            provider: .geminiCLI,
            sourceType: .cliProxyAuthDir,
            accountKey: credential.accountKey,
            email: credential.email,
            accessToken: newAccessToken,
            refreshToken: refreshToken,
            expiresAt: refreshed.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
            filePath: filePath,
            metadata: credential.metadata
        )
    }

    private func persistRefreshedToken(filePath: String, newAccessToken: String, expiresIn: Int?) throws {
        let url = URL(fileURLWithPath: filePath)
        let data = try Data(contentsOf: url)
        guard var json = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw FluxError(code: .parseError, message: "Gemini auth file parse failed")
        }

        json["type"] = (json["type"] as? String)?.isEmpty == false ? json["type"] : "gemini"

        var token = (json["token"] as? [String: Any]) ?? [:]
        token["access_token"] = newAccessToken
        if let expiresIn, expiresIn > 0 {
            let ms = Date().addingTimeInterval(TimeInterval(expiresIn)).timeIntervalSince1970 * 1000
            token["expiry_date"] = ms
        }
        json["token"] = token

        let out = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        try out.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
    }

    private struct BucketAccumulator {
        var minRemainingFraction: Double?
        var earliestResetAt: Date?
    }

    private func parseISO8601Date(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: trimmed) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: trimmed)
    }

    private func formURLEncoded(_ pairs: [(String, String)]) -> Data {
        let allowed: CharacterSet = {
            var s = CharacterSet.urlQueryAllowed
            s.remove(charactersIn: "&+=?/")
            return s
        }()
        let encoded = pairs.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }
}

private struct RetrieveUserQuotaRequest: Encodable {
    let project: String
}

private struct RetrieveUserQuotaResponse: Decodable {
    let buckets: [Bucket]?

    struct Bucket: Decodable {
        let modelId: String?
        let remainingFraction: Double?
        let remainingAmount: Double?
        let resetTime: String?

        enum CodingKeys: String, CodingKey {
            case modelId
            case model_id
            case remainingFraction
            case remaining_fraction
            case remainingAmount
            case remaining_amount
            case resetTime
            case reset_time
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            modelId = (try? container.decodeIfPresent(String.self, forKey: .modelId))
                ?? (try? container.decodeIfPresent(String.self, forKey: .model_id))

            remainingFraction =
                (try? container.decodeIfPresent(LossyDouble.self, forKey: .remainingFraction))?.value
                ?? (try? container.decodeIfPresent(LossyDouble.self, forKey: .remaining_fraction))?.value

            remainingAmount =
                (try? container.decodeIfPresent(LossyDouble.self, forKey: .remainingAmount))?.value
                ?? (try? container.decodeIfPresent(LossyDouble.self, forKey: .remaining_amount))?.value

            resetTime = (try? container.decodeIfPresent(String.self, forKey: .resetTime))
                ?? (try? container.decodeIfPresent(String.self, forKey: .reset_time))
        }
    }
}

private struct LossyDouble: Decodable {
    let value: Double?

    init(from decoder: Decoder) throws {
        if let d = try? decoder.singleValueContainer().decode(Double.self) {
            value = d.isFinite ? d : nil
            return
        }
        if let i = try? decoder.singleValueContainer().decode(Int.self) {
            value = Double(i)
            return
        }
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if let d = Double(trimmed), d.isFinite {
                value = d
            } else {
                value = nil
            }
            return
        }
        value = nil
    }
}

private struct GoogleTokenRefreshResponse: Decodable {
    let accessToken: String?
    let expiresIn: Int?
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self else { return nil }
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
