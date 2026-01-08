import Foundation
import Security

@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let externalBinaryPath = "cliProxyAPIBinaryPath"
        static let cliProxyAPIVersion = "cliProxyAPIVersion"
        static let cliProxyAPIPort = "cliProxyAPIPort"
        static let cliProxyAPIConfigPath = "cliProxyAPIConfigPath"
        static let managementPort = "managementPort"
        static let keychainService = "com.flux.app"
        static let keychainAccount = "managementPassword"
    }

    @Published var externalBinaryPath: String? {
        didSet {
            if let path = externalBinaryPath {
                defaults.set(path, forKey: Keys.externalBinaryPath)
            } else {
                defaults.removeObject(forKey: Keys.externalBinaryPath)
            }
        }
    }

    @Published var cliProxyAPIVersion: String?

    @Published var cliProxyAPIPort: Int {
        didSet {
            defaults.set(cliProxyAPIPort, forKey: Keys.cliProxyAPIPort)
        }
    }

    @Published var cliProxyAPIConfigPath: String? {
        didSet {
            if let path = cliProxyAPIConfigPath {
                defaults.set(path, forKey: Keys.cliProxyAPIConfigPath)
            } else {
                defaults.removeObject(forKey: Keys.cliProxyAPIConfigPath)
            }
        }
    }

    @Published var managementPort: Int {
        didSet {
            defaults.set(managementPort, forKey: Keys.managementPort)
        }
    }

    @Published var managementPassword: String = "" {
        didSet {
            savePasswordToKeychain(managementPassword)
        }
    }

    var managementBaseURL: URL {
        URL(string: "http://127.0.0.1:\(managementPort)/v0/management")!
    }

    var currentBinaryPath: String? {
        ProxyStorageManager.shared.currentBinaryPath?.path
    }

    init() {
        self.externalBinaryPath = defaults.string(forKey: Keys.externalBinaryPath)
        self.cliProxyAPIVersion = defaults.string(forKey: Keys.cliProxyAPIVersion)
        self.cliProxyAPIPort = defaults.integer(forKey: Keys.cliProxyAPIPort)
        self.cliProxyAPIConfigPath = defaults.string(forKey: Keys.cliProxyAPIConfigPath)
        self.managementPort = defaults.integer(forKey: Keys.managementPort)
        if self.cliProxyAPIPort == 0 {
            self.cliProxyAPIPort = 8317 // CLIProxyAPI default port
        }
        if self.managementPort == 0 {
            self.managementPort = 8317 // Same as proxy port
        }
        self.managementPassword = loadPasswordFromKeychain() ?? ""
    }

    // MARK: - Keychain

    private func savePasswordToKeychain(_ password: String) {
        let data = password.data(using: .utf8)!

        // Delete existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Keys.keychainService,
            kSecAttrAccount as String: Keys.keychainAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new item
        guard !password.isEmpty else { return }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Keys.keychainService,
            kSecAttrAccount as String: Keys.keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func loadPasswordFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Keys.keychainService,
            kSecAttrAccount as String: Keys.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            return nil
        }

        return password
    }
}
