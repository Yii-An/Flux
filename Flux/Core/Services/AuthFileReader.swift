import Foundation

actor AuthFileReader {
    enum ProviderAuthState: Sendable, Hashable {
        case available(source: String, expiresAt: Date?)
        case missing
        case unsupported
        case error(FluxError)
    }

    static let shared = AuthFileReader()

    private let fileManager = FileManager.default
    private let keychainStore: KeychainStore
    private let cliExecutor: CLIExecutor

    init(keychainStore: KeychainStore = .shared, cliExecutor: CLIExecutor = .shared) {
        self.keychainStore = keychainStore
        self.cliExecutor = cliExecutor
    }

    func authState(for provider: ProviderID) async -> ProviderAuthState {
        switch provider.descriptor.authKind {
        case .none:
            return .unsupported
        case .apiKey:
            return await authStateFromKeychain(for: provider)
        case .file:
            return authStateFromFiles(for: provider)
        case .cli:
            return await authStateFromCLI(for: provider)
        case .sqlite:
            return authStateFromSQLite(for: provider)
        }
    }

    private func authStateFromKeychain(for provider: ProviderID) async -> ProviderAuthState {
        do {
            let apiKey = try await keychainStore.getProviderAPIKey(for: provider)
            guard let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .missing
            }
            return .available(source: "keychain", expiresAt: nil)
        } catch let error as FluxError {
            return .error(error)
        } catch {
            return .error(FluxError(code: .unknown, message: "Failed to read provider API key", details: String(describing: error)))
        }
    }

    private func authStateFromFiles(for provider: ProviderID) -> ProviderAuthState {
        for file in knownAuthFiles(for: provider) {
            if fileManager.fileExists(atPath: file.path) {
                return .available(source: file.path, expiresAt: parseExpiresAt(from: file))
            }
        }

        do {
            if let file = try findCLIProxyAuthFile(for: provider) {
                return .available(source: file.path, expiresAt: parseExpiresAt(from: file))
            }
            return .missing
        } catch let error as FluxError {
            return .error(error)
        } catch {
            return .error(
                FluxError(
                    code: .unknown,
                    message: "Failed to scan CLIProxyAPI auth directory",
                    details: String(describing: error)
                )
            )
        }
    }

    private func authStateFromCLI(for provider: ProviderID) async -> ProviderAuthState {
        guard provider == .copilot else {
            return .unsupported
        }

        let gh = await cliExecutor.findBinary(names: ["gh"])
        guard let gh else {
            return .missing
        }

        do {
            let result = try await cliExecutor.run(binaryPath: gh, args: ["auth", "status", "-h", "github.com"], timeout: 5)
            if result.exitCode == 0 {
                return .available(source: "gh auth status", expiresAt: nil)
            }
            return .missing
        } catch let error as FluxError {
            return .error(error)
        } catch {
            return .error(
                FluxError(
                    code: .unknown,
                    message: "Failed to execute gh auth status",
                    details: String(describing: error)
                )
            )
        }
    }

    private func authStateFromSQLite(for provider: ProviderID) -> ProviderAuthState {
        guard provider == .cursor else {
            return .unsupported
        }

        for db in cursorDatabaseCandidates() {
            if fileManager.fileExists(atPath: db.path) {
                return .available(source: db.path, expiresAt: nil)
            }
        }
        return .missing
    }

    private func knownAuthFiles(for provider: ProviderID) -> [URL] {
        let home = fileManager.homeDirectoryForCurrentUser

        switch provider {
        case .claude:
            let base = home.appendingPathComponent(".claude", isDirectory: true)
            return [
                base.appendingPathComponent("auth.json", isDirectory: false),
                base.appendingPathComponent("oauth.json", isDirectory: false),
            ]
        case .codex:
            let base = home.appendingPathComponent(".codex", isDirectory: true)
            return [
                base.appendingPathComponent("auth.json", isDirectory: false)
            ]
        case .gemini, .geminiCLI:
            let base = home.appendingPathComponent(".gemini", isDirectory: true)
            return [
                base.appendingPathComponent("oauth_creds.json", isDirectory: false)
            ]
        default:
            return []
        }
    }

    private func cursorDatabaseCandidates() -> [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        let base = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Cursor", isDirectory: true)
            .appendingPathComponent("User", isDirectory: true)
            .appendingPathComponent("globalStorage", isDirectory: true)

        return [
            base.appendingPathComponent("state.vscdb", isDirectory: false),
            base.appendingPathComponent("state.vscdb.backup", isDirectory: false),
        ]
    }

    private func findCLIProxyAuthFile(for provider: ProviderID) throws -> URL? {
        let authDir = FluxPaths.cliProxyAuthDir()
        guard fileManager.fileExists(atPath: authDir.path) else {
            return nil
        }

        do {
            let files = try fileManager.contentsOfDirectory(
                at: authDir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            let jsonFiles = files.filter { $0.pathExtension.lowercased() == "json" }

            for file in jsonFiles {
                if matchesProvider(provider, candidate: file.lastPathComponent) {
                    return file
                }
                guard let dict = readJSONDictionary(from: file) else { continue }
                if let typeString = extractTypeString(from: dict), matchesProvider(provider, candidate: typeString) {
                    return file
                }
            }
            return nil
        } catch {
            throw FluxError(
                code: .fileMissing,
                message: "Failed to read CLIProxyAPI auth directory",
                details: "\(authDir.path) - \(error)"
            )
        }
    }

    private func readJSONDictionary(from file: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else { return nil }
        return json as? [String: Any]
    }

    private func extractTypeString(from dict: [String: Any]) -> String? {
        let keys = ["provider", "type", "providerId", "provider_id", "service", "name", "kind"]
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty {
                return value
            }
        }
        if let nested = dict["provider"] as? [String: Any] {
            for key in keys {
                if let value = nested[key] as? String, !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    private func matchesProvider(_ provider: ProviderID, candidate: String) -> Bool {
        let normalizedCandidate = normalize(candidate)
        for alias in providerAliases(for: provider) {
            let normalizedAlias = normalize(alias)
            if normalizedCandidate.contains(normalizedAlias) {
                return true
            }
        }
        return false
    }

    private func providerAliases(for provider: ProviderID) -> [String] {
        switch provider {
        case .claude:
            return ["claude", "anthropic"]
        case .codex:
            return ["codex", "openai"]
        case .gemini, .geminiCLI:
            return ["gemini", "gemini-cli", "geminicli"]
        case .vertexAI:
            return ["vertexai", "vertex"]
        case .copilot:
            return ["copilot", "github"]
        case .glm:
            return ["glm", "zhipu"]
        default:
            return [provider.rawValue]
        }
    }

    private func normalize(_ value: String) -> String {
        value
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private func parseExpiresAt(from file: URL) -> Date? {
        guard let dict = readJSONDictionary(from: file) else { return nil }
        if let date = parseExpiresAt(in: dict) {
            return date
        }
        for value in dict.values {
            if let nested = value as? [String: Any], let date = parseExpiresAt(in: nested) {
                return date
            }
        }
        return nil
    }

    private func parseExpiresAt(in dict: [String: Any]) -> Date? {
        let keys = ["expiresAt", "expires_at", "expiry", "expires", "exp", "expiration"]
        for key in keys {
            if let date = parseDateValue(dict[key]) {
                return date
            }
        }
        return nil
    }

    private func parseDateValue(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            return parseEpoch(number.doubleValue)
        }
        if let int = value as? Int {
            return parseEpoch(Double(int))
        }
        if let double = value as? Double {
            return parseEpoch(double)
        }
        if let string = value as? String {
            if let double = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parseEpoch(double)
            }
            let iso = ISO8601DateFormatter()
            return iso.date(from: string)
        }
        return nil
    }

    private func parseEpoch(_ value: Double) -> Date? {
        guard value > 0 else { return nil }
        if value > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: value / 1000.0)
        }
        if value > 1_000_000_000 {
            return Date(timeIntervalSince1970: value)
        }
        return nil
    }
}
