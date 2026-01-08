import Foundation

// MARK: - Config / Health

struct HealthResponse: Codable, Equatable {
    let status: String
    let version: String?
    let uptime: TimeInterval?

    // Config response fields (from /v0/management/config)
    let debug: Bool?
    let wsAuth: Bool?

    enum CodingKeys: String, CodingKey {
        case status, version, uptime, debug
        case wsAuth = "ws-auth"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // /config endpoint returns config object, not health status
        // If we can decode it, the connection is healthy
        self.debug = try container.decodeIfPresent(Bool.self, forKey: .debug)
        self.wsAuth = try container.decodeIfPresent(Bool.self, forKey: .wsAuth)
        self.version = try container.decodeIfPresent(String.self, forKey: .version)
        self.uptime = try container.decodeIfPresent(TimeInterval.self, forKey: .uptime)
        // If decoding succeeds, status is OK
        self.status = try container.decodeIfPresent(String.self, forKey: .status) ?? "ok"
    }

    init(status: String, version: String? = nil, uptime: TimeInterval? = nil) {
        self.status = status
        self.version = version
        self.uptime = uptime
        self.debug = nil
        self.wsAuth = nil
    }
}

// MARK: - API Keys Response

struct APIKeysResponse: Decodable {
    let keys: [String]?

    var count: Int { keys?.count ?? 0 }

    private enum CodingKeys: String, CodingKey {
        case apiKeys = "api-keys"
        case apiKeysAlt = "apiKeys"
    }

    // 兼容多种返回格式
    init(from decoder: Decoder) throws {
        // 尝试 { "api-keys": [...] } 或 { "apiKeys": [...] }
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            if let keys = try? container.decodeIfPresent([String].self, forKey: .apiKeys) {
                self.keys = keys
                return
            }
            if let keys = try? container.decodeIfPresent([String].self, forKey: .apiKeysAlt) {
                self.keys = keys
                return
            }
        }
        // 尝试直接数组
        if let array = try? decoder.singleValueContainer().decode([String].self) {
            self.keys = array
            return
        }
        self.keys = nil
    }
}

// MARK: - Provider API Keys

/// 通用的 Provider Key 条目，用于 gemini/codex/claude-api-key
struct ProviderKeyEntry: Decodable, Equatable {
    let apiKey: String?
    let baseUrl: String?
    let proxyUrl: String?
    let prefix: String?
    let headers: [String: String]?
    let excludedModels: [String]?
    let models: [ModelMapping]?

    enum CodingKeys: String, CodingKey {
        case apiKey = "api-key"
        case baseUrl = "base-url"
        case proxyUrl = "proxy-url"
        case prefix
        case headers
        case excludedModels = "excluded-models"
        case models
    }
}

struct GeminiApiKeyResponse: Decodable {
    let keys: [ProviderKeyEntry]?

    var count: Int { keys?.count ?? 0 }

    private enum CodingKeys: String, CodingKey {
        case keys = "gemini-api-key"
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            self.keys = try container.decodeIfPresent([ProviderKeyEntry].self, forKey: .keys)
            return
        }
        if let array = try? decoder.singleValueContainer().decode([ProviderKeyEntry].self) {
            self.keys = array
            return
        }
        self.keys = nil
    }
}

struct CodexApiKeyResponse: Decodable {
    let keys: [ProviderKeyEntry]?

    var count: Int { keys?.count ?? 0 }

    private enum CodingKeys: String, CodingKey {
        case keys = "codex-api-key"
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            self.keys = try container.decodeIfPresent([ProviderKeyEntry].self, forKey: .keys)
            return
        }
        if let array = try? decoder.singleValueContainer().decode([ProviderKeyEntry].self) {
            self.keys = array
            return
        }
        self.keys = nil
    }
}

struct ClaudeApiKeyResponse: Decodable {
    let keys: [ProviderKeyEntry]?

    var count: Int { keys?.count ?? 0 }

