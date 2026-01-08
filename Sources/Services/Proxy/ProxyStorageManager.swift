import Foundation
import os.log

enum ProxyStorageError: Error, LocalizedError {
    case invalidVersion(String)
    case checksumMismatch(expected: String, actual: String)
    case unsupportedArchiveFormat
    case unsafeArchiveEntry(String)
    case symlinkEntryFound(String)
    case commandFailed(tool: String, exitCode: Int32, stderr: String)
    case binaryNotFound
    case ambiguousBinary([String])
    case versionNotInstalled(String)
    case cannotDeleteCurrent(String)

    var errorDescription: String? {
        switch self {
        case .invalidVersion(let value):
            return "无效版本号: \(value)"
        case .checksumMismatch(let expected, let actual):
            return "SHA256 校验失败，期望 \(expected)，实际 \(actual)"
        case .unsupportedArchiveFormat:
            return "不支持的安装包格式"
        case .unsafeArchiveEntry(let path):
            return "安装包包含不安全路径: \(path)"
        case .symlinkEntryFound(let path):
            return "安装包包含符号链接: \(path)"
        case .commandFailed(let tool, let code, let stderr):
            return "命令执行失败: \(tool) (exit \(code)) \(stderr)"
        case .binaryNotFound:
            return "未在安装包中找到 CLIProxyAPI 可执行文件"
        case .ambiguousBinary(let candidates):
            return "发现多个可执行文件，无法确定目标: \(candidates.joined(separator: ", "))"
        case .versionNotInstalled(let version):
            return "未安装版本: \(version)"
        case .cannotDeleteCurrent(let version):
            return "无法删除当前启用版本: \(version)"
        }
    }
}

