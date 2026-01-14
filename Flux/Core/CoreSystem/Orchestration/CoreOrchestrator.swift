import Foundation

actor CoreOrchestrator {
    static let shared = CoreOrchestrator()

    private let upgrader: CoreUpgrader
    private let storage: CoreStorage
    private let runner: CoreRunner
    private let inspector: CoreSystemBinaryInspector
    private let healthChecker: CoreSystemHealthChecker
    private let stateStore: CoreStateStore
    private let releaseService: CoreReleaseService
    private let fileManager: FileManager

    private var lifecycle: CoreLifecycleState = .idle
    private var continuations: [UUID: AsyncStream<CoreLifecycleState>.Continuation] = [:]
    private var healthMonitorTask: Task<Void, Never>?
    private var didAttemptLegacyMigration = false

    private let corePort: UInt16 = 8080

    init(
        upgrader: CoreUpgrader = .shared,
        storage: CoreStorage = .shared,
        runner: CoreRunner = .shared,
        inspector: CoreSystemBinaryInspector = .shared,
        healthChecker: CoreSystemHealthChecker = .shared,
        stateStore: CoreStateStore = .shared,
        releaseService: CoreReleaseService = .shared,
        fileManager: FileManager = .default
    ) {
        self.upgrader = upgrader
        self.storage = storage
        self.runner = runner
        self.inspector = inspector
        self.healthChecker = healthChecker
        self.stateStore = stateStore
        self.releaseService = releaseService
        self.fileManager = fileManager
    }

    func currentState() -> CoreLifecycleState {
        lifecycle
    }

    func runtimeState() -> CoreRuntimeState {
        switch lifecycle {
        case .starting:
            return .starting
        case .stopping:
            return .stopping
        case .installing, .promoting, .rollingBack:
            return .starting
        case .running(_, let pid, _, _):
            return .running(pid: pid)
        case .testing(_, let pid, _, _):
            return .running(pid: pid)
        case .idle:
            if isCoreInstalledSync() { return .stopped }
            return .notInstalled
        case .error(let error):
            return .error(mapToFluxError(error))
        }
    }

    func restart() async {
        await stop()
        await start()
    }

    func logFileURL() -> URL? {
        let newURL = CoreSystemPaths.logsDirURL().appendingPathComponent("core.log", isDirectory: false)
        if fileManager.fileExists(atPath: newURL.path) { return newURL }

        let legacyURL = FluxPaths.coreDir().appendingPathComponent("core.log", isDirectory: false)
        if fileManager.fileExists(atPath: legacyURL.path) { return legacyURL }

        return newURL
    }

    func stateStream() -> AsyncStream<CoreLifecycleState> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.yield(lifecycle)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id: id) }
            }
        }
    }

    func listVersions() async throws -> [InstalledCoreVersion] {
        await migrateLegacyIfNeeded()
        return try await storage.listInstalled()
    }

    func listReleases(policy: CachePolicy = .returnCacheElseLoad) async throws -> [CoreRelease] {
        await migrateLegacyIfNeeded()
        return try await releaseService.fetchReleases(policy: policy)
    }

    func start() async {
        await migrateLegacyIfNeeded()
        do {
            setLifecycle(.starting(targetVersion: nil, port: corePort))

            let configURL = try ensureCoreConfigExists(port: corePort)
            guard let executable = try await storage.currentExecutableURL() else {
                setLifecycle(.error(CoreError(code: .fileMissing, message: "Core not installed")))
                return
            }

            _ = try await inspector.validateExecutable(at: executable)
            let pid = try await runner.start(executable: executable, configURL: configURL, port: corePort)

            try await stateStore.update { state in
                state.consecutiveHealthFailures = 0
            }

            setLifecycle(.running(activeVersion: (try? await storage.currentVersion()) ?? "unknown", pid: pid, port: corePort, startedAt: Date()))
            startHealthMonitor()
        } catch let error as CoreError {
            setLifecycle(.error(error))
        } catch {
            setLifecycle(.error(CoreError(code: .coreStartFailed, message: "Failed to start core", details: String(describing: error))))
        }
    }

    func stop() async {
        stopHealthMonitor()
        setLifecycle(.stopping)
        await runner.stop()
        setLifecycle(.idle)
    }

    func install(version: String, progress: CoreUpgrader.ProgressHandler? = nil) async throws -> InstalledCoreVersion {
        await migrateLegacyIfNeeded()

        setLifecycle(.installing(version: version, phase: "start"))
        do {
            let installed = try await upgrader.install(version: version, setActive: true) { [weak self] stage, fraction in
                progress?(stage, fraction)
                Task { await self?.setLifecycle(.installing(version: version, phase: stage)) }
            }
            setLifecycle(.idle)
            return installed
        } catch let error as CoreError {
            setLifecycle(.error(error))
            throw error
        } catch {
            let wrapped = CoreError(code: .unknown, message: "Install failed", details: String(describing: error))
            setLifecycle(.error(wrapped))
            throw wrapped
        }
    }

    func installFromFile(
        fileURL: URL,
        version: String = "custom",
        setActive: Bool = true,
        progress: CoreUpgrader.ProgressHandler? = nil
    ) async throws -> InstalledCoreVersion {
        await migrateLegacyIfNeeded()

        setLifecycle(.installing(version: version, phase: "local"))
        do {
            let installed = try await upgrader.installFromFile(fileURL: fileURL, version: version, setActive: setActive) { [weak self] stage, fraction in
                progress?(stage, fraction)
                Task { await self?.setLifecycle(.installing(version: version, phase: stage)) }
            }
            setLifecycle(.idle)
            return installed
        } catch let error as CoreError {
            setLifecycle(.error(error))
            throw error
        } catch {
            let wrapped = CoreError(code: .unknown, message: "Install failed", details: String(describing: error))
            setLifecycle(.error(wrapped))
            throw wrapped
        }
    }

    func install(version: String) async {
        await migrateLegacyIfNeeded()
        setLifecycle(.installing(version: version, phase: "upgrade"))
        do {
            _ = try await install(version: version, progress: nil)
            setLifecycle(.idle)
        } catch let error as CoreError {
            setLifecycle(.error(error))
        } catch {
            setLifecycle(.error(CoreError(code: .unknown, message: "Install failed", details: String(describing: error))))
        }
    }

    func upgradeToLatest() async {
        await migrateLegacyIfNeeded()
        setLifecycle(.installing(version: "latest", phase: "upgrade"))
        do {
            _ = try await upgrader.upgradeToLatest(progress: nil)
            setLifecycle(.idle)
        } catch let error as CoreError {
            setLifecycle(.error(error))
        } catch {
            setLifecycle(.error(CoreError(code: .unknown, message: "Upgrade failed", details: String(describing: error))))
        }
    }

    func rollbackIfNeeded() async {
        await migrateLegacyIfNeeded()
        do {
            let state = try await stateStore.read()
            guard state.consecutiveHealthFailures >= CoreConfig.maxConsecutiveHealthFailures else { return }
            guard let lastKnownGood = state.lastKnownGoodVersion else { return }
            guard let current = try await storage.currentVersion(), current != lastKnownGood else {
                try await stateStore.update { $0.consecutiveHealthFailures = 0 }
                return
            }

            // Prevent overlapping rollbacks/monitors.
            stopHealthMonitor()

            setLifecycle(.rollingBack(from: current, to: lastKnownGood))
            await runner.stop()

            do {
                try await storage.setCurrent(lastKnownGood)
            } catch let err as CoreError {
                throw CoreError(code: .rollbackFailed, message: "Failed to rollback core version", details: err.details ?? err.message)
            } catch {
                throw CoreError(code: .rollbackFailed, message: "Failed to rollback core version", details: String(describing: error))
            }

            try await stateStore.update { state in
                state.activeVersion = lastKnownGood
                state.consecutiveHealthFailures = 0
            }

            await start()
        } catch let error as CoreError {
            setLifecycle(.error(error))
        } catch {
            setLifecycle(.error(CoreError(code: .rollbackFailed, message: "Rollback failed", details: String(describing: error))))
        }
    }

    // MARK: - Health monitor

    private func startHealthMonitor() {
        stopHealthMonitor()
        healthMonitorTask = Task { [weak self] in
            await self?.healthMonitorLoop()
        }
    }

    private func stopHealthMonitor() {
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
    }

    private func healthMonitorLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: CoreConfig.healthCheckIntervalSeconds * 1_000_000_000)
            guard !Task.isCancelled else { break }

            guard case .running = lifecycle else { continue }

            let ok = await healthChecker.isHealthy(port: corePort, retries: CoreConfig.healthCheckRetries)
            if ok {
                try? await stateStore.update { $0.consecutiveHealthFailures = 0 }
                continue
            }

            try? await stateStore.update { state in
                state.consecutiveHealthFailures += 1
            }

            await rollbackIfNeeded()
            break
        }
    }

    // MARK: - Helpers

    private func setLifecycle(_ new: CoreLifecycleState) {
        lifecycle = new
        for (_, continuation) in continuations {
            continuation.yield(new)
        }
    }

    private func removeContinuation(id: UUID) {
        continuations[id] = nil
    }

    private func isCoreInstalledSync() -> Bool {
        let current = CoreSystemPaths.currentSymlinkURL()
        if fileManager.fileExists(atPath: current.path) { return true }

        let versionsDir = CoreSystemPaths.versionsDirURL()
        guard let urls = try? fileManager.contentsOfDirectory(at: versionsDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return false
        }
        for dir in urls {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let binary = dir.appendingPathComponent("CLIProxyAPI", isDirectory: false)
            if fileManager.isExecutableFile(atPath: binary.path) { return true }
        }
        return false
    }

    private func mapToFluxError(_ error: CoreError) -> FluxError {
        let code: FluxErrorCode
        switch error.code {
        case .fileMissing:
            code = .fileMissing
        case .parseError, .cacheCorrupted, .htmlParseError:
            code = .parseError
        case .networkError, .downloadFailed, .webFetchFailed:
            code = .networkError
        case .rateLimited:
            code = .rateLimited
        case .noCompatibleAsset, .unsupportedAssetFormat:
            code = .unsupported
        case .coreBinaryInvalidFormat, .invalidArchive, .binaryNotFoundInArchive, .pathTraversalDetected, .symlinkEscapeDetected:
            code = .coreBinaryInvalidFormat
        case .coreBinaryArchMismatch:
            code = .coreBinaryArchMismatch
        case .rosettaRequired:
            code = .rosettaRequired
        case .coreStartFailed, .coreStartTimeout:
            code = .coreStartFailed
        default:
            code = .unknown
        }

        return FluxError(code: code, message: error.message, details: error.details, recoverySuggestion: error.recoverySuggestion)
    }

    private func migrateLegacyIfNeeded() async {
        guard didAttemptLegacyMigration == false else { return }
        didAttemptLegacyMigration = true

        do {
            if (try await storage.currentVersion()) != nil { return }
            if (try await stateStore.read()).activeVersion != nil { return }
        } catch {
            // proceed best-effort
        }

        let legacyActiveURL = FluxPaths.coreDir().appendingPathComponent("active.json", isDirectory: false)
        if let legacyVersion = readLegacyActiveVersion(at: legacyActiveURL) {
            do {
                try await storage.setCurrent(legacyVersion)
                try await stateStore.update { state in
                    state.activeVersion = legacyVersion
                    state.lastKnownGoodVersion = legacyVersion
                }
                return
            } catch {
                // fall through
            }
        }

        let legacyBinaryURL = FluxPaths.coreDir().appendingPathComponent("CLIProxyAPI", isDirectory: false)
        guard fileManager.isExecutableFile(atPath: legacyBinaryURL.path) else { return }

        // Legacy single-binary install fallback.
        let version = "legacy"
        do {
            try await storage.ensureDirectories()
            let dir = await storage.versionDirURL(version: version)
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            let destination = dir.appendingPathComponent("CLIProxyAPI", isDirectory: false)
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: legacyBinaryURL, to: destination)
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: destination.path)

            try await storage.setCurrent(version)
            try await stateStore.update { state in
                state.activeVersion = version
                state.lastKnownGoodVersion = version
            }
        } catch {
            // ignore
        }
    }

    private func readLegacyActiveVersion(at url: URL) -> String? {
        struct LegacyActiveVersionFile: Codable { var version: String }
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let parsed = try? JSONDecoder().decode(LegacyActiveVersionFile.self, from: data) else { return nil }
        let v = parsed.version.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    private func ensureCoreConfigExists(port: UInt16) throws -> URL {
        try FluxPaths.ensureConfigDirExists()

        let configURL = FluxPaths.coreConfigURL()
        let legacyConfigURL = FluxPaths.coreDir().appendingPathComponent("config.yaml", isDirectory: false)

        if fileManager.fileExists(atPath: configURL.path) {
            try normalizeConfigFilePathsIfNeeded(at: configURL)
            return configURL
        }

        if fileManager.fileExists(atPath: legacyConfigURL.path) {
            do {
                try fileManager.copyItem(at: legacyConfigURL, to: configURL)
                try normalizeConfigFilePathsIfNeeded(at: configURL)
                return configURL
            } catch {
                // fall through to creating a new config
            }
        }

        guard !fileManager.fileExists(atPath: configURL.path) else {
            return configURL
        }

        let authDir = FluxPaths.tildePath(for: FluxPaths.cliProxyAuthDir())
        let defaultConfig = """
        host: \"127.0.0.1\"
        port: \(port)
        auth-dir: \"\(authDir)\"
        proxy-url: \"\"

        api-keys:
          - \"flux-local-\(UUID().uuidString.prefix(8))\"

        remote-management:
          allow-remote: false
        """

        do {
            try defaultConfig.write(to: configURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: configURL.path)
        } catch {
            throw CoreError(code: .fileWriteFailed, message: "Failed to write core config", details: "\(configURL.path) - \(error)")
        }

        return configURL
    }

    private func normalizeConfigFilePathsIfNeeded(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        guard var text = try? String(contentsOf: url, encoding: .utf8) else { return }

        let absoluteAuthDir = FluxPaths.cliProxyAuthDir().standardizedFileURL.path
        let tildeAuthDir = FluxPaths.tildePath(for: FluxPaths.cliProxyAuthDir())

        // Replace only the exact absolute auth dir to avoid unintended rewrites.
        if text.contains("auth-dir: \"\(absoluteAuthDir)\"") {
            text = text.replacingOccurrences(of: "auth-dir: \"\(absoluteAuthDir)\"", with: "auth-dir: \"\(tildeAuthDir)\"")
        }

        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            // best-effort
        }
    }
}
