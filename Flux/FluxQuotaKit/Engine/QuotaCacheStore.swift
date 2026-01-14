import Foundation

actor QuotaCacheStore {
    private let logger: FluxLogger

    init(logger: FluxLogger = .shared) {
        self.logger = logger
    }

    private static let legacyCacheURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Flux", isDirectory: true)
            .appendingPathComponent("quota_cache.json", isDirectory: false)
    }()

    func load() async -> QuotaReport? {
        let url = FluxPaths.quotaCacheURL()
        let legacyURL = Self.legacyCacheURL

        let data = FileManager.default.contents(atPath: url.path)
            ?? FileManager.default.contents(atPath: legacyURL.path)
        guard let data, data.isEmpty == false else { return nil }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(QuotaReport.self, from: data)
        } catch {
            await logger.log(
                .warning,
                category: LogCategories.quota,
                metadata: ["path": .string(url.path)],
                message: "Failed to decode quota cache"
            )
            return nil
        }
    }

    func save(_ report: QuotaReport) async {
        let url = FluxPaths.quotaCacheURL()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601

            let data = try encoder.encode(report)
            try data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
        } catch {
            await logger.log(
                .warning,
                category: LogCategories.quota,
                metadata: ["path": .string(url.path)],
                message: "Failed to write quota cache"
            )
        }
    }
}
