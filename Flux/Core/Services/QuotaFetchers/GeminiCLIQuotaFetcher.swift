import Foundation

actor GeminiCLIQuotaFetcher: QuotaFetcher {
    nonisolated let providerID: ProviderID = .geminiCLI

    private let httpClient: HTTPClient
    private let quotaURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")

    init(httpClient: HTTPClient = .shared) {
        self.httpClient = httpClient
    }

    func fetchQuotas(authFiles: [AuthFileInfo]) async -> [String: AccountQuota] {
        let now = Date()

        guard let auth = readOAuthCreds() else { return [:] }
        guard let accessToken = nonEmpty(auth.accessToken) else { return [:] }

        if let expiryDate = auth.expiryDate, expiryDate <= now {
            let accountKey = auth.email ?? "Gemini CLI"
            return [
                accountKey: AccountQuota(
                    accountKey: accountKey,
                    email: auth.email,
                    kind: .authMissing,
                    quota: nil,
                    lastUpdated: now,
                    message: nil,
                    error: "Gemini CLI token expired".localizedStatic(),
                    planType: .unknown,
                    modelQuotas: []
                ),
            ]
        }

        guard let projectId = resolveProjectIdFromAccountsFile() else { return [:] }
        guard let url = quotaURL else { return [:] }

        do {
            let body = try JSONSerialization.data(withJSONObject: ["project": projectId], options: [])
            let data = try await httpClient.post(
                url: url,
                body: body,
                headers: [
                    "Authorization": "Bearer \(accessToken)",
                    "Content-Type": "application/json",
                    "Accept": "application/json",
                ]
            )

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            let buckets = json["buckets"] as? [Any] ?? []

            let modelQuotas = buildModelQuotas(from: buckets)
            let summary = summarize(modelQuotas)

            let accountKey = auth.email ?? "Gemini CLI"
            return [
                accountKey: AccountQuota(
                    accountKey: accountKey,
                    email: auth.email,
                    kind: .ok,
                    quota: summary,
                    lastUpdated: now,
                    message: nil,
                    error: nil,
                    planType: .unknown,
                    modelQuotas: modelQuotas
                ),
            ]
        } catch let error as FluxError {
            let kind: QuotaSnapshotKind = (error.code == .authError) ? .authMissing : .error
            let accountKey = auth.email ?? "Gemini CLI"
            return [
                accountKey: AccountQuota(
                    accountKey: accountKey,
                    email: auth.email,
                    kind: kind,
                    quota: nil,
                    lastUpdated: now,
                    message: nil,
                    error: error.message,
                    planType: .unknown,
                    modelQuotas: []
                ),
            ]
        } catch {
            let accountKey = auth.email ?? "Gemini CLI"
            return [
                accountKey: AccountQuota(
                    accountKey: accountKey,
                    email: auth.email,
                    kind: .error,
                    quota: nil,
                    lastUpdated: now,
                    message: nil,
                    error: "Gemini CLI quota fetch failed".localizedStatic(),
                    planType: .unknown,
                    modelQuotas: []
                ),
            ]
        }
    }

    private struct OAuthCreds: Sendable {
        let accessToken: String?
        let refreshToken: String?
        let expiryDate: Date?
        let email: String?
    }

    private func readOAuthCreds() -> OAuthCreds? {
        let url = URL(fileURLWithPath: NSString(string: "~/.gemini/oauth_creds.json").expandingTildeInPath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }

        let accessToken = json["access_token"] as? String
        let refreshToken = json["refresh_token"] as? String

        let expiryDate: Date?
        if let ms = json["expiry_date"] as? Double {
            expiryDate = Date(timeIntervalSince1970: ms / 1000)
        } else if let ms = json["expiry_date"] as? NSNumber {
            expiryDate = Date(timeIntervalSince1970: ms.doubleValue / 1000)
        } else {
            expiryDate = nil
        }

        let idToken = json["id_token"] as? String
        let email = idToken.flatMap(extractEmailFromIDToken)

        return OAuthCreds(accessToken: accessToken, refreshToken: refreshToken, expiryDate: expiryDate, email: email)
    }

    private func extractEmailFromIDToken(_ token: String) -> String? {
        guard let payload = decodeJWTPayload(token) else { return nil }
        let email = payload["email"] as? String
        return nonEmpty(email)
    }

    private func resolveProjectIdFromAccountsFile() -> String? {
        let url = URL(fileURLWithPath: NSString(string: "~/.gemini/google_accounts.json").expandingTildeInPath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }

        let raw = (json["account"] as? String) ?? (json["active"] as? String)
        guard let raw, let projectId = extractProjectId(raw) else { return nil }
        return projectId
    }

    private func extractProjectId(_ value: String) -> String? {
        let ns = value as NSString
        let pattern = "\\(([^()]+)\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = regex.matches(in: value, range: NSRange(location: 0, length: ns.length))
        guard let last = matches.last, last.numberOfRanges >= 2 else { return nil }
        let range = last.range(at: 1)
        if range.location == NSNotFound { return nil }
        let extracted = ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        return extracted.isEmpty ? nil : extracted
    }

    private struct BucketAccumulator {
        var minRemainingFraction: Double?
        var earliestResetAt: Date?
    }

    private func buildModelQuotas(from buckets: [Any]) -> [ModelQuota] {
        var byModelId: [String: BucketAccumulator] = [:]

        for item in buckets {
            guard let bucket = item as? [String: Any] else { continue }
            guard let modelId = nonEmpty((bucket["modelId"] as? String) ?? (bucket["model_id"] as? String)) else { continue }

            let remainingFractionRaw = bucket["remainingFraction"] ?? bucket["remaining_fraction"]
            let remainingAmountRaw = bucket["remainingAmount"] ?? bucket["remaining_amount"]
            let resetTimeString = (bucket["resetTime"] as? String) ?? (bucket["reset_time"] as? String)

            let resetAt = resetTimeString.flatMap(parseISO8601Date)

            var remainingFraction = parseFraction(remainingFractionRaw)
            if remainingFraction == nil {
                if let amount = parseDouble(remainingAmountRaw) {
                    remainingFraction = amount <= 0 ? 0 : nil
                } else if resetAt != nil {
                    remainingFraction = 0
                }
            }

            var acc = byModelId[modelId] ?? BucketAccumulator(minRemainingFraction: nil, earliestResetAt: nil)
            if let remainingFraction {
                acc.minRemainingFraction = min(acc.minRemainingFraction ?? remainingFraction, remainingFraction)
            }
            if let resetAt {
                acc.earliestResetAt = min(acc.earliestResetAt ?? resetAt, resetAt)
            }
            byModelId[modelId] = acc
        }

        return byModelId
            .sorted(by: { $0.key < $1.key })
            .compactMap { (modelId, acc) -> ModelQuota? in
                guard let fraction = acc.minRemainingFraction ?? (acc.earliestResetAt != nil ? 0 : nil) else { return nil }
                let remainingPercent = max(0, min(100, fraction * 100))
                return ModelQuota(
                    modelId: modelId,
                    displayName: modelId,
                    usedPercent: max(0, 100 - remainingPercent),
                    remainingPercent: remainingPercent,
                    resetAt: acc.earliestResetAt
                )
            }
    }

    private func summarize(_ modelQuotas: [ModelQuota]) -> QuotaMetrics? {
        guard modelQuotas.isEmpty == false else { return nil }
        guard let worst = modelQuotas.min(by: { $0.remainingPercent < $1.remainingPercent }) else { return nil }
        return QuotaMetrics(
            used: Int(worst.usedPercent.rounded()),
            limit: 100,
            remaining: Int(worst.remainingPercent.rounded()),
            resetAt: worst.resetAt,
            unit: .credits
        )
    }

    private func parseFraction(_ value: Any?) -> Double? {
        guard let raw = parseDouble(value) else { return nil }
        if raw > 1, raw <= 100 { return raw / 100 }
        return min(1, max(0, raw))
    }

    private func parseDouble(_ value: Any?) -> Double? {
        if let double = value as? Double, double.isFinite { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String, let parsed = Double(string), parsed.isFinite { return parsed }
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

    private func decodeJWTPayload(_ jwt: String) -> [String: Any]? {
        let segments = jwt.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        let payloadSegment = String(segments[1])
        guard let decoded = decodeBase64URL(payloadSegment) else { return nil }
        return (try? JSONSerialization.jsonObject(with: decoded)) as? [String: Any]
    }

    private func decodeBase64URL(_ input: String) -> Data? {
        var base64 = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - (base64.count % 4)) % 4
        base64 += String(repeating: "=", count: padding)
        return Data(base64Encoded: base64)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

