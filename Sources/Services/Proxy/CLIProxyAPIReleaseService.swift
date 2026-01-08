import Foundation
import os.log

enum CLIProxyAPIReleaseServiceError: Error, LocalizedError {
    case invalidURL
    case httpError(statusCode: Int, body: String?)
    case decodingError(Error)
    case networkError(Error)
    case noSuitableAssetFound

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的 GitHub API URL"
        case .httpError(let code, let body):
            return "GitHub API 请求失败 (\(code)): \(body ?? "无响应内容")"
        case .decodingError(let error):
            return "解析 GitHub 响应失败: \(error.localizedDescription)"
        case .networkError(let error):
            return "网络错误: \(error.localizedDescription)"
        case .noSuitableAssetFound:
            return "未找到适用于当前 macOS 平台的安装包"
        }
    }
}

actor CLIProxyAPIReleaseService {
    private let source: CLIProxyAPIReleaseSource
    private let session: URLSession
    private let logger = Logger(subsystem: "com.flux.app", category: "CLIProxyAPIRelease")
    private let timeout: TimeInterval = 30

    init(source: CLIProxyAPIReleaseSource = .official) {
        self.source = source

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public

    func fetchLatestRelease() async throws -> GitHubRelease {
        let url = try apiURL(path: "releases/latest", queryItems: [])
        return try await performRequest(url: url, decode: GitHubRelease.self)
    }

    func fetchReleases(page: Int, perPage: Int) async throws -> [GitHubRelease] {
        let queryItems = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(perPage))
        ]
        let url = try apiURL(path: "releases", queryItems: queryItems)
        return try await performRequest(url: url, decode: [GitHubRelease].self)
    }

    func bestAsset(for release: GitHubRelease) -> GitHubReleaseAsset? {
        let candidates = release.assets.filter { isSupportedAssetName($0.name) }
        guard !candidates.isEmpty else { return nil }

        let preferredKeywords = preferredArchitectureKeywords()
        return candidates.max { a, b in
            assetScore(a, preferredArchKeywords: preferredKeywords) < assetScore(b, preferredArchKeywords: preferredKeywords)
        }
    }

    func download(asset: GitHubReleaseAsset, progress: @Sendable @escaping (DownloadProgress) -> Void) async throws -> Data {
        guard let url = URL(string: asset.browserDownloadUrl) else {
            throw CLIProxyAPIReleaseServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("Flux", forHTTPHeaderField: "User-Agent")

        let delegate = DownloadProgressDelegate(progressHandler: progress)
        do {
            let (fileURL, response) = try await session.download(for: request, delegate: delegate)
            defer { try? FileManager.default.removeItem(at: fileURL) }

            guard let http = response as? HTTPURLResponse else {
                throw CLIProxyAPIReleaseServiceError.networkError(URLError(.badServerResponse))
            }

            guard (200...299).contains(http.statusCode) else {
                let body = try? String(contentsOf: fileURL, encoding: .utf8)
                throw CLIProxyAPIReleaseServiceError.httpError(statusCode: http.statusCode, body: body)
            }

            return try Data(contentsOf: fileURL)
        } catch let error as CLIProxyAPIReleaseServiceError {
            throw error
        } catch {
            throw CLIProxyAPIReleaseServiceError.networkError(error)
        }
    }

    // MARK: - Private

    private func apiURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.\(source.host)"
        components.path = "/repos/\(source.owner)/\(source.name)/\(path)"
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else { throw CLIProxyAPIReleaseServiceError.invalidURL }
        return url
    }

    private func performRequest<T: Decodable>(url: URL, decode type: T.Type) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Flux", forHTTPHeaderField: "User-Agent")

        logger.debug("GET \(url.absoluteString)")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw CLIProxyAPIReleaseServiceError.networkError(URLError(.badServerResponse))
            }

            guard (200...299).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8)
                throw CLIProxyAPIReleaseServiceError.httpError(statusCode: http.statusCode, body: body)
            }

            do {
                let decoder = JSONDecoder()
                return try decoder.decode(type, from: data)
            } catch {
                throw CLIProxyAPIReleaseServiceError.decodingError(error)
            }
        } catch let error as CLIProxyAPIReleaseServiceError {
            throw error
        } catch {
            throw CLIProxyAPIReleaseServiceError.networkError(error)
        }
    }

    private func preferredArchitectureKeywords() -> [String] {
        #if arch(arm64)
        return ["arm64", "aarch64"]
        #elseif arch(x86_64)
        return ["x86_64", "amd64", "x64"]
        #else
        return []
        #endif
    }

    private func isSupportedAssetName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.contains("windows") || lower.contains("win32") || lower.contains("linux") {
            return false
        }
        if lower.hasSuffix(".zip") || lower.hasSuffix(".tar.gz") {
            return true
        }
        // 有些 release 可能直接上传无扩展名二进制
        if !lower.contains(".") {
            return true
        }
        return false
    }

    private func assetScore(_ asset: GitHubReleaseAsset, preferredArchKeywords: [String]) -> Int {
        let name = asset.name.lowercased()
        var score = 0

        if name.contains("macos") || name.contains("darwin") || name.contains("mac") {
            score += 100
        }

        if name.contains("universal") {
            score += 60
        }

        if preferredArchKeywords.contains(where: { name.contains($0) }) {
            score += 50
        }

        #if arch(arm64)
        if name.contains("x86_64") || name.contains("amd64") || name.contains("x64") {
            score -= 40
        }
        #elseif arch(x86_64)
        if name.contains("arm64") || name.contains("aarch64") {
            score -= 40
        }
        #endif

        if name.hasSuffix(".zip") {
            score += 10
        } else if name.hasSuffix(".tar.gz") {
            score += 5
        }

        return score
    }

    private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
        private let progressHandler: @Sendable (DownloadProgress) -> Void

        init(progressHandler: @Sendable @escaping (DownloadProgress) -> Void) {
            self.progressHandler = progressHandler
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // Handled by URLSession async API return value.
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            progressHandler(DownloadProgress(bytesWritten: totalBytesWritten, totalBytes: totalBytesExpectedToWrite))
        }
    }
}