actor ProxyStorageManager {
    static let shared = ProxyStorageManager()

    private let logger = Logger(subsystem: "com.flux.app", category: "ProxyStorage")

    nonisolated var baseDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Flux/proxy", isDirectory: true)
    }

    nonisolated var currentBinaryPath: URL? {
        let url = baseDirectory.appendingPathComponent("current", isDirectory: true).appendingPathComponent("CLIProxyAPI")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    func getCurrentVersion() -> String? {
        let currentLink = baseDirectory.appendingPathComponent("current")
        guard FileManager.default.fileExists(atPath: currentLink.path) else { return nil }

        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: currentLink.path) else {
            return nil
        }

        let destinationURL: URL
        if destination.hasPrefix("/") {
            destinationURL = URL(fileURLWithPath: destination)
        } else {
            destinationURL = currentLink.deletingLastPathComponent().appendingPathComponent(destination)
        }

        let last = destinationURL.lastPathComponent
        guard last.hasPrefix("v") else { return nil }
        return String(last.dropFirst())
    }

    func listInstalledVersions() -> [ProxyVersion] {
        guard FileManager.default.fileExists(atPath: baseDirectory.path) else { return [] }

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .creationDateKey,
            .contentModificationDateKey
        ]

        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var versions: [ProxyVersion] = []
        for url in urls {
            let name = url.lastPathComponent
            guard name.hasPrefix("v"), name != "current" else { continue }

            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }

            let versionNumber = String(name.dropFirst())
            let date = values?.creationDate ?? values?.contentModificationDate
            versions.append(ProxyVersion(version: versionNumber, downloadURL: nil, sha256: nil, releaseDate: date))
        }

        return versions.sorted { lhs, rhs in
            switch (lhs.releaseDate, rhs.releaseDate) {
            case (nil, nil): return lhs.version > rhs.version
            case (nil, _?): return false
            case (_?, nil): return true
            case (let a?, let b?): return a > b
            }
        }
    }

    func install(version: String, archiveData: Data, expectedSHA256: String?) async throws {
        let normalizedVersion = try normalizeVersion(version)
        try ensureBaseDirectoryExists()

        if let expectedSHA256, !expectedSHA256.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let actual = ChecksumVerifier.computeSHA256(data: archiveData)
            guard ChecksumVerifier.verifySHA256(data: archiveData, expected: expectedSHA256) else {
                throw ProxyStorageError.checksumMismatch(expected: expectedSHA256, actual: actual)
            }
        }

        let versionDirectory = baseDirectory.appendingPathComponent("v\(normalizedVersion)", isDirectory: true)
        try FileManager.default.createDirectory(at: versionDirectory, withIntermediateDirectories: true)

        let destinationBinary = versionDirectory.appendingPathComponent("CLIProxyAPI")
        let stagingRoot = FileManager.default.temporaryDirectory.appendingPathComponent("FluxProxyInstall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        if let format = detectArchiveFormat(data: archiveData) {
            let archiveURL = stagingRoot.appendingPathComponent("archive\(format.fileExtension)")
            try archiveData.write(to: archiveURL, options: .atomic)

            try validateArchive(at: archiveURL, format: format)

            let extractRoot = stagingRoot.appendingPathComponent("extract", isDirectory: true)
            try FileManager.default.createDirectory(at: extractRoot, withIntermediateDirectories: true)
            try extractArchive(at: archiveURL, to: extractRoot, format: format)
            try assertExtractedTreeIsSafe(root: extractRoot)

            let binaryURL = try findCLIProxyAPIBinary(in: extractRoot)
            try replaceItem(at: destinationBinary, with: binaryURL)
        } else {
            try archiveData.write(to: destinationBinary, options: .atomic)
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationBinary.path)
        bestEffortAdhocSign(path: destinationBinary.path)
    }

    func activate(version: String) throws {
        let normalizedVersion = try normalizeVersion(version)
        let versionDirectory = baseDirectory.appendingPathComponent("v\(normalizedVersion)", isDirectory: true)
        guard FileManager.default.fileExists(atPath: versionDirectory.path) else {
            throw ProxyStorageError.versionNotInstalled(normalizedVersion)
        }
        try ensureBaseDirectoryExists()

        let currentLink = baseDirectory.appendingPathComponent("current")
        if FileManager.default.fileExists(atPath: currentLink.path) {
            try FileManager.default.removeItem(at: currentLink)
        }
        try FileManager.default.createSymbolicLink(at: currentLink, withDestinationURL: versionDirectory)
    }

    func delete(version: String) throws {
        let normalizedVersion = try normalizeVersion(version)
        if let current = getCurrentVersion(), current == normalizedVersion {
            throw ProxyStorageError.cannotDeleteCurrent(normalizedVersion)
        }

        let versionDirectory = baseDirectory.appendingPathComponent("v\(normalizedVersion)", isDirectory: true)
        guard FileManager.default.fileExists(atPath: versionDirectory.path) else {
            throw ProxyStorageError.versionNotInstalled(normalizedVersion)
        }
        try FileManager.default.removeItem(at: versionDirectory)
    }

    func cleanupOldVersions(keepLatest: Int) throws {
        guard keepLatest >= 0 else { return }
        let installed = listInstalledVersions()
        let current = getCurrentVersion()

        var keep = Set<String>()
        if let current { keep.insert(current) }
        for v in installed.prefix(keepLatest) {
            keep.insert(v.version)
        }

        for v in installed where !keep.contains(v.version) {
            let dir = baseDirectory.appendingPathComponent("v\(v.version)", isDirectory: true)
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Private

    private func normalizeVersion(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let droppedV = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        guard !droppedV.isEmpty else { throw ProxyStorageError.invalidVersion(value) }

        if droppedV.contains("/") || droppedV.contains("\\") || droppedV.contains("..") {
            throw ProxyStorageError.invalidVersion(value)
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard droppedV.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw ProxyStorageError.invalidVersion(value)
        }

        return droppedV
    }

    private func ensureBaseDirectoryExists() throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    private enum ArchiveFormat {
        case zip
        case tarGz

        var fileExtension: String {
            switch self {
            case .zip: return ".zip"
            case .tarGz: return ".tar.gz"
            }
        }
    }

    private func detectArchiveFormat(data: Data) -> ArchiveFormat? {
        guard data.count >= 4 else { return nil }
        let bytes = [UInt8](data.prefix(4))

        if bytes[0] == 0x50, bytes[1] == 0x4B { return .zip }
        if bytes[0] == 0x1F, bytes[1] == 0x8B { return .tarGz }
        return nil
    }

    private func validateArchive(at url: URL, format: ArchiveFormat) throws {
        switch format {
        case .zip:
            try validateZip(at: url)
        case .tarGz:
            try validateTarGz(at: url)
        }
    }

    private func validateZip(at url: URL) throws {
        let unzip = URL(fileURLWithPath: "/usr/bin/unzip")
        let zipinfo = URL(fileURLWithPath: "/usr/bin/zipinfo")

        let listTool: URL
        var listArgs: [String]
        if FileManager.default.isExecutableFile(atPath: unzip.path) {
            listTool = unzip
            listArgs = ["-Z1", url.path]
        } else if FileManager.default.isExecutableFile(atPath: zipinfo.path) {
            listTool = zipinfo
            listArgs = ["-1", url.path]
        } else {
            throw ProxyStorageError.commandFailed(tool: "unzip/zipinfo", exitCode: 127, stderr: "missing")
        }

        let listOutput = try runTool(executable: listTool, arguments: listArgs)
        let names = listOutput.split(separator: "\n").map(String.init)
        for name in names {
            try validateArchiveEntryPath(name)
        }

        guard FileManager.default.isExecutableFile(atPath: zipinfo.path) else { return }
        let verbose = try runTool(executable: zipinfo, arguments: ["-v", url.path])
        if let symlinkPath = parseFirstZipSymlink(from: verbose) {
            throw ProxyStorageError.symlinkEntryFound(symlinkPath)
        }
    }

    private func parseFirstZipSymlink(from zipinfoVerbose: String) -> String? {
        var currentName: String?
        var expectingName = false

        for rawLine in zipinfoVerbose.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("Central directory entry #") {
                currentName = nil
                expectingName = true
                continue
            }

            if expectingName {
                if line.isEmpty { continue }
                if line.allSatisfy({ $0 == "-" }) { continue }
                currentName = line
                expectingName = false
                continue
            }

            if line.hasPrefix("Unix file attributes") {
                if let attributes = line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces),
                   attributes.first == "l" {
                    return currentName
                }
            }
        }

        return nil
    }

    private func validateTarGz(at url: URL) throws {
        let tar = URL(fileURLWithPath: "/usr/bin/tar")
        let namesOutput = try runTool(executable: tar, arguments: ["-tzf", url.path])
        let names = namesOutput.split(separator: "\n").map(String.init)
        for name in names {
            try validateArchiveEntryPath(name)
        }

        let verbose = try runTool(executable: tar, arguments: ["-tvzf", url.path])
        for rawLine in verbose.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let first = line.first else { continue }

            if first == "l" { throw ProxyStorageError.symlinkEntryFound(extractTarPath(from: line) ?? "<unknown>") }
            if line.contains(" -> ") { throw ProxyStorageError.symlinkEntryFound(extractTarPath(from: line) ?? "<unknown>") }
            if line.contains(" link to ") { throw ProxyStorageError.symlinkEntryFound(extractTarPath(from: line) ?? "<unknown>") }
            if first != "-" && first != "d" {
                throw ProxyStorageError.unsafeArchiveEntry(extractTarPath(from: line) ?? "<unknown>")
            }
        }
    }

    private func extractTarPath(from verboseLine: String) -> String? {
        if let range = verboseLine.range(of: " -> ") {
            return String(verboseLine[..<range.lowerBound]).split(separator: " ").last.map(String.init)
        }
        if let range = verboseLine.range(of: " link to ") {
            return String(verboseLine[..<range.lowerBound]).split(separator: " ").last.map(String.init)
        }
        return verboseLine.split(separator: " ").last.map(String.init)
    }

    private func validateArchiveEntryPath(_ rawPath: String) throws {
        let path = rawPath.replacingOccurrences(of: "\\", with: "/")
        let trimmed = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
        guard !trimmed.hasPrefix("/") else { throw ProxyStorageError.unsafeArchiveEntry(rawPath) }

        let components = trimmed.split(separator: "/")
        if components.contains("..") { throw ProxyStorageError.unsafeArchiveEntry(rawPath) }
    }

    private func extractArchive(at archiveURL: URL, to destinationURL: URL, format: ArchiveFormat) throws {
        switch format {
        case .zip:
            let ditto = URL(fileURLWithPath: "/usr/bin/ditto")
            _ = try runTool(executable: ditto, arguments: ["-xk", archiveURL.path, destinationURL.path])
        case .tarGz:
            let tar = URL(fileURLWithPath: "/usr/bin/tar")
            _ = try runTool(executable: tar, arguments: ["-xzf", archiveURL.path, "-C", destinationURL.path])
        }
    }

    private func assertExtractedTreeIsSafe(root: URL) throws {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let rootPath = root.standardizedFileURL.path
        for case let url as URL in enumerator {
            let standardized = url.standardizedFileURL
            guard standardized.path.hasPrefix(rootPath) else {
                throw ProxyStorageError.unsafeArchiveEntry(url.path)
            }

            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                throw ProxyStorageError.symlinkEntryFound(url.path)
            }
        }
    }

    private func findCLIProxyAPIBinary(in root: URL) throws -> URL {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            throw ProxyStorageError.binaryNotFound
        }

        var preferred: URL?
        var executables: [URL] = []

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }

            if url.lastPathComponent == "CLIProxyAPI" {
                preferred = url
            }

            if FileManager.default.isExecutableFile(atPath: url.path) {
                executables.append(url)
            }
        }

        if let preferred { return preferred }
        if executables.count == 1 { return executables[0] }
        if executables.isEmpty { throw ProxyStorageError.binaryNotFound }
        throw ProxyStorageError.ambiguousBinary(executables.map(\.path))
    }

    private func replaceItem(at destinationURL: URL, with sourceURL: URL) throws {
        let fileManager = FileManager.default
        let destinationDir = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try? fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    private func bestEffortAdhocSign(path: String) {
        let codesign = URL(fileURLWithPath: "/usr/bin/codesign")
        guard FileManager.default.isExecutableFile(atPath: codesign.path) else { return }

        do {
            _ = try runTool(executable: codesign, arguments: ["--force", "--sign", "-", path])
        } catch {
            logger.warning("codesign failed: \(error.localizedDescription)")
        }
    }

    private func runTool(executable: URL, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw ProxyStorageError.commandFailed(
                tool: executable.lastPathComponent,
                exitCode: process.terminationStatus,
                stderr: stderr.isEmpty ? stdout : stderr
            )
        }

        return stdout
    }
}