    private enum CodingKeys: String, CodingKey {
        case keys = "claude-api-key"
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            self.keys = try container.decodeIfPresent([ProviderKeyEntry].self, forKey: .keys)
            return
        }
        if let array = try? decoder.singleValueContainer().decode([ProviderKeyEntry].self) {
            self.keys = array
            return
        }
        self.keys = nil
    }
}

/// OpenAI 兼容提供商条目
struct OpenAICompatibilityEntry: Decodable, Equatable {
    let name: String?
    let baseUrl: String?
    let apiKeyEntries: [OpenAICompatApiKeyEntry]?
    let models: [ModelMapping]?
    let headers: [String: String]?

    enum CodingKeys: String, CodingKey {
        case name
        case baseUrl = "base-url"
        case apiKeyEntries = "api-key-entries"
        case models
        case headers
    }

    static func == (lhs: OpenAICompatibilityEntry, rhs: OpenAICompatibilityEntry) -> Bool {
        lhs.name == rhs.name &&
        lhs.baseUrl == rhs.baseUrl
    }
}

/// OpenAI 兼容提供商的 API Key 条目
struct OpenAICompatApiKeyEntry: Codable, Equatable {
    let apiKey: String?
    let proxyUrl: String?

    enum CodingKeys: String, CodingKey {
        case apiKey = "api-key"
        case proxyUrl = "proxy-url"
    }
}

/// 模型映射（用于 alias）
struct ModelMapping: Codable, Equatable {
    let name: String?
    let alias: String?
}

struct OpenAICompatibilityResponse: Decodable {
    let entries: [OpenAICompatibilityEntry]?

    var count: Int { entries?.count ?? 0 }

    private enum CodingKeys: String, CodingKey {
        case entries = "openai-compatibility"
    }

    // 兼容多种返回格式
    init(from decoder: Decoder) throws {
        // 尝试解码 { "openai-compatibility": [...] }
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            self.entries = try container.decodeIfPresent([OpenAICompatibilityEntry].self, forKey: .entries)
            return
        }
        // 尝试直接解码数组
        if let array = try? decoder.singleValueContainer().decode([OpenAICompatibilityEntry].self) {
            self.entries = array
            return
        }
        self.entries = nil
    }
}

// MARK: - Auth Files

/// 认证文件信息（来自 /auth-files 端点）
struct AuthFile: Decodable, Equatable {
    let id: String?
    let authIndex: String?
    let name: String?
    let type: String?  // 降级模式下返回
    let provider: String?
    let label: String?
    let status: String?
    let statusMessage: String?
    let disabled: Bool?
    let unavailable: Bool?
    let runtimeOnly: Bool?
    let source: String?
    let path: String?
    let size: Int?
    let modtime: String?
    let email: String?
    let accountType: String?
    let account: String?
    let createdAt: String?
    let updatedAt: String?
    let lastRefresh: String?

    enum CodingKeys: String, CodingKey {
        case id, name, type, provider, label, status, disabled, unavailable, source, path, size, modtime, email, account
        case authIndex = "auth_index"
        case authIndexAlt = "authIndex"
        case statusMessage = "status_message"
        case runtimeOnly = "runtime_only"
        case accountType = "account_type"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastRefresh = "last_refresh"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id)
        let authIndexPrimary = try container.decodeIfPresent(String.self, forKey: .authIndex)
        let authIndexAlternate = try container.decodeIfPresent(String.self, forKey: .authIndexAlt)
        self.authIndex = authIndexPrimary ?? authIndexAlternate
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.type = try container.decodeIfPresent(String.self, forKey: .type)
        self.provider = try container.decodeIfPresent(String.self, forKey: .provider)
        self.label = try container.decodeIfPresent(String.self, forKey: .label)
        self.status = try container.decodeIfPresent(String.self, forKey: .status)
        self.statusMessage = try container.decodeIfPresent(String.self, forKey: .statusMessage)
        self.disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled)
        self.unavailable = try container.decodeIfPresent(Bool.self, forKey: .unavailable)
        self.runtimeOnly = try container.decodeIfPresent(Bool.self, forKey: .runtimeOnly)
        self.source = try container.decodeIfPresent(String.self, forKey: .source)
        self.path = try container.decodeIfPresent(String.self, forKey: .path)
        self.size = try container.decodeIfPresent(Int.self, forKey: .size)
        self.modtime = try container.decodeIfPresent(String.self, forKey: .modtime)
        self.email = try container.decodeIfPresent(String.self, forKey: .email)
        self.accountType = try container.decodeIfPresent(String.self, forKey: .accountType)
        self.account = try container.decodeIfPresent(String.self, forKey: .account)
        self.createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        self.updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        self.lastRefresh = try container.decodeIfPresent(String.self, forKey: .lastRefresh)
    }

    static func == (lhs: AuthFile, rhs: AuthFile) -> Bool {
        lhs.id == rhs.id &&
        lhs.name == rhs.name
    }
}

