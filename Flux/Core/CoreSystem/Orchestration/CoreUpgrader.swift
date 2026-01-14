import Foundation

actor CoreUpgrader {
    static let shared = CoreUpgrader()

    typealias ProgressHandler = @MainActor @Sendable (_ stage: String, _ fraction: Double?) -> Void

    private let releaseService: CoreReleaseService
    private let assetSelector: CoreAssetSelector
    private let downloader: CoreSystemDownloader
    private let checksumVerifier: CoreChecksumVerifier
    private let extractor: CoreExtractor
    private let inspector: CoreSystemBinaryInspector
    private let runner: CoreRunner
    private let healthChecker: CoreSystemHealthChecker
    private let storage: CoreStorage
    private let stateStore: CoreStateStore
    private let lockManager: LockManager
    private let fileManager: FileManager

    init(
        releaseService: CoreReleaseService = .shared,
        assetSelector: CoreAssetSelector = .shared,
        downloader: CoreSystemDownloader = .shared,
        checksumVerifier: CoreChecksumVerifier = .shared,
        extractor: CoreExtractor = .shared,
        inspector: CoreSystemBinaryInspector = .shared,
        runner: CoreRunner = .shared,
        healthChecker: CoreSystemHealthChecker = .shared,
        storage: CoreStorage = .shared,
        stateStore: CoreStateStore = .shared,
        lockManager: LockManager = .shared,
        fileManager: FileManager = .default
    ) {
        self.releaseService = releaseService
        self.assetSelector = assetSelector
        self.downloader = downloader
        self.checksumVerifier = checksumVerifier
        self.extractor = extractor
        self.inspector = inspector
        self.runner = runner
        self.healthChecker = healthChecker
        self.storage = storage
        self.stateStore = stateStore
        self.lockManager = lockManager
        self.fileManager = fileManager
    }

    func install(version: String, setActive: Bool = true, progress: ProgressHandler? = nil) async throws -> InstalledCoreVersion {
        let lock = try await lockManager.lock(.upgrade)
        let startedAt = Date()
        var resolvedVersion = version
        var installedBinaryURL: URL?

        do {
            try await stateStore.update { state in
                state.lastUpgradeAttempt = UpgradeAttempt(version: version, startedAt: startedAt)
            }

            await progress?("fetch_release", nil)
            let tag = normalizeTag(version)
            let release = try await releaseService.fetchRelease(tag: tag, policy: .reloadRevalidatingCacheData)
            resolvedVersion = release.versionString

            let hostArch = try HostArchDetector.currentHostArch()
            await progress?("select_asset", nil)
            let asset = try await assetSelector.selectMacOSAsset(from: release, hostArch: hostArch)

            await progress?("download", 0)
            let archiveURL = try await downloader.download(asset: asset) { received, expected in
                Task { @MainActor in
                    guard expected > 0 else {
                        progress?("download", nil)
                        return
                    }
                    let fraction = min(1, Double(received) / Double(expected))
                    progress?("download", fraction)
                }
            }

            await progress?("verify_checksum", nil)
            try await checksumVerifier.verify(file: archiveURL, asset: asset, release: release)

            await progress?("extract_install", nil)
            let destination = try await extractor.extractAndInstall(from: archiveURL, version: resolvedVersion)
            installedBinaryURL = destination

            await progress?("validate_binary", nil)
            let selectedArch = try await inspector.validateExecutable(at: destination)

            await progress?("codesign", nil)
            await inspector.bestEffortAdhocCodesign(at: destination)

            await progress?("write_metadata", nil)
            try await writeMetadata(
                version: resolvedVersion,
                release: release,
                asset: asset,
                installedBinary: destination,
                selectedArch: selectedArch
            )

            if setActive {
                await progress?("dry_run_start", nil)
                let dryRunConfigURL = try ensureCoreConfigExists(port: 8080)
                let (_, dryPort) = try await runner.startDryRun(executable: destination, configURL: dryRunConfigURL)

                try await Task.sleep(nanoseconds: UInt64(CoreConfig.dryRunWaitSeconds * 1_000_000_000))

                await progress?("dry_run_health", nil)
                let ok = await healthChecker.isHealthy(port: dryPort, retries: CoreConfig.healthCheckRetries)

                await progress?("dry_run_stop", nil)
                await runner.stop()

                guard ok else {
                    throw CoreError(code: .healthCheckFailed, message: "Dry-run health check failed", details: "port=\(dryPort)")
                }

                await progress?("promote", nil)
                do {
                    try await storage.setCurrent(resolvedVersion)
                } catch let err as CoreError {
                    throw CoreError(code: .promoteFailed, message: "Failed to set current core version", details: err.details ?? err.message)
                } catch {
                    throw CoreError(code: .promoteFailed, message: "Failed to set current core version", details: String(describing: error))
                }

                try await stateStore.update { state in
                    state.activeVersion = resolvedVersion
                    state.lastKnownGoodVersion = resolvedVersion
                    state.consecutiveHealthFailures = 0
                    if var attempt = state.lastUpgradeAttempt {
                        attempt.finishedAt = Date()
                        attempt.result = "success"
                        attempt.errorCode = nil
                        state.lastUpgradeAttempt = attempt
                    }
                }

                await progress?("prune", nil)
                try await storage.prune(keep: CoreConfig.defaultKeepVersions)
            }

            await progress?("done", 1)
            let result = try await installedVersionOrFallback(version: resolvedVersion)
            await lock.unlock()
            return result
        } catch {
            if installedBinaryURL != nil {
                try? await storage.remove(version: resolvedVersion)
            }
            try? await recordFailure(version: resolvedVersion, startedAt: startedAt, error: error)
            await lock.unlock()
            throw error
        }
    }

    func upgradeToLatest(progress: ProgressHandler? = nil) async throws -> InstalledCoreVersion {
        await progress?("fetch_latest", nil)
        let latest = try await releaseService.fetchLatest(policy: .reloadRevalidatingCacheData)
        return try await install(version: latest.versionString, setActive: true, progress: progress)
    }

    func installFromFile(
        fileURL: URL,
        version: String = "custom",
        setActive: Bool = true,
        progress: ProgressHandler? = nil
    ) async throws -> InstalledCoreVersion {
        let lock = try await lockManager.lock(.upgrade)
        let startedAt = Date()

        var resolvedVersion = version
        var installedBinaryURL: URL?

        do {
            try await stateStore.update { state in
                state.lastUpgradeAttempt = UpgradeAttempt(version: resolvedVersion, startedAt: startedAt)
            }

            await progress?("copy_local_binary", nil)
            try await storage.ensureDirectories()
            let versionDir = await storage.versionDirURL(version: resolvedVersion)
            try fileManager.createDirectory(at: versionDir, withIntermediateDirectories: true)

            let destination = versionDir.appendingPathComponent("CLIProxyAPI", isDirectory: false)
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: fileURL, to: destination)
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: destination.path)
            installedBinaryURL = destination

            await progress?("validate_binary", nil)
            let selectedArch = try await inspector.validateExecutable(at: destination)

            await progress?("codesign", nil)
            await inspector.bestEffortAdhocCodesign(at: destination)

            await progress?("write_metadata", nil)
            try await writeLocalMetadata(
                version: resolvedVersion,
                sourceFileURL: fileURL,
                installedBinary: destination,
                selectedArch: selectedArch
            )

            if setActive {
                await progress?("dry_run_start", nil)
                let dryRunConfigURL = try ensureCoreConfigExists(port: 8080)
                let (_, dryPort) = try await runner.startDryRun(executable: destination, configURL: dryRunConfigURL)

                try await Task.sleep(nanoseconds: UInt64(CoreConfig.dryRunWaitSeconds * 1_000_000_000))

                await progress?("dry_run_health", nil)
                let ok = await healthChecker.isHealthy(port: dryPort, retries: CoreConfig.healthCheckRetries)

                await progress?("dry_run_stop", nil)
                await runner.stop()

                guard ok else {
                    throw CoreError(code: .healthCheckFailed, message: "Dry-run health check failed", details: "port=\(dryPort)")
                }

                await progress?("promote", nil)
                do {
                    try await storage.setCurrent(resolvedVersion)
                } catch let err as CoreError {
                    throw CoreError(code: .promoteFailed, message: "Failed to set current core version", details: err.details ?? err.message)
                } catch {
                    throw CoreError(code: .promoteFailed, message: "Failed to set current core version", details: String(describing: error))
                }

                try await stateStore.update { state in
                    state.activeVersion = resolvedVersion
                    state.lastKnownGoodVersion = resolvedVersion
                    state.consecutiveHealthFailures = 0
                    if var attempt = state.lastUpgradeAttempt {
                        attempt.finishedAt = Date()
                        attempt.result = "success"
                        attempt.errorCode = nil
                        state.lastUpgradeAttempt = attempt
                    }
                }

                await progress?("prune", nil)
                try await storage.prune(keep: CoreConfig.defaultKeepVersions)
            }

            await progress?("done", 1)
            let result = try await installedVersionOrFallback(version: resolvedVersion)
            await lock.unlock()
            return result
        } catch {
            if installedBinaryURL != nil {
                try? await storage.remove(version: resolvedVersion)
            }
            try? await recordFailure(version: resolvedVersion, startedAt: startedAt, error: error)
            await lock.unlock()
            throw error
        }
    }

    // MARK: - Helpers

    private func normalizeTag(_ versionOrTag: String) -> String {
        if versionOrTag.hasPrefix("v") { return versionOrTag }
        return "v\(versionOrTag)"
    }

    private func installedVersionOrFallback(version: String) async throws -> InstalledCoreVersion {
        let installed = try await storage.listInstalled()
        if let found = installed.first(where: { $0.version == version }) {
            return found
        }
        // Fallback: build minimal model.
        return InstalledCoreVersion(
            version: version,
            installedAt: Date(),
            executableURL: CoreSystemPaths.executableURL(version: version, binaryName: "CLIProxyAPI"),
            sha256: nil,
            arch: nil,
            isCurrent: (try? await storage.currentVersion()) == version
        )
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

        guard !fileManager.fileExists(atPath: configURL.path) else { return configURL }

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

        if text.contains("auth-dir: \"\(absoluteAuthDir)\"") {
            text = text.replacingOccurrences(of: "auth-dir: \"\(absoluteAuthDir)\"", with: "auth-dir: \"\(tildeAuthDir)\"")
        }

        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            // best-effort
        }
    }

    private func writeMetadata(
        version: String,
        release: CoreRelease,
        asset: CoreAsset,
        installedBinary: URL,
        selectedArch: HostArch
    ) async throws {
        let installedAt = Date()
        let sha256 = try FileHasher.sha256Hex(of: installedBinary)

        let metadata = CoreVersionMetadata(
            version: version,
            installedAt: installedAt,
            validatedAt: Date(),
            source: .init(
                repo: "router-for-me/CLIProxyAPIPlus",
                tag: release.tagName,
                assetName: asset.name,
                assetURL: asset.browserDownloadURL,
                assetSHA256: asset.sha256Digest
            ),
            binary: .init(
                nameInArchive: nil,
                finalName: "CLIProxyAPI",
                sha256: sha256,
                arch: selectedArch,
                format: "macho",
                isExecutable: fileManager.isExecutableFile(atPath: installedBinary.path)
            )
        )

        let url = await storage.metadataURL(version: version)
        do {
            let data = try CoreJSON.encoder.encode(metadata)
            try data.write(to: url, options: [.atomic])
        } catch {
            throw CoreError(code: .fileWriteFailed, message: "Failed to write metadata", details: "\(url.path) - \(error)")
        }
    }

    private func writeLocalMetadata(
        version: String,
        sourceFileURL: URL,
        installedBinary: URL,
        selectedArch: HostArch
    ) async throws {
        let installedAt = Date()
        let sha256 = try FileHasher.sha256Hex(of: installedBinary)

        let metadata = CoreVersionMetadata(
            version: version,
            installedAt: installedAt,
            validatedAt: Date(),
            source: .init(
                repo: "local",
                tag: version,
                assetName: sourceFileURL.lastPathComponent,
                assetURL: sourceFileURL,
                assetSHA256: nil
            ),
            binary: .init(
                nameInArchive: nil,
                finalName: "CLIProxyAPI",
                sha256: sha256,
                arch: selectedArch,
                format: "macho",
                isExecutable: fileManager.isExecutableFile(atPath: installedBinary.path)
            )
        )

        let url = await storage.metadataURL(version: version)
        do {
            let data = try CoreJSON.encoder.encode(metadata)
            try data.write(to: url, options: [.atomic])
        } catch {
            throw CoreError(code: .fileWriteFailed, message: "Failed to write metadata", details: "\(url.path) - \(error)")
        }
    }

    private func recordFailure(version: String, startedAt: Date, error: Error) async throws {
        let code: CoreErrorCode?
        if let coreError = error as? CoreError {
            code = coreError.code
        } else {
            code = nil
        }

        try await stateStore.update { state in
            var attempt = state.lastUpgradeAttempt ?? UpgradeAttempt(version: version, startedAt: startedAt)
            attempt.finishedAt = Date()
            attempt.result = "failed"
            attempt.errorCode = code
            state.lastUpgradeAttempt = attempt
        }
    }
}
