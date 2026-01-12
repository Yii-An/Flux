import Foundation

struct QuotaRiskItem: Identifiable, Sendable, Hashable {
    let providerID: ProviderID
    let displayNameKey: String
    let percentUsed: Double
    let used: Int?
    let limit: Int?
    let remaining: Int?
    let resetAt: Date?

    var id: ProviderID { providerID }

    func hash(into hasher: inout Hasher) {
        hasher.combine(providerID)
        hasher.combine(percentUsed)
    }

    static func == (lhs: QuotaRiskItem, rhs: QuotaRiskItem) -> Bool {
        return lhs.providerID == rhs.providerID && lhs.percentUsed == rhs.percentUsed
    }
}

