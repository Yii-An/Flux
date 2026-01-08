import Foundation
import os.log

@MainActor
final class ManagedProxyCoordinator: ObservableObject {
    @Published var availableLatest: GitHubRelease?
    @Published var installedVersions: [ProxyVersion] = []
    @Published var currentVersion: String?
    @Published var isCheckingUpdate: Bool = false
    @Published var isInstalling: Bool = false
    @Published var downloadProgress: DownloadProgress?
    @Published var error: String?

    private let releaseService: CLIProxyAPIReleaseService
    private let storageManager: ProxyStorageManager
    private let logger = Logger(subsystem: "com.flux.app", category: "ManagedProxy")

    init(
        releaseService: CLIProxyAPIReleaseService = CLIProxyAPIReleaseService(),
        storageManager: ProxyStorageManager = ProxyStorageManager.shared
    ) {
        self.releaseService = releaseService
        self.storageManager = storageManager
    }

    func refresh() async {
        error = nil
        installedVersions = await storageManager.listInstalledVersions()
        currentVersion = await storageManager.getCurrentVersion()
    }

    func checkForUpdate() async {
        isCheckingUpdate = true
        error = nil
        defer { isCheckingUpdate = false }

        do {
            availableLatest = try await releaseService.fetchLatestRelease()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func install(release: GitHubRelease) async {
        guard !isInstalling else { return }
        isInstalling = true
        downloadProgress = nil
        error = nil
        defer { isInstalling = false }

        do {
            guard let asset = await releaseService.bestAsset(for: release) else {
                throw CLIProxyAPIReleaseServiceError.noSuitableAssetFound
            }

            let weakSelf = WeakBox(self)
            let progressHandler: @Sendable (DownloadProgress) -> Void = { progress in
                Task { @MainActor in
                    weakSelf.value?.downloadProgress = progress
                }
            }

            let data = try await releaseService.download(asset: asset, progress: progressHandler)
            let expectedSHA256 = extractSHA256(from: release.body)

            try await storageManager.install(
                version: release.versionNumber,
                archiveData: data,
                expectedSHA256: expectedSHA256
            )
            try await storageManager.activate(version: release.versionNumber)

            await refresh()
        } catch {
            logger.error("Install failed: \(error.localizedDescription)")
            self.error = error.localizedDescription
        }
    }

    func activate(version: String) async {
        error = nil
        do {
            try await storageManager.activate(version: version)
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func delete(version: String) async {
        error = nil
        do {
            try await storageManager.delete(version: version)
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func cleanupOldVersions(keepLatest: Int) async {
        error = nil
        do {
            try await storageManager.cleanupOldVersions(keepLatest: keepLatest)
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func extractSHA256(from text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }

        let pattern = #"(?i)sha256:\s*([a-f0-9]{64})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges >= 2,
              let shaRange = Range(match.range(at: 1), in: text) else {
            return nil
        }

        return String(text[shaRange])
    }

    private final class WeakBox<T: AnyObject>: @unchecked Sendable {
        weak var value: T?

        init(_ value: T) {
            self.value = value
        }
    }
}
