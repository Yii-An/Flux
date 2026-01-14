import Foundation

actor AntigravityProjectCacheStore {
    static let shared = AntigravityProjectCacheStore()

    private static let legacyCacheFileURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Flux", isDirectory: true)
            .appendingPathComponent("antigravity_project_cache.json", isDirectory: false)
    }()

    struct ProjectCacheEntry: Codable, Sendable {
        enum Source: String, Codable, Sendable {
            case loadCodeAssist
            case authFileHint
            case persistentCache
        }

        let projectId: String
        let ttlSeconds: TimeInterval
        let updatedAt: Date
        let source: Source

        var isExpired: Bool {
            Date() >= updatedAt.addingTimeInterval(ttlSeconds)
        }
    }

    func load() async -> [String: ProjectCacheEntry] {
        let url = FluxPaths.antigravityProjectCacheURL()
        let legacyURL = Self.legacyCacheFileURL

        let data = FileManager.default.contents(atPath: url.path)
            ?? FileManager.default.contents(atPath: legacyURL.path)
        guard let data else {
            return [:]
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode([String: ProjectCacheEntry].self, from: data)
            return decoded.filter { !$0.value.isExpired }
        } catch {
            return [:]
        }
    }

    func save(_ cache: [String: ProjectCacheEntry]) async {
        let url = FluxPaths.antigravityProjectCacheURL()

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601

            let data = try encoder.encode(cache)
            try data.write(to: url, options: [.atomic])
        } catch {
            // Best effort.
        }
    }
}