struct AuthFilesResponse: Decodable {
    let files: [AuthFile]?

    var count: Int { files?.count ?? 0 }
}

// MARK: - API Call (Proxy API Tools)

struct APICallRequest: Codable {
    let authIndex: String?
    let method: String
    let url: String
    let header: [String: String]?
    let data: String?

    enum CodingKeys: String, CodingKey {
        case authIndex = "auth_index"
        case method
        case url
        case header
        case data
    }
}

struct APICallResponse: Decodable {
    let statusCode: Int
    let header: [String: [String]]?
    let body: String

    enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case header
        case body
    }
}

// MARK: - Quota Payloads (Upstream)

struct GeminiCliQuotaBucket: Decodable {
    let modelId: String?
    let tokenType: String?
    let remainingFraction: Double?
    let remainingAmount: Double?
    let resetTime: String?

    enum CodingKeys: String, CodingKey {
        case modelId
        case modelIdAlt = "model_id"
        case tokenType
        case tokenTypeAlt = "token_type"
        case remainingFraction
        case remainingFractionAlt = "remaining_fraction"
        case remainingAmount
        case remainingAmountAlt = "remaining_amount"
        case resetTime
        case resetTimeAlt = "reset_time"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.modelId = try container.decodeIfPresent(String.self, forKey: .modelId) ?? container.decodeIfPresent(String.self, forKey: .modelIdAlt)
        self.tokenType = try container.decodeIfPresent(String.self, forKey: .tokenType) ?? container.decodeIfPresent(String.self, forKey: .tokenTypeAlt)
        self.remainingFraction = Self.decodeFlexibleDouble(container: container, primary: .remainingFraction, fallback: .remainingFractionAlt)
        self.remainingAmount = Self.decodeFlexibleDouble(container: container, primary: .remainingAmount, fallback: .remainingAmountAlt)
        self.resetTime = try container.decodeIfPresent(String.self, forKey: .resetTime) ?? container.decodeIfPresent(String.self, forKey: .resetTimeAlt)
    }

    private static func decodeFlexibleDouble(container: KeyedDecodingContainer<CodingKeys>, primary: CodingKeys, fallback: CodingKeys) -> Double? {
        if let v = try? container.decodeIfPresent(Double.self, forKey: primary) {
            return v
        }
        if let s = try? container.decodeIfPresent(String.self, forKey: primary), let v = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return v
        }
        if let v = try? container.decodeIfPresent(Double.self, forKey: fallback) {
            return v
        }
        if let s = try? container.decodeIfPresent(String.self, forKey: fallback), let v = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return v
        }
        return nil
    }
}

struct GeminiCliQuotaPayload: Decodable {
    let buckets: [GeminiCliQuotaBucket]?
}

struct AntigravityQuotaInfo: Decodable {
    struct QuotaInfo: Decodable {
        let remainingFraction: Double?
        let remaining: Double?
        let resetTime: String?

