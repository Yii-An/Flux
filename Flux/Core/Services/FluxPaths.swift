import Foundation

enum FluxPaths {
    static func configDir() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("flux", isDirectory: true)
    }

    static func coreDir() -> URL {
        configDir().appendingPathComponent("core", isDirectory: true)
    }

    static func settingsURL() -> URL {
        configDir().appendingPathComponent("settings.json", isDirectory: false)
    }

    static func agentsURL() -> URL {
        configDir().appendingPathComponent("agents.json", isDirectory: false)
    }

    static func cliProxyAuthDir() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".cli-proxy-api", isDirectory: true)
    }

    static func ensureConfigDirExists() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: configDir(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: coreDir(), withIntermediateDirectories: true)
    }
}
