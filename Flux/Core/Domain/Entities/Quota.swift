import Foundation

enum QuotaUnit: String, Codable, Sendable {
    case requests
    case tokens
    case credits
}

enum QuotaSnapshotKind: String, Codable, Sendable {
    case ok
    case authMissing
    case unsupported
    case error
    case loading
}

// MARK: - Detailed Quota

enum AccountPlanType: String, Codable, Sendable {
    case free
    case plus
    case pro
    case team
    case enterprise
    case unknown
}

extension AccountPlanType {
    var displayName: String {
        switch self {
        case .free: return "Free"
        case .plus: return "Plus"
        case .pro: return "Pro"
        case .team: return "Team"
        case .enterprise: return "Enterprise"
        case .unknown: return ""
        }
    }
}

struct ModelQuota: Codable, Sendable, Identifiable, Hashable {
    var id: String { modelId }

    let modelId: String
    let displayName: String
    let usedPercent: Double
    let remainingPercent: Double
    let resetAt: Date?
}

struct QuotaMetrics: Codable, Sendable, Hashable {
    var used: Int?
    var limit: Int?
    var remaining: Int?
    var resetAt: Date?
    var unit: QuotaUnit

    init(
        used: Int? = nil,
        limit: Int? = nil,
        remaining: Int? = nil,
        resetAt: Date? = nil,
        unit: QuotaUnit
    ) {
        self.used = used
        self.limit = limit
        self.remaining = remaining
        self.resetAt = resetAt
        self.unit = unit
    }
}

struct QuotaSnapshot: Codable, Sendable, Identifiable, Hashable {
    var id: ProviderID { provider }

    var provider: ProviderID
    var fetchedAt: Date
    var kind: QuotaSnapshotKind
    var metrics: QuotaMetrics?
    var message: String?

    init(
        provider: ProviderID,
        fetchedAt: Date = .now,
        kind: QuotaSnapshotKind,
        metrics: QuotaMetrics? = nil,
        message: String? = nil
    ) {
        self.provider = provider
        self.fetchedAt = fetchedAt
        self.kind = kind
        self.metrics = metrics
        self.message = message
    }
}

struct AccountQuota: Codable, Sendable, Identifiable {
    var id: String { accountKey }

    let accountKey: String
    let email: String?
    let kind: QuotaSnapshotKind
    let quota: QuotaMetrics?
    let lastUpdated: Date
    let message: String?
    let error: String?
    let planType: AccountPlanType?
    let modelQuotas: [ModelQuota]

    init(
        accountKey: String,
        email: String?,
        kind: QuotaSnapshotKind,
        quota: QuotaMetrics?,
        lastUpdated: Date,
        message: String?,
        error: String?,
        planType: AccountPlanType? = nil,
        modelQuotas: [ModelQuota] = []
    ) {
        self.accountKey = accountKey
        self.email = email
        self.kind = kind
        self.quota = quota
        self.lastUpdated = lastUpdated
        self.message = message
        self.error = error
        self.planType = planType
        self.modelQuotas = modelQuotas
    }

    enum CodingKeys: String, CodingKey {
        case accountKey
        case email
        case kind
        case quota
        case lastUpdated
        case message
        case error
        case planType
        case modelQuotas
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountKey = try container.decode(String.self, forKey: .accountKey)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        kind = try container.decode(QuotaSnapshotKind.self, forKey: .kind)
        quota = try container.decodeIfPresent(QuotaMetrics.self, forKey: .quota)
        lastUpdated = try container.decode(Date.self, forKey: .lastUpdated)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        planType = try container.decodeIfPresent(AccountPlanType.self, forKey: .planType)
        modelQuotas = try container.decodeIfPresent([ModelQuota].self, forKey: .modelQuotas) ?? []
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accountKey, forKey: .accountKey)
        try container.encodeIfPresent(email, forKey: .email)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(quota, forKey: .quota)
        try container.encode(lastUpdated, forKey: .lastUpdated)
        try container.encodeIfPresent(message, forKey: .message)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encodeIfPresent(planType, forKey: .planType)
        if modelQuotas.isEmpty == false {
            try container.encode(modelQuotas, forKey: .modelQuotas)
        }
    }
}

struct ProviderQuotaSnapshot: Codable, Sendable, Identifiable {
    var id: ProviderID { provider }

    let provider: ProviderID
    let accounts: [String: AccountQuota]
    let fetchedAt: Date
}
