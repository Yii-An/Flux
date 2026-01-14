import Foundation

actor CoreExtractor {
    static let shared = CoreExtractor()

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Extracts a `.tar.gz` archive to a temp directory, validates its contents, locates the core executable,
    /// and installs it into `versions/<version>/CLIProxyAPI` with mode 0755.
    func extractAndInstall(from archiveURL: URL, version: String) async throws -> URL {
        try await CoreStorage.shared.ensureDirectories()

        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("flux-core-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? fileManager.removeItem(at: tempDir)
        }

        try untarGz(archiveURL, to: tempDir)
        try validateExtractedFiles(in: tempDir)

        let executable = try findExecutable(in: tempDir)

        let destinationDir = CoreSystemPaths.versionDirURL(version: version)
        try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        let destinationBinary = CoreSystemPaths.executableURL(version: version, binaryName: "CLIProxyAPI")

        if fileManager.fileExists(atPath: destinationBinary.path) {
            try fileManager.removeItem(at: destinationBinary)
        }

        do {
            try fileManager.copyItem(at: executable, to: destinationBinary)
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: destinationBinary.path)
        } catch {
            throw CoreError(code: .fileWriteFailed, message: "Failed to install extracted core binary", details: "\(destinationBinary.path) - \(error)")
        }

        return destinationBinary
    }

    // MARK: - Extract

    private func untarGz(_ archiveURL: URL, to directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archiveURL.path, "-C", directory.path, "--no-same-owner", "--no-same-permissions"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw CoreError(code: .invalidArchive, message: "Failed to start tar", details: String(describing: error))
        }

        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw CoreError(code: .invalidArchive, message: "tar extraction failed", details: output.isEmpty ? "exit=\(process.terminationStatus)" : output)
        }
    }

    // MARK: - Safety validation

    func validateExtractedFiles(in directory: URL) throws {
        let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let directoryPath = directory.standardizedFileURL.path

        while let fileURL = enumerator?.nextObject() as? URL {
            let standardizedPath = fileURL.standardizedFileURL.path
            guard standardizedPath.hasPrefix(directoryPath) else {
                throw CoreError(code: .pathTraversalDetected, message: "Archive contains path traversal", details: fileURL.path)
            }

            let values = try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                let destination = try fileManager.destinationOfSymbolicLink(atPath: fileURL.path)
                let resolvedURL = URL(fileURLWithPath: destination, relativeTo: fileURL.deletingLastPathComponent())
                let resolvedPath = resolvedURL.standardizedFileURL.path
                if !resolvedPath.hasPrefix(directoryPath) {
                    throw CoreError(code: .symlinkEscapeDetected, message: "Archive contains symlink escape", details: fileURL.path)
                }
            }
        }
    }

    // MARK: - Executable discovery

    func findExecutable(in directory: URL) throws -> URL {
        // Prefer well-known names.
        if let url = try findByName(in: directory, names: ["CLIProxyAPI", "cli-proxy-api-plus"]) {
            return url
        }

        // Fallback to the largest Mach-O file.
        let machos = try findMachOFiles(in: directory)
        if let largest = machos.max(by: { $0.size < $1.size })?.url {
            return largest
        }

        throw CoreError(code: .binaryNotFoundInArchive, message: "Core executable not found in extracted archive", details: directory.path)
    }

    private func findByName(in directory: URL, names: [String]) throws -> URL? {
        let lowerNames = Set(names.map { $0.lowercased() })

        let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            if lowerNames.contains(url.lastPathComponent.lowercased()) {
                return url
            }
        }

        return nil
    }

    private func findMachOFiles(in directory: URL) throws -> [(url: URL, size: Int64)] {
        var results: [(URL, Int64)] = []

        let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            guard let size = values.fileSize.map(Int64.init) else { continue }

            if try isMachOFile(url) {
                results.append((url, size))
            }
        }

        return results
    }

    private func isMachOFile(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let data = try handle.read(upToCount: 4) ?? Data()
        guard data.count == 4 else { return false }

        let magic = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return CoreSystemBinaryInspector.isMachOMagic(magic)
    }
}
