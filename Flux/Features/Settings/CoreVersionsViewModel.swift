import Foundation
import Observation

@Observable
@MainActor
final class CoreVersionsViewModel {
    var installedVersions: [CoreVersion] = []
    var availableReleases: [CoreDownloader.Release] = []

    var isLoadingReleases: Bool = false
    var downloadingVersion: String?
    var downloadProgress: Double = 0
    var errorMessage: String?

    private let versionManager: CoreVersionManager
    private let downloader: CoreDownloader

    init(versionManager: CoreVersionManager = .shared, downloader: CoreDownloader = .shared) {
        self.versionManager = versionManager
        self.downloader = downloader
    }

    func load() async {
        await loadInstalledVersions()
        await fetchReleases()
    }

    func loadInstalledVersions() async {
        errorMessage = nil
        do {
            installedVersions = try await versionManager.listInstalledVersions()
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
            availableReleases = try await downloader.fetchAvailableReleases()
        } catch {
            availableReleases = []
            errorMessage = error.localizedDescription
        }
    }

    func downloadVersion(_ release: CoreDownloader.Release) async {
        guard downloadingVersion == nil else { return }
        errorMessage = nil

        guard let asset = selectMacOSAsset(from: release) else {
            errorMessage = "No macOS binary found".localizedStatic()
            return
        }

        downloadingVersion = release.tagName
        downloadProgress = 0
        defer {
            downloadingVersion = nil
            downloadProgress = 0
        }

        do {
            let tempFile = try await downloader.downloadCore(from: asset) { value in
                self.downloadProgress = value
            }

            _ = try await versionManager.installVersion(from: tempFile, version: release.tagName, setActive: true)
            await loadInstalledVersions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func activateVersion(_ version: CoreVersion) async {
        errorMessage = nil
        do {
            try await versionManager.setActiveVersion(version.version)
            await loadInstalledVersions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func selectMacOSAsset(from release: CoreDownloader.Release) -> CoreDownloader.Asset? {
        release.assets.first { asset in
            let name = asset.name.lowercased()
            return name.contains("darwin") || name.contains("macos")
        }
    }
}