        enum CodingKeys: String, CodingKey {
            case remainingFraction
            case remainingFractionAlt = "remaining_fraction"
            case remaining
            case resetTime
            case resetTimeAlt = "reset_time"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.remainingFraction = Self.decodeFlexibleDouble(container: container, primary: .remainingFraction, fallback: .remainingFractionAlt)
            self.remaining = Self.decodeFlexibleDouble(container: container, primary: .remaining, fallback: .remaining)
            self.resetTime = try container.decodeIfPresent(String.self, forKey: .resetTime) ?? container.decodeIfPresent(String.self, forKey: .resetTimeAlt)
        }

        private static func decodeFlexibleDouble(container: KeyedDecodingContainer<CodingKeys>, primary: CodingKeys, fallback: CodingKeys) -> Double? {
            if let v = try? container.decodeIfPresent(Double.self, forKey: primary) {
                return v
            }
            if let s = try? container.decodeIfPresent(String.self, forKey: primary) {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasSuffix("%"), let p = Double(trimmed.dropLast()) {
                    return p / 100.0
                }
                if let v = Double(trimmed) {
                    return v
                }
            }
            if let v = try? container.decodeIfPresent(Double.self, forKey: fallback) {
                return v
            }
            if let s = try? container.decodeIfPresent(String.self, forKey: fallback) {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasSuffix("%"), let p = Double(trimmed.dropLast()) {
                    return p / 100.0
                }
                if let v = Double(trimmed) {
                    return v
                }
            }
            return nil
        }
    }

    let displayName: String?
    let quotaInfo: QuotaInfo?
    let quotaInfoAlt: QuotaInfo?

    enum CodingKeys: String, CodingKey {
        case displayName
        case quotaInfo
        case quotaInfoAlt = "quota_info"
    }

    var effectiveQuotaInfo: QuotaInfo? { quotaInfo ?? quotaInfoAlt }
}

typealias AntigravityModelsPayload = [String: AntigravityQuotaInfo]

struct CodexUsageWindow: Decodable {
    let usedPercent: Double?
    let resetAfterSeconds: Double?
    let resetAt: Double?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case usedPercentAlt = "usedPercent"
        case resetAfterSeconds = "reset_after_seconds"
        case resetAfterSecondsAlt = "resetAfterSeconds"
        case resetAt = "reset_at"
        case resetAtAlt = "resetAt"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.usedPercent = Self.decodeFlexibleDouble(container: container, keys: [.usedPercent, .usedPercentAlt])
        self.resetAfterSeconds = Self.decodeFlexibleDouble(container: container, keys: [.resetAfterSeconds, .resetAfterSecondsAlt])
        self.resetAt = Self.decodeFlexibleDouble(container: container, keys: [.resetAt, .resetAtAlt])
    }

    private static func decodeFlexibleDouble(container: KeyedDecodingContainer<CodingKeys>, keys: [CodingKeys]) -> Double? {
        for key in keys {
            if let v = try? container.decodeIfPresent(Double.self, forKey: key) {
                return v
            }
            if let s = try? container.decodeIfPresent(String.self, forKey: key), let v = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return v
            }
        }
        return nil
    }
}

struct CodexRateLimitInfo: Decodable {
    let allowed: Bool?
    let limitReached: Bool?
    let primaryWindow: CodexUsageWindow?
    let secondaryWindow: CodexUsageWindow?

    enum CodingKeys: String, CodingKey {
        case allowed
        case limitReached = "limit_reached"
        case limitReachedAlt = "limitReached"
        case primaryWindow = "primary_window"
        case primaryWindowAlt = "primaryWindow"
        case secondaryWindow = "secondary_window"
        case secondaryWindowAlt = "secondaryWindow"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.allowed = try container.decodeIfPresent(Bool.self, forKey: .allowed)
        self.limitReached = try container.decodeIfPresent(Bool.self, forKey: .limitReached) ?? container.decodeIfPresent(Bool.self, forKey: .limitReachedAlt)
        self.primaryWindow = try container.decodeIfPresent(CodexUsageWindow.self, forKey: .primaryWindow) ?? container.decodeIfPresent(CodexUsageWindow.self, forKey: .primaryWindowAlt)
        self.secondaryWindow = try container.decodeIfPresent(CodexUsageWindow.self, forKey: .secondaryWindow) ?? container.decodeIfPresent(CodexUsageWindow.self, forKey: .secondaryWindowAlt)
    }
}

