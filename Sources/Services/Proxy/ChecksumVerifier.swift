import CryptoKit
import Foundation

enum ChecksumVerifier {
    static func computeSHA256(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func verifySHA256(data: Data, expected: String) -> Bool {
        let normalizedExpected = normalizeHex(expected)
        guard !normalizedExpected.isEmpty else { return false }
        return computeSHA256(data: data) == normalizedExpected
    }

    private static func normalizeHex(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("sha256:") {
            trimmed = String(trimmed.dropFirst("sha256:".count))
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

