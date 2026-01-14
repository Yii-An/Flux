import Foundation

enum CoreConfig {
    static var healthCheckIntervalSeconds: UInt64 { UInt64(int("HEALTH_CHECK_INTERVAL_SECONDS", default: 30)) }
    static var healthCheckTimeoutSeconds: TimeInterval { TimeInterval(int("HEALTH_CHECK_TIMEOUT_SECONDS", default: 5)) }
    static var healthCheckRetries: Int { int("HEALTH_CHECK_RETRIES", default: 0) }

    static var dryRunWaitSeconds: TimeInterval { TimeInterval(int("DRY_RUN_WAIT_SECONDS", default: 2)) }
    static var maxConsecutiveHealthFailures: Int { int("MAX_CONSECUTIVE_HEALTH_FAILURES", default: 3) }

    static var defaultKeepVersions: Int { int("DEFAULT_KEEP_VERSIONS", default: 2) }
    static var releaseCacheTTLSeconds: Int { int("RELEASE_CACHE_TTL_SECONDS", default: 600) }
    static var downloadTimeoutSeconds: TimeInterval { TimeInterval(int("DOWNLOAD_TIMEOUT_SECONDS", default: 300)) }

    static var enableWebFallback: Bool { bool("ENABLE_WEB_FALLBACK", default: true) }

    private static func int(_ key: String, default defaultValue: Int) -> Int {
        // Env: FLUX_CORE_<KEY>
        if let envValue = ProcessInfo.processInfo.environment["FLUX_CORE_\(key)"],
           let value = Int(envValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return value
        }

        // UserDefaults: flux.core.<keyLower>
        let defaultsKey = "flux.core.\(key.lowercased())"
        let defaults = UserDefaults.standard
        if defaults.object(forKey: defaultsKey) != nil {
            return defaults.integer(forKey: defaultsKey)
        }

        return defaultValue
    }

    private static func bool(_ key: String, default defaultValue: Bool) -> Bool {
        // Env: FLUX_CORE_<KEY>
        if let envValue = ProcessInfo.processInfo.environment["FLUX_CORE_\(key)"] {
            let normalized = envValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["1", "true", "yes", "y", "on"].contains(normalized) { return true }
            if ["0", "false", "no", "n", "off"].contains(normalized) { return false }
        }

        // UserDefaults: flux.core.<keyLower>
        let defaultsKey = "flux.core.\(key.lowercased())"
        let defaults = UserDefaults.standard
        if defaults.object(forKey: defaultsKey) != nil {
            return defaults.bool(forKey: defaultsKey)
        }

        return defaultValue
    }
}
