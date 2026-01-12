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
}

struct ProviderQuotaSnapshot: Codable, Sendable, Identifiable {
    var id: ProviderID { provider }

    let provider: ProviderID
    let accounts: [String: AccountQuota]
    let fetchedAt: Date
}
