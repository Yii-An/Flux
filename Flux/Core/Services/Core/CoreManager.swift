import Foundation

actor CoreManager {
    static let shared = CoreManager()

    private let versionManager: CoreVersionManager
    private let coreProcess: CoreProcess
    private let healthChecker: CoreHealthChecker
    private let settingsStore: SettingsStore

    private let fileManager: FileManager

    private var runtimeState: CoreRuntimeState = .stopped
    private var startedAt: Date?

    private var healthMonitorTask: Task<Void, Never>?
    private var healthCheckFailures: Int = 0

    private let maxHealthCheckFailures = 3
    private let healthCheckIntervalSeconds: UInt64 = 30
    private let corePort: UInt16 = 8080

    init(
        versionManager: CoreVersionManager = .shared,
        coreProcess: CoreProcess = .shared,
        healthChecker: CoreHealthChecker = .shared,
        settingsStore: SettingsStore = .shared,
        fileManager: FileManager = .default
    ) {
        self.versionManager = versionManager
        self.coreProcess = coreProcess
        self.healthChecker = healthChecker
        self.settingsStore = settingsStore
        self.fileManager = fileManager
    }

    func state() -> CoreRuntimeState {
        runtimeState
    }

    func startedAtDate() -> Date? {
        startedAt
    }

    func port() -> UInt16 {
        corePort
    }

    func endpointBaseURL(host: String = "127.0.0.1") -> URL? {
        URL(string: "http://\(host):\(corePort)")
    }

    func logFileURL() -> URL {
        FluxPaths.coreDir().appendingPathComponent("core.log", isDirectory: false)
    }

    func installedVersions() async -> [CoreVersion] {
        do {
            return try await versionManager.listInstalledVersions()
        } catch {
            return []
        }
    }

    func start() async {
        switch runtimeState {
        case .starting, .running:
            return
        default:
            break
        }

        runtimeState = .starting
        healthCheckFailures = 0
        startedAt = nil

        do {
            let configURL = try ensureCoreConfigExists()
            guard let binaryURL = try await versionManager.activeBinaryURL() else {
                runtimeState = .notInstalled
                startedAt = nil
                return
            }

            let pid = try await coreProcess.start(
                executableURL: binaryURL,
                arguments: ["-config", configURL.path],
                workingDirectory: binaryURL.deletingLastPathComponent(),
                logFileURL: logFileURL()
            )

            startedAt = Date()
            runtimeState = .running(pid: pid)
            startHealthMonitor()

            let keepCount = await loadKeepCoreVersions()
            try? await versionManager.pruneVersions(keeping: keepCount)
        } catch let error as FluxError {
            runtimeState = .error(error)
            startedAt = nil
        } catch {
            runtimeState = .error(FluxError(code: .coreStartFailed, message: "Failed to start core", details: String(describing: error)))
            startedAt = nil
        }
    }

    func stop() async {
        stopHealthMonitor()

        switch runtimeState {
        case .stopped, .notInstalled:
            return
        default:
            break
        }

        runtimeState = .stopping
        await coreProcess.stop()
        runtimeState = .stopped
        healthCheckFailures = 0
        startedAt = nil
    }

    func restart() async {
        await stop()
        await start()
    }

    func setActiveVersion(_ version: String) async {
        do {
            try await versionManager.setActiveVersion(version)
            let keepCount = await loadKeepCoreVersions()
            try? await versionManager.pruneVersions(keeping: keepCount)

            if case .running = runtimeState {
                await restart()
            }
        } catch let error as FluxError {
            runtimeState = .error(error)
        } catch {
            runtimeState = .error(FluxError(code: .unknown, message: "Failed to activate core version", details: String(describing: error)))
        }
    }

    private func loadKeepCoreVersions() async -> Int {
        do {
            let settings = try await settingsStore.load()
            return min(2, max(1, settings.keepCoreVersions))
        } catch {
            return 2
        }
    }

    private func startHealthMonitor() {
        stopHealthMonitor()
        healthCheckFailures = 0
        healthMonitorTask = Task { [self] in
            await healthMonitorLoop()
        }
    }

    private func stopHealthMonitor() {
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
    }

    private func healthMonitorLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: healthCheckIntervalSeconds * 1_000_000_000)
            guard !Task.isCancelled else { break }
            await performHealthCheck()
        }
    }

    private func performHealthCheck() async {
        guard case .running = runtimeState else {
            healthCheckFailures = 0
            return
        }

        let isHealthy = await healthChecker.isHealthy(port: corePort)
        if isHealthy {
            healthCheckFailures = 0
            return
        }

        healthCheckFailures += 1
        if healthCheckFailures < maxHealthCheckFailures {
            return
        }

        healthCheckFailures = 0

        let shouldAutoRestart = (try? await settingsStore.load())?.autoRestartCore ?? true
        guard shouldAutoRestart else {
            return
        }

        await restart()
    }

    private func ensureCoreConfigExists() throws -> URL {
        try FluxPaths.ensureConfigDirExists()

        let configURL = FluxPaths.coreDir().appendingPathComponent("config.yaml", isDirectory: false)
        guard !fileManager.fileExists(atPath: configURL.path) else {
            return configURL
        }

        let authDir = FluxPaths.cliProxyAuthDir().path
        let defaultConfig = """
        host: "127.0.0.1"
        port: \(corePort)
        auth-dir: "\(authDir)"
        proxy-url: ""

        api-keys:
          - "flux-local-\(UUID().uuidString.prefix(8))"

        remote-management:
          allow-remote: false
        """

        do {
            try defaultConfig.write(to: configURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: configURL.path)
        } catch {
            throw FluxError(code: .unknown, message: "Failed to write core config", details: "\(configURL.path) - \(error)")
        }

        return configURL
    }
}