struct CodexUsagePayload: Decodable {
    let planType: String?
    let rateLimit: CodexRateLimitInfo?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case planTypeAlt = "planType"
        case rateLimit = "rate_limit"
        case rateLimitAlt = "rateLimit"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.planType = try container.decodeIfPresent(String.self, forKey: .planType) ?? container.decodeIfPresent(String.self, forKey: .planTypeAlt)
        self.rateLimit = try container.decodeIfPresent(CodexRateLimitInfo.self, forKey: .rateLimit) ?? container.decodeIfPresent(CodexRateLimitInfo.self, forKey: .rateLimitAlt)
    }
}

// MARK: - Models

struct ModelInfo: Codable, Identifiable {
    let id: String
    let displayName: String?
    let ownedBy: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case ownedBy = "owned_by"
    }
}

struct ModelsResponse: Codable {
    let data: [ModelInfo]?
    let models: [ModelInfo]?

    var allModels: [ModelInfo] { data ?? models ?? [] }
    var count: Int { allModels.count }
}

// MARK: - Dashboard Stats

struct DashboardStats: Equatable {
    var apiKeysCount: Int = 0
    var providersCount: Int = 0
    var authFilesCount: Int = 0
    var modelsCount: Int = 0

    // Provider breakdown
    var geminiCount: Int = 0
    var codexCount: Int = 0
    var claudeCount: Int = 0
    var openaiCompatCount: Int = 0
}

// MARK: - Status Response

struct StatusOKResponse: Codable, Equatable {
    let status: String
}

// MARK: - Provider Key Payload (Request)

struct ProviderKeyPayload: Codable {
    let apiKey: String?
    let baseUrl: String?
    let proxyUrl: String?
    let prefix: String?
    let headers: [String: String]?
    let excludedModels: [String]?
    let models: [ModelMapping]?

    enum CodingKeys: String, CodingKey {
        case apiKey = "api-key"
        case baseUrl = "base-url"
        case proxyUrl = "proxy-url"
        case prefix
        case headers
        case excludedModels = "excluded-models"
        case models
    }
}

// MARK: - OpenAI Compatibility Payload (Request)

struct OpenAICompatPayload: Codable {
    let name: String
    let baseUrl: String?
    let apiKeyEntries: [OpenAICompatApiKeyEntry]?
    let models: [ModelMapping]?
    let headers: [String: String]?

    enum CodingKeys: String, CodingKey {
        case name
        case baseUrl = "base-url"
        case apiKeyEntries = "api-key-entries"
        case models
        case headers
    }
}

// MARK: - Patch Wrappers

struct IndexValuePatch<T: Codable>: Codable {
    let index: Int
    let value: T
}

struct MatchValuePatch<T: Codable>: Codable {
    let match: String
    let value: T
}

struct NameValuePatch<T: Codable>: Codable {
    let name: String
    let value: T
}

// MARK: - Error

enum ManagementAPIError: Error, LocalizedError {
    case invalidURL
    case networkError(Error)
    case httpError(statusCode: Int, body: String?)
    case decodingError(Error)
    case notConnected
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的 URL"
        case .networkError(let error):
            return "网络错误: \(error.localizedDescription)"
        case .httpError(let code, let body):
            return "HTTP 错误 \(code): \(body ?? "未知")"
        case .decodingError(let error):
            return "解码错误: \(error.localizedDescription)"
        case .notConnected:
            return "未连接到 CLIProxyAPI"
        case .unauthorized:
            return "认证失败，请检查密码"
        }
    }
}
