import Foundation

actor CoreChecksumVerifier {
    static let shared = CoreChecksumVerifier()

    private let session: URLSession
    private let cache: CoreReleaseCache

    init(session: URLSession = .shared, cache: CoreReleaseCache = .shared) {
        self.session = session
        self.cache = cache
    }

    func expectedSHA256(for asset: CoreAsset, in release: CoreRelease) async throws -> String {
        if let digest = asset.sha256Digest, !digest.isEmpty {
            return digest.lowercased()
        }

        if let checksumsAsset = release.assets.first(where: { $0.lowercasedName == "checksums.txt" }) {
            let text = try await downloadText(from: checksumsAsset.browserDownloadURL)
            if let parsed = parseChecksums(text: text)[asset.name] {
                return parsed.lowercased()
            }
            throw CoreError(code: .checksumMissing, message: "Checksum not found", details: "asset=\(asset.name)")
        }

        throw CoreError(code: .checksumMissing, message: "No checksum available", details: "asset=\(asset.name)")
    }

    func verify(file: URL, asset: CoreAsset, release: CoreRelease) async throws {
        let expected = try await expectedSHA256(for: asset, in: release)
        let actual: String
        do {
            actual = try FileHasher.sha256Hex(of: file).lowercased()
        } catch {
            throw CoreError(code: .checksumMismatch, message: "Failed to compute checksum", details: "\(file.path) - \(error)")
        }

        guard actual == expected.lowercased() else {
            throw CoreError(
                code: .checksumMismatch,
                message: "Checksum verification failed",
                details: "expected=\(expected) actual=\(actual) file=\(file.lastPathComponent)"
            )
        }
    }

    // MARK: - Private

    private func downloadText(from url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Flux", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CoreError(code: .networkError, message: "Invalid HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 429 {
                throw CoreError(code: .rateLimited, message: "Request rate limited", details: "HTTP 429 \(url.absoluteString)")
            }
            if http.statusCode == 403, http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                throw CoreError(code: .rateLimited, message: "Request rate limited", details: "HTTP 403 rate limited \(url.absoluteString)")
            }
            throw CoreError(code: .networkError, message: "HTTP request failed", details: "HTTP \(http.statusCode) \(url.absoluteString)")
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw CoreError(code: .parseError, message: "Failed to decode checksums file", details: url.absoluteString)
        }
        return text
    }

    private func parseChecksums(text: String) -> [String: String] {
        var result: [String: String] = [:]

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            // Format: "<sha256>  <filename>"
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2 else { continue }
            let sha = parts[0]
            let file = parts[1]
            result[file] = sha
        }

        return result
    }
}

