import Foundation

enum CredentialSourceType: String, Sendable, Codable {
    case cliProxyAuthDir
    case officialFile
}

protocol Credential: Sendable {
    var provider: ProviderKind { get }
    var sourceType: CredentialSourceType { get }

    var accountKey: String { get }
    var email: String? { get }

    var accessToken: String { get }
    var refreshToken: String? { get }
    var expiresAt: Date? { get }
    var isExpired: Bool { get }

    var filePath: String? { get }
    var metadata: [String: String] { get }
}

protocol CredentialProvider: Sendable {
    var provider: ProviderKind { get }
    var sourceType: CredentialSourceType { get }

    func listCredentials() async -> [any Credential]
    func refresh(_ credential: any Credential) async throws -> any Credential
    func persist(_ credential: any Credential) async throws
}

protocol QuotaDataSource: Sendable {
    var provider: ProviderKind { get }
    var source: FluxQuotaSource { get }

    func isAvailable(for credential: any Credential) async -> Bool
    func fetchQuota(for credential: any Credential) async throws -> AccountQuotaReport
}
