import Foundation
import Observation

enum AuthFileProvider: String, Codable, Sendable {
    case codex
    case antigravity
    case geminiCLI
    case unknown
}

struct AuthFileInfo: Codable, Sendable, Hashable, Identifiable {
    var id: String { filePath }

    let filename: String
    let provider: AuthFileProvider
    let accessToken: String
    let refreshToken: String?
    let email: String?
    let expiredAt: Date?
    let accountId: String?
    let filePath: String
}

@Observable
final class CLIProxyAuthScanner: @unchecked Sendable {
    private let logger: FluxLogger

    init(logger: FluxLogger = .shared) {
        self.logger = logger
    }

    func scanAuthFiles() async -> [AuthFileInfo] {
        let directoryURL = FluxPaths.cliProxyAuthDir()
        let directoryPath = directoryURL.path
        let results = Self.scanDirectory(directoryPath: directoryPath)
        await logger.log(.debug, category: LogCategories.auth, metadata: ["count": .int(results.count), "dir": .string(directoryPath)], message: "scanAuthFiles")
        return results
    }

    private static func scanDirectory(directoryPath: String) -> [AuthFileInfo] {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: directoryPath) else { return [] }

        let entries: [String]
        do {
            entries = try fileManager.contentsOfDirectory(atPath: directoryPath)
        } catch {
            return []
        }

        return entries
            .filter { $0.hasSuffix(".json") }
            .compactMap { filename -> AuthFileInfo? in
                let filePath = (directoryPath as NSString).appendingPathComponent(filename)
                return parseAuthFile(filePath: filePath, filename: filename)
            }
    }

    private static func parseAuthFile(filePath: String, filename: String) -> AuthFileInfo? {
        guard let data = FileManager.default.contents(atPath: filePath) else { return nil }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }

        let provider = detectProvider(filename: filename, json: json)
        guard provider != .unknown else { return nil }

        let tokenContainer: [String: Any]? = {
            if let nested = json["token"] as? [String: Any] { return nested }
            if let nested = json["oauth"] as? [String: Any] { return nested }
            return nil
        }()

        let accessToken =
            firstNonEmptyString(json, keys: ["access_token", "accessToken", "session_key", "oauth_token"])
            ?? tokenContainer.flatMap { firstNonEmptyString($0, keys: ["access_token", "accessToken", "oauth_token"]) }

        guard let accessToken else {
            return nil
        }

        let refreshToken =
            firstNonEmptyString(json, keys: ["refresh_token", "refreshToken"])
            ?? tokenContainer.flatMap { firstNonEmptyString($0, keys: ["refresh_token", "refreshToken"]) }

        let email =
            firstNonEmptyString(json, keys: ["email", "user_email", "account_email", "username", "login"])
            ?? tokenContainer.flatMap { firstNonEmptyString($0, keys: ["email"]) }

        let accountId = firstNonEmptyString(json, keys: ["account_id", "accountId", "chatgpt_account_id", "chatgptAccountId"])
        let expiredAt = parseExpiryDate(json) ?? tokenContainer.flatMap(parseExpiryDate)

        return AuthFileInfo(
            filename: filename,
            provider: provider,
            accessToken: accessToken,
            refreshToken: refreshToken,
            email: email,
            expiredAt: expiredAt,
            accountId: accountId,
            filePath: filePath
        )
    }

    private static func detectProvider(filename: String, json: [String: Any]) -> AuthFileProvider {
        let lower = filename.lowercased()
        if lower.hasPrefix("codex-") { return .codex }
        if lower.hasPrefix("antigravity-") || lower == "antigravity.json" { return .antigravity }
        if lower.hasPrefix("gemini-") { return .geminiCLI }

        if let typeValue = firstNonEmptyString(json, keys: ["type", "provider", "providerId", "provider_id", "service", "kind"])?.lowercased() {
            if typeValue.contains("codex") || typeValue.contains("openai") { return .codex }
            if typeValue.contains("antigravity") { return .antigravity }
            if typeValue.contains("gemini") { return .geminiCLI }
        }

        return .unknown
    }

    private static func firstNonEmptyString(_ json: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = json[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func parseExpiryDate(_ json: [String: Any]) -> Date? {
        let dateKeys = ["expired", "expires_at", "expiresAt", "expiry", "expiry_date", "expiryDate"]
        for key in dateKeys {
            if let date = parseDate(json[key]) {
                return date
            }
        }
        return nil
    }

    private static func parseDate(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let seconds = value as? TimeInterval { return dateFromEpoch(seconds) }
        if let number = value as? NSNumber { return dateFromEpoch(number.doubleValue) }

        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: trimmed) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) { return date }

        if let seconds = TimeInterval(trimmed) {
            return dateFromEpoch(seconds)
        }

        return nil
    }

    private static func dateFromEpoch(_ secondsOrMilliseconds: TimeInterval) -> Date {
        // Heuristic: values larger than year ~2286 in seconds are likely milliseconds.
        if secondsOrMilliseconds > 10_000_000_000 {
            return Date(timeIntervalSince1970: secondsOrMilliseconds / 1000)
        }
        return Date(timeIntervalSince1970: secondsOrMilliseconds)
    }
}
