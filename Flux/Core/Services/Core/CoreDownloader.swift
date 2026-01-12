import Foundation

actor CoreDownloader {
    static let shared = CoreDownloader()

    private let httpClient: HTTPClient
    private let urlSession: URLSession

    init(httpClient: HTTPClient = .shared, urlSession: URLSession = .shared) {
        self.httpClient = httpClient
        self.urlSession = urlSession
    }

    struct Release: Codable, Sendable {
        var tagName: String
        var name: String
        var publishedAt: Date
        var assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case publishedAt = "published_at"
            case assets
        }
    }

    struct Asset: Codable, Sendable {
        var name: String
        var browserDownloadURL: URL
        var size: Int

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case size
        }
    }

    func fetchAvailableReleases() async throws -> [Release] {
        let url = URL(string: "https://api.github.com/repos/anthropics/claude-code/releases")!
        let headers = githubHeaders()
        let data = try await httpClient.get(url: url, headers: headers)

        do {
            return try githubDecoder().decode([Release].self, from: data)
        } catch {
            throw FluxError(code: .parseError, message: "Failed to parse releases", details: String(describing: error))
        }
    }

    func downloadCore(from asset: Asset, progress: (@MainActor (Double) -> Void)? = nil) async throws -> URL {
        var request = URLRequest(url: asset.browserDownloadURL)
        request.httpMethod = "GET"
        for (key, value) in githubHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (bytes, response) = try await urlSession.bytes(for: request)
        try validate(httpResponse: response, requestURL: asset.browserDownloadURL)

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(asset.name, isDirectory: false)
        if FileManager.default.fileExists(atPath: tempURL.path) {
            try? FileManager.default.removeItem(at: tempURL)
        }
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)

        let expectedBytes: Int64 = {
            if response.expectedContentLength > 0 {
                return response.expectedContentLength
            }
            if asset.size > 0 {
                return Int64(asset.size)
            }
            return -1
        }()

        let handle = try FileHandle(forWritingTo: tempURL)
        defer {
            try? handle.close()
        }

        var buffer: [UInt8] = []
        buffer.reserveCapacity(64 * 1024)

        var received: Int64 = 0
        var lastNotifiedProgress: Double = -1

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count == 64 * 1024 {
                try handle.write(contentsOf: Data(buffer))
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)

                if expectedBytes > 0 {
                    let value = min(1, Double(received) / Double(expectedBytes))
                    if value - lastNotifiedProgress >= 0.01 {
                        lastNotifiedProgress = value
                        if let progress {
                            await progress(value)
                        }
                    }
                }
            }
        }

        if !buffer.isEmpty {
            try handle.write(contentsOf: Data(buffer))
            received += Int64(buffer.count)
            buffer.removeAll(keepingCapacity: true)
        }

        if let progress {
            await progress(1)
        }

        return tempURL
    }

    private func githubHeaders() -> [String: String] {
        [
            "Accept": "application/vnd.github+json",
            "User-Agent": "Flux"
        ]
    }

    private func githubDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()

        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            if let date = fractional.date(from: value) {
                return date
            }

            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]

            if let date = plain.date(from: value) {
                return date
            }

            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(value)")
        }

        return decoder
    }

    private func validate(httpResponse response: URLResponse, requestURL: URL) throws {
        guard let http = response as? HTTPURLResponse else {
            throw FluxError(code: .networkError, message: "Invalid HTTP response")
        }

        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 429 {
                throw FluxError(code: .rateLimited, message: "Request rate limited", details: "HTTP 429 \(requestURL.absoluteString)")
            }

            if http.statusCode == 401 {
                throw FluxError(code: .authError, message: "Request unauthorized", details: "HTTP 401 \(requestURL.absoluteString)")
            }

            if http.statusCode == 403 {
                let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining")
                if remaining == "0" {
                    throw FluxError(code: .rateLimited, message: "Request rate limited", details: "HTTP 403 rate limited \(requestURL.absoluteString)")
                }
                throw FluxError(code: .authError, message: "Request unauthorized", details: "HTTP 403 \(requestURL.absoluteString)")
            }

            throw FluxError(code: .networkError, message: "HTTP request failed", details: "HTTP \(http.statusCode) \(requestURL.absoluteString)")
        }
    }
}
