import Foundation

struct ProviderStatusItem: Identifiable, Sendable, Hashable {
    let providerID: ProviderID
    let kind: QuotaSnapshotKind
    let percentUsed: Double?
    let message: String?

    var id: ProviderID { providerID }
}

