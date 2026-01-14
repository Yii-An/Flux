import Foundation

enum CachePolicy: String, Sendable {
    /// Return cached releases if present & not expired; otherwise load.
    case returnCacheElseLoad
    /// Return cached releases even if expired; never load. Throws if cache missing.
    case returnCacheDataDontLoad
    /// Always load, using If-None-Match when cached ETag is present; accepts 304.
    case reloadRevalidatingCacheData
    /// Always load; does not send If-None-Match.
    case reloadIgnoringCacheData
}

actor CoreReleaseService {
    static let shared = CoreReleaseService()

    private let session: URLSession
    private let cache: CoreReleaseCache
    private let webFetcher: CoreWebReleaseFetcher

    private let baseURL = URL(string: "https://api.github.com/repos/router-for-me/CLIProxyAPIPlus")!
    private let webFallbackLimit = 20

    init(session: URLSession = .shared, cache: CoreReleaseCache = .shared, webFetcher: CoreWebReleaseFetcher = .shared) {
        self.session = session
        self.cache = cache
        self.webFetcher = webFetcher
    }

    func fetchReleases(policy: CachePolicy = .returnCacheElseLoad) async throws -> [CoreRelease] {
        let cached = try await cache.load()

        switch policy {
        case .returnCacheDataDontLoad:
            guard let cached else {
                throw CoreError(code: .cacheCorrupted, message: "No cached releases available")
            }
            return cached.releases
        case .returnCacheElseLoad:
            if let cached, !(await cache.isExpired(cached)) {
                return cached.releases
            }
            do {
                return try await loadReleases(revalidatingWith: cached?.etag)
            } catch {
                return try await fallbackReleasesIfEnabled(originalError: error, cached: cached, limit: webFallbackLimit)
            }
        case .reloadRevalidatingCacheData:
            do {
                return try await loadReleases(revalidatingWith: cached?.etag)
            } catch {
                return try await fallbackReleasesIfEnabled(originalError: error, cached: cached, limit: webFallbackLimit)
            }
        case .reloadIgnoringCacheData:
            do {
                return try await loadReleases(revalidatingWith: nil)
            } catch {
                return try await fallbackReleasesIfEnabled(originalError: error, cached: cached, limit: webFallbackLimit)
            }
        }
    }

    func fetchRelease(tag: String, policy: CachePolicy = .returnCacheElseLoad) async throws -> CoreRelease {
        let cached = try await cache.load()
        if let cachedRelease = cached?.releases.first(where: { $0.tagName == tag }) {
            switch policy {
            case .returnCacheDataDontLoad:
                return cachedRelease
            case .returnCacheElseLoad:
                if let cached, !(await cache.isExpired(cached)) {
                    return cachedRelease
                }
            case .reloadRevalidatingCacheData, .reloadIgnoringCacheData:
                break
            }
        } else if policy == .returnCacheDataDontLoad {
            throw CoreError(code: .cacheCorrupted, message: "Release not found in cache", details: "tag=\(tag)")
        }

        let url = baseURL.appendingPathComponent("releases/tags/\(tag)")
        do {
            return try await loadSingleRelease(url: url)
        } catch {
            return try await fallbackReleaseIfEnabled(originalError: error, tag: tag)
        }
    }

    func fetchLatest(policy: CachePolicy = .returnCacheElseLoad) async throws -> CoreRelease {
        // Prefer list endpoint (ordered desc) to benefit from ETag cache.
        do {
            let releases = try await fetchReleases(policy: policy)
            guard let first = releases.first else {
                throw CoreError(code: .parseError, message: "No releases available")
            }
            return first
        } catch {
            if policy == .returnCacheDataDontLoad || !CoreConfig.enableWebFallback {
                throw error
            }
            let tag = try await webFetcher.fetchLatestTag()
            let release = try await webFetcher.fetchRelease(tag: tag)
            try await upsertCachedRelease(release)
            return release
        }
    }

    // MARK: - Private

    private func loadReleases(revalidatingWith etag: String?) async throws -> [CoreRelease] {
        let url = baseURL.appendingPathComponent("releases")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyGitHubHeaders(to: &request)
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CoreError(code: .networkError, message: "Invalid HTTP response")
        }

        if http.statusCode == 304 {
            guard let cached = try await cache.load() else {
                throw CoreError(code: .cacheCorrupted, message: "Received 304 but cache is missing")
            }
            try await cache.touchFetchedAt()
            return cached.releases
        }

        try validate(http: http, url: url)

        let releases: [CoreRelease]
        do {
            releases = try CoreJSON.decoder.decode([CoreRelease].self, from: data)
        } catch {
            throw CoreError(code: .parseError, message: "Failed to parse releases", details: String(describing: error))
        }

        let responseETag = http.value(forHTTPHeaderField: "ETag")
        try await cache.store(etag: responseETag, releases: releases)
        return releases
    }

    private func loadSingleRelease(url: URL) async throws -> CoreRelease {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyGitHubHeaders(to: &request)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CoreError(code: .networkError, message: "Invalid HTTP response")
        }

        try validate(http: http, url: url)

        do {
            return try CoreJSON.decoder.decode(CoreRelease.self, from: data)
        } catch {
            throw CoreError(code: .parseError, message: "Failed to parse release", details: String(describing: error))
        }
    }

    private func applyGitHubHeaders(to request: inout URLRequest) {
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Flux", forHTTPHeaderField: "User-Agent")
    }

    private func validate(http: HTTPURLResponse, url: URL) throws {
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 429 {
                throw CoreError(code: .rateLimited, message: "Request rate limited", details: "HTTP 429 \(url.absoluteString)")
            }

            if http.statusCode == 403 {
                if http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                    throw CoreError(code: .rateLimited, message: "Request rate limited", details: "HTTP 403 rate limited \(url.absoluteString)")
                }
            }

            throw CoreError(code: .networkError, message: "HTTP request failed", details: "HTTP \(http.statusCode) \(url.absoluteString)")
        }
    }

    private func fallbackReleasesIfEnabled(originalError: Error, cached: CoreReleaseCache.CacheFile?, limit: Int) async throws -> [CoreRelease] {
        guard CoreConfig.enableWebFallback else { throw originalError }

        do {
            let releases = try await webFetcher.fetchReleases(limit: limit)
            try await cache.store(etag: nil, releases: releases, ttlSeconds: cached?.ttlSeconds)
            return releases
        } catch {
            if let webError = error as? CoreError {
                throw CoreError(
                    code: webError.code,
                    message: webError.message,
                    details: mergedDetails(webError.details, "apiError=\(String(describing: originalError))"),
                    recoverySuggestion: webError.recoverySuggestion
                )
            }

            throw CoreError(code: .webFetchFailed, message: "Failed to fetch releases via web fallback", details: "apiError=\(String(describing: originalError)) webError=\(String(describing: error))")
        }
    }

    private func fallbackReleaseIfEnabled(originalError: Error, tag: String) async throws -> CoreRelease {
        guard CoreConfig.enableWebFallback else { throw originalError }

        do {
            let release = try await webFetcher.fetchRelease(tag: tag)
            try await upsertCachedRelease(release)
            return release
        } catch {
            if let webError = error as? CoreError {
                throw CoreError(
                    code: webError.code,
                    message: webError.message,
                    details: mergedDetails(webError.details, "tag=\(tag) apiError=\(String(describing: originalError))"),
                    recoverySuggestion: webError.recoverySuggestion
                )
            }

            throw CoreError(code: .webFetchFailed, message: "Failed to fetch release via web fallback", details: "tag=\(tag) apiError=\(String(describing: originalError)) webError=\(String(describing: error))")
        }
    }

    private func upsertCachedRelease(_ release: CoreRelease) async throws {
        let cached = try await cache.load()
        var releases = cached?.releases ?? []
        releases.removeAll(where: { $0.tagName == release.tagName })
        releases.insert(release, at: 0)
        // Web fallback data is not associated with an API ETag; keep cache consistent by clearing it.
        try await cache.store(etag: nil, releases: releases, ttlSeconds: cached?.ttlSeconds)
    }

    private func mergedDetails(_ existing: String?, _ addition: String) -> String {
        guard let existing, !existing.isEmpty else { return addition }
        return "\(existing) | \(addition)"
    }
}
