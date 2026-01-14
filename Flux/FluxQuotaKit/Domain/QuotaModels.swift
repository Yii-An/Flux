import Foundation

enum FluxQuotaUnit: String, Sendable, Codable {
    case requests
    case tokens
    case credits
    case percent
}

enum FluxQuotaStatus: String, Sendable, Codable {
    case ok
    case authMissing
    case error
    case stale
    case loading
}

enum FluxQuotaSource: String, Sendable, Codable {
    case oauthApi
}

struct QuotaWindow: Sendable, Codable, Hashable, Identifiable {
    var id: String
    var label: String
    var unit: FluxQuotaUnit

    var usedPercent: Double?
    var remainingPercent: Double?
    var used: Int?
    var limit: Int?
    var remaining: Int?
    var resetAt: Date?
}

struct AccountQuotaReport: Sendable, Codable, Hashable, Identifiable {
    var id: String { "\(provider.rawValue)::\(accountKey)" }

    var provider: ProviderKind
    var accountKey: String
    var email: String?
    var plan: String?

    var status: FluxQuotaStatus
    var source: FluxQuotaSource
    var fetchedAt: Date

    var windows: [QuotaWindow]
    var errorMessage: String?
}

struct ProviderQuotaReport: Sendable, Codable, Hashable, Identifiable {
    var id: ProviderKind { provider }
    var provider: ProviderKind
    var fetchedAt: Date
    var accounts: [AccountQuotaReport]
}

struct QuotaReport: Sendable, Codable, Hashable {
    var generatedAt: Date
    var providers: [ProviderQuotaReport]
}
