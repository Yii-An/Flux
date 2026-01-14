import Foundation
import Observation

@Observable
@MainActor
final class CoreVersionsViewModel {
    var installedVersions: [InstalledCoreVersion] = []
    var availableReleases: [CoreRelease] = []

    var isLoadingReleases: Bool = false
    var downloadingVersion: String?
    var downloadProgress: Double = 0
    var errorMessage: String?

    private let orchestrator: CoreOrchestrator
    private let storage: CoreStorage
    private let releaseService: CoreReleaseService

    init(
        orchestrator: CoreOrchestrator = .shared,
        storage: CoreStorage = .shared,
        releaseService: CoreReleaseService = .shared
    ) {
        self.orchestrator = orchestrator
        self.storage = storage
        self.releaseService = releaseService
    }

    func load() async {
        await loadInstalledVersions()
        await fetchReleases()
    }

    func loadInstalledVersions() async {
        errorMessage = nil
        do {
            installedVersions = try await orchestrator.listVersions()
        } catch {
            installedVersions = []
            errorMessage = error.localizedDescription
        }
    }

    func fetchReleases() async {
        guard !isLoadingReleases else { return }
        isLoadingReleases = true
        defer { isLoadingReleases = false }

        errorMessage = nil
        do {
            availableReleases = try await releaseService.fetchReleases(policy: .returnCacheElseLoad)
        } catch {
            availableReleases = []
            errorMessage = error.localizedDescription
        }
    }

    func downloadVersion(_ release: CoreRelease) async {
        guard downloadingVersion == nil else { return }
        errorMessage = nil

        downloadingVersion = release.tagName
        downloadProgress = 0
        defer {
            downloadingVersion = nil
            downloadProgress = 0
        }

        do {
            _ = try await orchestrator.install(version: release.tagName) { [weak self] stage, fraction in
                guard let self else { return }
                if stage == "download" {
                    if let fraction { self.downloadProgress = fraction }
                } else if self.downloadProgress == 0 {
                    self.downloadProgress = 0.01
                }
            }
            await loadInstalledVersions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func activateVersion(_ version: InstalledCoreVersion) async {
        errorMessage = nil
        do {
            try await storage.setCurrent(version.version)

            let runtime = await orchestrator.runtimeState()
            if runtime.isRunning {
                await orchestrator.restart()
            }
            await loadInstalledVersions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
