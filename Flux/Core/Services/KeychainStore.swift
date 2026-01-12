import Foundation
import Security

actor KeychainStore {
    static let shared = KeychainStore()

    private let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "com.flux.Flux") {
        self.service = service
    }

    func setSecret(_ secret: String, account: String) throws {
        guard !account.isEmpty else {
            throw FluxError(code: .unknown, message: "Keychain account is empty")
        }
        guard let data = secret.data(using: .utf8) else {
            throw FluxError(code: .unknown, message: "Failed to encode secret as UTF-8")
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess {
            return
        }
        if status != errSecDuplicateItem {
            throw makeError(status: status, operation: "SecItemAdd", account: account)
        }

        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus != errSecSuccess {
            throw makeError(status: updateStatus, operation: "SecItemUpdate", account: account)
        }
    }

    func getSecret(account: String) throws -> String? {
        guard !account.isEmpty else {
            throw FluxError(code: .unknown, message: "Keychain account is empty")
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw makeError(status: status, operation: "SecItemCopyMatching", account: account)
        }
        guard let data = result as? Data else {
            throw FluxError(
                code: .unknown,
                message: "Keychain returned invalid data type",
                details: "account=\(account)"
            )
        }
        guard let secret = String(data: data, encoding: .utf8) else {
            throw FluxError(
                code: .unknown,
                message: "Failed to decode keychain data as UTF-8 string",
                details: "account=\(account)"
            )
        }
        return secret
    }

    func deleteSecret(account: String) throws {
        guard !account.isEmpty else {
            throw FluxError(code: .unknown, message: "Keychain account is empty")
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            return
        }
        throw makeError(status: status, operation: "SecItemDelete", account: account)
    }

    func apiKeyAccount(for provider: ProviderID) -> String {
        "provider-api-key-\(provider.rawValue)"
    }

    func setProviderAPIKey(_ apiKey: String, for provider: ProviderID) throws {
        try setSecret(apiKey, account: apiKeyAccount(for: provider))
    }

    func getProviderAPIKey(for provider: ProviderID) throws -> String? {
        try getSecret(account: apiKeyAccount(for: provider))
    }

    func deleteProviderAPIKey(for provider: ProviderID) throws {
        try deleteSecret(account: apiKeyAccount(for: provider))
    }

    private func makeError(status: OSStatus, operation: String, account: String) -> FluxError {
        let statusMessage = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return FluxError(
            code: .unknown,
            message: "Keychain operation failed: \(operation)",
            details: "account=\(account), status=\(status) (\(statusMessage))"
        )
    }
}
