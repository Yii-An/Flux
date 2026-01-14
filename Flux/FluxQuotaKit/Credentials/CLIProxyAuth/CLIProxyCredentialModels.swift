import Foundation

struct CLIProxyCredential: Credential, Codable, Hashable, Sendable {
    let provider: ProviderKind
    let sourceType: CredentialSourceType

    let accountKey: String
    let email: String?

    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?

    let filePath: String?
    let metadata: [String: String]

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }
}

enum CLIProxyAuthFileReader {
    static func listCredentials(authDir: URL = FluxPaths.cliProxyAuthDir()) -> [CLIProxyCredential] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: authDir.path) else { return [] }

        let files: [URL]
        do {
            files = try fm.contentsOfDirectory(at: authDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        } catch {
            return []
        }

        let jsonFiles = files.filter { $0.pathExtension.lowercased() == "json" }
        return jsonFiles.compactMap { decodeCredential(from: $0) }
    }

    static func decodeCredential(from file: URL) -> CLIProxyCredential? {
        guard let data = try? Data(contentsOf: file) else { return nil }

        if let codex = tryDecode(CodexAuthFile.self, data: data), codex.typeNormalized == "codex" {
            guard let token = codex.accessToken.nonEmpty else { return nil }
            return CLIProxyCredential(
                provider: .codex,
                sourceType: .cliProxyAuthDir,
                accountKey: codex.email.nonEmpty ?? file.lastPathComponent,
                email: codex.email.nonEmpty,
                accessToken: token,
                refreshToken: codex.refreshToken.nonEmpty,
                expiresAt: codex.expired,
                filePath: file.path,
                metadata: [
                    "account_id": codex.accountId.nonEmpty ?? "",
                    "client_id": codex.clientId.nonEmpty ?? "",
                ].filter { !$0.value.isEmpty }
            )
        }

        if let anti = tryDecode(AntigravityAuthFile.self, data: data), anti.typeNormalized == "antigravity" {
            guard let token = anti.accessToken.nonEmpty else { return nil }
            return CLIProxyCredential(
                provider: .antigravity,
                sourceType: .cliProxyAuthDir,
                accountKey: anti.email.nonEmpty ?? file.lastPathComponent,
                email: anti.email.nonEmpty,
                accessToken: token,
                refreshToken: anti.refreshToken.nonEmpty,
                expiresAt: anti.expiredAt,
                filePath: file.path,
                metadata: [
                    "project_id": anti.projectId.nonEmpty ?? "",
                    "client_id": anti.clientId.nonEmpty ?? "",
                    "client_secret": anti.clientSecret.nonEmpty ?? "",
                ].filter { !$0.value.isEmpty }
            )
        }

        if let gemini = tryDecode(GeminiAuthFile.self, data: data), gemini.typeNormalized == "gemini" {
            guard let accessToken = gemini.resolvedAccessToken().nonEmpty else { return nil }
            return CLIProxyCredential(
                provider: .geminiCLI,
                sourceType: .cliProxyAuthDir,
                accountKey: gemini.email.nonEmpty.map { "\($0)::\(gemini.projectId ?? "unknown")" } ?? file.lastPathComponent,
                email: gemini.email.nonEmpty,
                accessToken: accessToken,
                refreshToken: gemini.resolvedRefreshToken().nonEmpty,
                expiresAt: gemini.resolvedExpiryDate(),
                filePath: file.path,
                metadata: [
                    "project_id": gemini.projectId.nonEmpty ?? "",
                    "client_id": gemini.resolvedClientId().nonEmpty ?? "",
                    "client_secret": gemini.resolvedClientSecret().nonEmpty ?? "",
                ].filter { !$0.value.isEmpty }
            )
        }

        return nil
    }

    private static func tryDecode<T: Decodable>(_ type: T.Type, data: Data) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self else { return nil }
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Auth file shapes (CLIProxyAPI/CLIProxyAPIPlus compatible)

private struct CodexAuthFile: Decodable {
    let type: String?
    let email: String?
    let accessToken: String?
    let refreshToken: String?
    let accountId: String?
    let expiredRaw: String?
    let clientId: String?

    var typeNormalized: String { type?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }

    var expired: Date? { ISO8601DateFormatter().date(from: expiredRaw ?? "") }

    enum CodingKeys: String, CodingKey {
        case type
        case email
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case accountId = "account_id"
        case expiredRaw = "expired"
        case clientId = "client_id"
    }
}

private struct AntigravityAuthFile: Decodable {
    let type: String?
    let email: String?
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int?
    let expiredRaw: String?
    let timestampMs: Int?
    let projectId: String?
    let clientId: String?
    let clientSecret: String?

    var typeNormalized: String { type?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }

    var expiredAt: Date? {
        if let expiredRaw, let date = ISO8601DateFormatter().date(from: expiredRaw) { return date }
        if let timestampMs, let expiresIn {
            let issuedAt = Date(timeIntervalSince1970: Double(timestampMs) / 1000)
            return issuedAt.addingTimeInterval(TimeInterval(expiresIn))
        }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case type
        case email
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case expiredRaw = "expired"
        case timestampMs = "timestamp"
        case projectId = "project_id"
        case clientId = "client_id"
        case clientSecret = "client_secret"
    }
}

private struct GeminiAuthFile: Decodable {
    let type: String?
    let email: String?
    let projectId: String?
    let token: GeminiTokenObject?
    let clientId: String?
    let clientSecret: String?

    var typeNormalized: String { type?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }

    enum CodingKeys: String, CodingKey {
        case type
        case email
        case projectId = "project_id"
        case token
        case clientId = "client_id"
        case clientSecret = "client_secret"
    }

    func resolvedAccessToken() -> String? {
        token?.accessToken ?? token?.accessTokenAlt
    }

    func resolvedRefreshToken() -> String? {
        token?.refreshToken ?? token?.refreshTokenAlt
    }

    func resolvedClientId() -> String? {
        token?.clientId ?? clientId
    }

    func resolvedClientSecret() -> String? {
        token?.clientSecret ?? clientSecret
    }

    func resolvedExpiryDate() -> Date? {
        token?.expiryDate
    }
}

private struct GeminiTokenObject: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let tokenType: String?
    let clientId: String?
    let clientSecret: String?
    let expiry: Date?
    let expiryDateMs: Double?

    // Alternate casing from some token serializers
    let accessTokenAlt: String?
    let refreshTokenAlt: String?

    var expiryDate: Date? {
        if let expiry { return expiry }
        if let expiryDateMs { return Date(timeIntervalSince1970: expiryDateMs / 1000) }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case clientId = "client_id"
        case clientSecret = "client_secret"
        case expiry
        case expiryDateMs = "expiry_date"
        case accessTokenAlt = "AccessToken"
        case refreshTokenAlt = "RefreshToken"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken)
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        tokenType = try container.decodeIfPresent(String.self, forKey: .tokenType)
        clientId = try container.decodeIfPresent(String.self, forKey: .clientId)
        clientSecret = try container.decodeIfPresent(String.self, forKey: .clientSecret)

        // expiry can be RFC3339, ISO8601, or missing.
        if let expiryString = try container.decodeIfPresent(String.self, forKey: .expiry),
           let date = ISO8601DateFormatter().date(from: expiryString) {
            expiry = date
        } else {
            expiry = nil
        }

        expiryDateMs = try container.decodeIfPresent(Double.self, forKey: .expiryDateMs)

        accessTokenAlt = try container.decodeIfPresent(String.self, forKey: .accessTokenAlt)
        refreshTokenAlt = try container.decodeIfPresent(String.self, forKey: .refreshTokenAlt)
    }
}
