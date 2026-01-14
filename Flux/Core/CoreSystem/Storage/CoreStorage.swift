import Foundation

actor CoreStorage {
    static let shared = CoreStorage()

    private let fileManager: FileManager

    private let binaryName = "CLIProxyAPI"
    private let stateFileName = "state.json"
    private let currentLinkName = "current"

    private let releasesDirName = "releases"
    private let downloadsDirName = "downloads"
    private let versionsDirName = "versions"
    private let locksDirName = "locks"
    private let logsDirName = "logs"

    private let metadataFileName = "metadata.json"

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func ensureDirectories() throws {
        try FluxPaths.ensureConfigDirExists()

        try fileManager.createDirectory(at: CoreSystemPaths.coreRootDirURL(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: releasesDirURL(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: downloadsDirURL(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: versionsDirURL(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: locksDirURL(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: logsDirURL(), withIntermediateDirectories: true)
    }

    func coreRootDirURL() -> URL {
        CoreSystemPaths.coreRootDirURL()
    }

    func releasesDirURL() -> URL {
        coreRootDirURL().appendingPathComponent(releasesDirName, isDirectory: true)
    }

    func downloadsDirURL() -> URL {
        coreRootDirURL().appendingPathComponent(downloadsDirName, isDirectory: true)
    }

    func versionsDirURL() -> URL {
        coreRootDirURL().appendingPathComponent(versionsDirName, isDirectory: true)
    }

    func locksDirURL() -> URL {
        coreRootDirURL().appendingPathComponent(locksDirName, isDirectory: true)
    }

    func logsDirURL() -> URL {
        coreRootDirURL().appendingPathComponent(logsDirName, isDirectory: true)
    }

    func stateFileURL() -> URL {
        CoreSystemPaths.stateFileURL()
    }

    func currentSymlinkURL() -> URL {
        CoreSystemPaths.currentSymlinkURL()
    }

    func versionDirURL(version: String) -> URL {
        CoreSystemPaths.versionDirURL(version: version)
    }

    func executableURL(version: String) -> URL {
        CoreSystemPaths.executableURL(version: version, binaryName: binaryName)
    }

    func metadataURL(version: String) -> URL {
        CoreSystemPaths.metadataURL(version: version, metadataFileName: metadataFileName)
    }

    func currentVersion() throws -> String? {
        try ensureDirectories()

        let linkURL = currentSymlinkURL()
        guard fileManager.fileExists(atPath: linkURL.path) else {
            return nil
        }

        do {
            let destination = try fileManager.destinationOfSymbolicLink(atPath: linkURL.path)
            let resolved = URL(fileURLWithPath: destination, relativeTo: linkURL.deletingLastPathComponent()).standardizedFileURL
            return resolved.lastPathComponent
        } catch {
            return nil
        }
    }

    func currentExecutableURL() throws -> URL? {
        try ensureDirectories()

        guard let version = try currentVersion() else { return nil }
        let url = executableURL(version: version)
        return fileManager.isExecutableFile(atPath: url.path) ? url : nil
    }

    func setCurrent(_ version: String) throws {
        try ensureDirectories()

        let dir = versionDirURL(version: version)
        let binary = executableURL(version: version)
        guard fileManager.fileExists(atPath: dir.path) else {
            throw CoreError(code: .fileMissing, message: "Core version not installed", details: "version=\(version)")
        }
        guard fileManager.isExecutableFile(atPath: binary.path) else {
            throw CoreError(code: .fileMissing, message: "Core binary not found", details: "path=\(binary.path)")
        }

        let linkURL = currentSymlinkURL()
        if fileManager.fileExists(atPath: linkURL.path) {
            try fileManager.removeItem(at: linkURL)
        }

        try fileManager.createSymbolicLink(at: linkURL, withDestinationURL: dir)
    }

    func remove(version: String) throws {
        try ensureDirectories()

        if let current = try currentVersion(), current == version {
            throw CoreError(code: .cannotDeleteCurrentVersion, message: "Cannot delete current core version", details: "version=\(version)")
        }

        let dir = versionDirURL(version: version)
        if fileManager.fileExists(atPath: dir.path) {
            try fileManager.removeItem(at: dir)
        }
    }

    func listInstalled() throws -> [InstalledCoreVersion] {
        try ensureDirectories()

        let current = try currentVersion()

        let dirs: [URL]
        do {
            dirs = try fileManager.contentsOfDirectory(
                at: versionsDirURL(),
                includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw CoreError(code: .fileMissing, message: "Failed to read versions directory", details: "\(versionsDirURL().path) - \(error)")
        }

        var results: [InstalledCoreVersion] = []
        for dir in dirs {
            guard isDirectory(dir) else { continue }

            let version = dir.lastPathComponent
            let executable = executableURL(version: version)
            guard fileManager.isExecutableFile(atPath: executable.path) else { continue }

            let metadataURL = metadataURL(version: version)
            let (installedAt, sha256, arch) = readMetadataOrFallback(versionDir: dir, metadataURL: metadataURL)

            results.append(
                InstalledCoreVersion(
                    version: version,
                    installedAt: installedAt,
                    executableURL: executable,
                    sha256: sha256,
                    arch: arch,
                    isCurrent: version == current
                )
            )
        }

        return results.sorted { $0.installedAt > $1.installedAt }
    }

    func prune(keep maxCount: Int = 2) throws {
        try ensureDirectories()

        let keepCount = max(1, maxCount)
        let current = try currentVersion()
        let installed = try listInstalled()

        guard installed.count > keepCount else { return }

        var keepVersions: [InstalledCoreVersion] = []
        if let current, let currentInstalled = installed.first(where: { $0.version == current }) {
            keepVersions.append(currentInstalled)
        }

        for item in installed where keepVersions.count < keepCount {
            if keepVersions.contains(where: { $0.version == item.version }) { continue }
            keepVersions.append(item)
        }

        let keepSet = Set(keepVersions.map(\.version))
        for item in installed where !keepSet.contains(item.version) {
            try? remove(version: item.version)
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }

    private func readMetadataOrFallback(versionDir: URL, metadataURL: URL) -> (installedAt: Date, sha256: String?, arch: HostArch?) {
        if fileManager.fileExists(atPath: metadataURL.path),
           let data = try? Data(contentsOf: metadataURL),
           let metadata = try? CoreJSON.decoder.decode(CoreVersionMetadata.self, from: data) {
            return (metadata.installedAt, metadata.binary.sha256, metadata.binary.arch)
        }

        let installedAt = (try? fileManager.attributesOfItem(atPath: versionDir.path)[.creationDate] as? Date) ?? Date()
        return (installedAt, nil, nil)
    }
}

enum CoreJSON {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) {
                return date
            }

            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: value) {
                return date
            }

            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(value)")
        }
        return decoder
    }
}

enum CoreSystemPaths {
    static func coreRootDirURL() -> URL {
        FluxPaths.coreDir()
    }

    static func releasesDirURL() -> URL {
        coreRootDirURL().appendingPathComponent("releases", isDirectory: true)
    }

    static func downloadsDirURL() -> URL {
        coreRootDirURL().appendingPathComponent("downloads", isDirectory: true)
    }

    static func versionsDirURL() -> URL {
        coreRootDirURL().appendingPathComponent("versions", isDirectory: true)
    }

    static func locksDirURL() -> URL {
        coreRootDirURL().appendingPathComponent("locks", isDirectory: true)
    }

    static func logsDirURL() -> URL {
        coreRootDirURL().appendingPathComponent("logs", isDirectory: true)
    }

    static func stateFileURL() -> URL {
        coreRootDirURL().appendingPathComponent("state.json", isDirectory: false)
    }

    static func currentSymlinkURL() -> URL {
        coreRootDirURL().appendingPathComponent("current", isDirectory: false)
    }

    static func versionDirURL(version: String) -> URL {
        versionsDirURL().appendingPathComponent(version, isDirectory: true)
    }

    static func executableURL(version: String, binaryName: String) -> URL {
        versionDirURL(version: version).appendingPathComponent(binaryName, isDirectory: false)
    }

    static func metadataURL(version: String, metadataFileName: String) -> URL {
        versionDirURL(version: version).appendingPathComponent(metadataFileName, isDirectory: false)
    }
}
