import Foundation

protocol QuotaFetcher: Sendable {
    var providerID: ProviderID { get }
    func fetchQuotas(authFiles: [AuthFileInfo]) async -> [String: AccountQuota]
}
