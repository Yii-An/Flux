import Foundation

actor CoreReleaseCache {
    static let shared = CoreReleaseCache()

    private let fileManager: FileManager
    private let defaultTTLSeconds: Int

    init(fileManager: FileManager = .default, defaultTTLSeconds: Int = 10 * 60) {
        self.fileManager = fileManager
        self.defaultTTLSeconds = defaultTTLSeconds
    }

    struct CacheFile: Codable, Sendable, Equatable {
        var etag: String?
        var fetchedAt: Date
        var ttlSeconds: Int
        var releases: [CoreRelease]
    }

    func load() throws -> CacheFile? {
        try ensureCacheDirectory()

        let url = cacheFileURL()
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            return try CoreJSON.decoder.decode(CacheFile.self, from: data)
        } catch {
            throw CoreError(code: .cacheCorrupted, message: "Failed to read releases cache", details: "\(url.path) - \(error)")
        }
    }

    func store(etag: String?, releases: [CoreRelease], fetchedAt: Date = Date(), ttlSeconds: Int? = nil) throws {
        try ensureCacheDirectory()

        let url = cacheFileURL()
        let file = CacheFile(
            etag: etag,
            fetchedAt: fetchedAt,
            ttlSeconds: ttlSeconds ?? defaultTTLSeconds,
            releases: releases
        )

        do {
            let data = try CoreJSON.encoder.encode(file)
            try data.write(to: url, options: [.atomic])
        } catch {
            throw CoreError(code: .fileWriteFailed, message: "Failed to write releases cache", details: "\(url.path) - \(error)")
        }
    }

    func touchFetchedAt(_ date: Date = Date()) throws {
        guard var file = try load() else { return }
        file.fetchedAt = date
        try store(etag: file.etag, releases: file.releases, fetchedAt: file.fetchedAt, ttlSeconds: file.ttlSeconds)
    }

    func isExpired(_ file: CacheFile, now: Date = Date()) -> Bool {
        now.timeIntervalSince(file.fetchedAt) > TimeInterval(max(0, file.ttlSeconds))
    }

    func effectiveTTLSeconds(_ file: CacheFile?) -> Int {
        file?.ttlSeconds ?? defaultTTLSeconds
    }

    func cacheFileURL() -> URL {
        CoreSystemPaths.releasesDirURL().appendingPathComponent("github_releases_cache.json", isDirectory: false)
    }

    private func ensureCacheDirectory() throws {
        try FluxPaths.ensureConfigDirExists()
        try fileManager.createDirectory(at: CoreSystemPaths.coreRootDirURL(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: CoreSystemPaths.releasesDirURL(), withIntermediateDirectories: true)
    }
}

