import Foundation

enum FluxPaths {
    static func configDir() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("flux", isDirectory: true)
    }

    static func cacheDir() -> URL {
        configDir().appendingPathComponent("cache", isDirectory: true)
    }

    static func coreDir() -> URL {
        configDir().appendingPathComponent("core", isDirectory: true)
    }

    /// CLIProxyAPI/CLIProxyAPIPlus config file path used by Core process.
    /// Stored directly under `~/.config/flux/` for user visibility and compatibility.
    static func coreConfigURL() -> URL {
        configDir().appendingPathComponent("config.yaml", isDirectory: false)
    }

    static func settingsURL() -> URL {
        configDir().appendingPathComponent("settings.json", isDirectory: false)
    }

    static func agentsURL() -> URL {
        configDir().appendingPathComponent("agents.json", isDirectory: false)
    }

    static func quotaCacheURL() -> URL {
        cacheDir().appendingPathComponent("quota_cache.json", isDirectory: false)
    }

    static func antigravityProjectCacheURL() -> URL {
        cacheDir().appendingPathComponent("antigravity_project_cache.json", isDirectory: false)
    }

    static func cliProxyAuthDir() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".cli-proxy-api", isDirectory: true)
    }

    /// Formats paths under the current user's home directory using `~` prefix.
    /// Example: `/Users/alice/.cli-proxy-api` -> `~/.cli-proxy-api`
    static func tildePath(for url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let homePath = home.standardizedFileURL.path
        let path = url.standardizedFileURL.path

        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") {
            let suffix = path.dropFirst(homePath.count)
            return "~" + suffix
        }
        return path
    }

    /// Expands leading `~` into the current user's home directory.
    static func expandTildeInPath(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    static func ensureConfigDirExists() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: configDir(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cacheDir(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: coreDir(), withIntermediateDirectories: true)
    }
}
