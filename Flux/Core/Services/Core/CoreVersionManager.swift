import CryptoKit
import Foundation

actor CoreVersionManager {
    static let shared = CoreVersionManager()

    private let fileManager: FileManager

    private let binaryName = "CLIProxyAPI"
    private let versionsDirName = "versions"
    private let activeFileName = "active.json"
    private let metadataFileName = "metadata.json"

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func ensureDirectories() throws {
        try FluxPaths.ensureConfigDirExists()
        try fileManager.createDirectory(at: versionsDirURL(), withIntermediateDirectories: true)
    }

    func listInstalledVersions() throws -> [CoreVersion] {
        try ensureDirectories()

        let activeVersion = try readActiveVersion()
        let versionsDir = versionsDirURL()

        let versionDirs: [URL]
        do {
            versionDirs = try fileManager.contentsOfDirectory(
                at: versionsDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw FluxError(code: .fileMissing, message: "Failed to read core versions directory", details: "\(versionsDir.path) - \(error)")
        }

        var versions: [CoreVersion] = []
        for dir in versionDirs {
            guard isDirectory(dir) else { continue }
            guard let version = try readCoreVersion(from: dir, activeVersion: activeVersion) else { continue }
            versions.append(version)
        }

        return versions.sorted { $0.installedAt > $1.installedAt }
    }

    func activeVersion() throws -> CoreVersion? {
        let active = try readActiveVersion()
        return try listInstalledVersions().first(where: { $0.version == active })
    }

    func activeBinaryURL() throws -> URL? {
        try ensureDirectories()

        if let active = try activeVersion() {
            let binaryURL = active.path
            if fileManager.isExecutableFile(atPath: binaryURL.path) {
                return binaryURL
            }
        }

        let legacyBinary = FluxPaths.coreDir().appendingPathComponent(binaryName, isDirectory: false)
        if fileManager.isExecutableFile(atPath: legacyBinary.path) {
            return legacyBinary
        }

        return nil
    }

    func setActiveVersion(_ version: String) throws {
        try ensureDirectories()

        let dir = versionDirURL(version: version)
        guard fileManager.fileExists(atPath: dir.path) else {
            throw FluxError(code: .fileMissing, message: "Core version not installed", details: "version=\(version)")
        }

        let activeFile = ActiveVersionFile(version: version)
        let data = try encoder.encode(activeFile)
        try data.write(to: activeFileURL(), options: [.atomic])
    }

    func installVersion(from sourceBinary: URL, version: String, setActive: Bool = false) throws -> CoreVersion {
        try ensureDirectories()

        let destinationDir = versionDirURL(version: version)
        try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        let destinationBinary = destinationDir.appendingPathComponent(binaryName, isDirectory: false)

        do {
            if fileManager.fileExists(atPath: destinationBinary.path) {
                try fileManager.removeItem(at: destinationBinary)
            }
            try fileManager.copyItem(at: sourceBinary, to: destinationBinary)
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: destinationBinary.path)
        } catch {
            throw FluxError(
                code: .unknown,
                message: "Failed to install core binary",
                details: "\(sourceBinary.path) -> \(destinationBinary.path) - \(error)"
            )
        }

        let sha256 = try sha256Hex(of: destinationBinary)
        let installedAt = Date()

        let metadata = CoreVersionMetadata(version: version, installedAt: installedAt, sha256: sha256)
        let metadataData = try encoder.encode(metadata)
        try metadataData.write(to: metadataURL(in: destinationDir), options: [.atomic])

        if setActive {
            try self.setActiveVersion(version)
        }

        return CoreVersion(
            version: version,
            installedAt: installedAt,
            path: destinationBinary,
            sha256: sha256,
            isActive: setActive
        )
    }

    func pruneVersions(keeping maxCount: Int = 2) throws {
        try ensureDirectories()

        let keepCount = max(1, maxCount)
        let active = try readActiveVersion()
        let all = try listInstalledVersions()

        guard all.count > keepCount else { return }

        let activeVersion = all.first(where: { $0.version == active })
        var keep: [CoreVersion] = []

        if let activeVersion {
            keep.append(activeVersion)
        }

        for version in all where keep.count < keepCount {
            if keep.contains(where: { $0.version == version.version }) {
                continue
            }
            keep.append(version)
        }

        let keepSet = Set(keep.map { $0.version })
        let versionsDir = versionsDirURL()
        for version in all where !keepSet.contains(version.version) {
            let dir = versionsDir.appendingPathComponent(version.version, isDirectory: true)
            try? fileManager.removeItem(at: dir)
        }
    }

    private struct ActiveVersionFile: Codable, Sendable {
        var version: String
    }

    private struct CoreVersionMetadata: Codable, Sendable {
        var version: String
        var installedAt: Date
        var sha256: String
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private var decoder: JSONDecoder { JSONDecoder() }

    private func versionsDirURL() -> URL {
        FluxPaths.coreDir().appendingPathComponent(versionsDirName, isDirectory: true)
    }

    private func versionDirURL(version: String) -> URL {
        versionsDirURL().appendingPathComponent(version, isDirectory: true)
    }

    private func activeFileURL() -> URL {
        FluxPaths.coreDir().appendingPathComponent(activeFileName, isDirectory: false)
    }

    private func metadataURL(in versionDir: URL) -> URL {
        versionDir.appendingPathComponent(metadataFileName, isDirectory: false)
    }

    private func readActiveVersion() throws -> String? {
        let url = activeFileURL()
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let file = try decoder.decode(ActiveVersionFile.self, from: data)
            return file.version
        } catch {
            throw FluxError(code: .parseError, message: "Failed to parse active core version file", details: "\(url.path) - \(error)")
        }
    }

    private func readCoreVersion(from versionDir: URL, activeVersion: String?) throws -> CoreVersion? {
        let metadataURL = metadataURL(in: versionDir)
        let binaryURL = versionDir.appendingPathComponent(binaryName, isDirectory: false)

        guard fileManager.fileExists(atPath: binaryURL.path) else { return nil }

        let metadata: CoreVersionMetadata?
        if fileManager.fileExists(atPath: metadataURL.path) {
            do {
                let data = try Data(contentsOf: metadataURL)
                metadata = try decoder.decode(CoreVersionMetadata.self, from: data)
            } catch {
                throw FluxError(code: .parseError, message: "Failed to parse core version metadata", details: "\(metadataURL.path) - \(error)")
            }
        } else {
            let sha256 = (try? sha256Hex(of: binaryURL)) ?? "unknown"
            let installedAt = modificationDate(binaryURL) ?? Date()
            metadata = CoreVersionMetadata(version: versionDir.lastPathComponent, installedAt: installedAt, sha256: sha256)
        }

        guard let metadata else { return nil }

        return CoreVersion(
            version: metadata.version,
            installedAt: metadata.installedAt,
            path: binaryURL,
            sha256: metadata.sha256,
            isActive: metadata.version == activeVersion
        )
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
    }

    private func sha256Hex(of fileURL: URL) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw FluxError(code: .fileMissing, message: "Failed to read file for SHA256", details: "\(fileURL.path) - \(error)")
        }

        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

