import Foundation

/// CoreSystem downloader (distinct from legacy `CoreDownloader` in old Core services).
actor CoreSystemDownloader {
    static let shared = CoreSystemDownloader()

    typealias ProgressHandler = @MainActor @Sendable (_ bytesReceived: Int64, _ totalBytes: Int64) -> Void

    private let session: URLSession
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5 * 60
        config.timeoutIntervalForResource = 5 * 60
        self.session = URLSession(configuration: config)
    }

    func download(
        asset: CoreAsset,
        progress: ProgressHandler? = nil
    ) async throws -> URL {
        try ensureDownloadsDirectory()

        var request = URLRequest(url: asset.browserDownloadURL)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Flux", forHTTPHeaderField: "User-Agent")

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CoreError(code: .downloadFailed, message: "Invalid HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw CoreError(code: .downloadFailed, message: "Download failed", details: "HTTP \(http.statusCode) \(asset.browserDownloadURL.absoluteString)")
        }

        let downloadsDir = CoreSystemPaths.downloadsDirURL()
        let tempName = "\(UUID().uuidString)-\(asset.name)"
        let tempURL = downloadsDir.appendingPathComponent(tempName, isDirectory: false)
        let finalURL = downloadsDir.appendingPathComponent(asset.name, isDirectory: false)

        if fileManager.fileExists(atPath: tempURL.path) {
            try? fileManager.removeItem(at: tempURL)
        }
        fileManager.createFile(atPath: tempURL.path, contents: nil)

        let expectedBytes: Int64 = {
            if response.expectedContentLength > 0 { return response.expectedContentLength }
            if asset.size > 0 { return Int64(asset.size) }
            return -1
        }()

        let handle = try FileHandle(forWritingTo: tempURL)
        defer { try? handle.close() }

        var received: Int64 = 0
        var buffer: [UInt8] = []
        buffer.reserveCapacity(64 * 1024)

        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count == 64 * 1024 {
                    try handle.write(contentsOf: Data(buffer))
                    received += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    if let progress {
                        await progress(received, expectedBytes)
                    }
                }
            }

            if !buffer.isEmpty {
                try handle.write(contentsOf: Data(buffer))
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
            }

            if let progress {
                await progress(received, expectedBytes)
            }
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw CoreError(code: .downloadFailed, message: "Download failed", details: String(describing: error))
        }

        do {
            if fileManager.fileExists(atPath: finalURL.path) {
                try fileManager.removeItem(at: finalURL)
            }
            try fileManager.moveItem(at: tempURL, to: finalURL)
            return finalURL
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw CoreError(code: .downloadFailed, message: "Failed to move downloaded file", details: "\(tempURL.path) -> \(finalURL.path) - \(error)")
        }
    }

    private func ensureDownloadsDirectory() throws {
        try FluxPaths.ensureConfigDirExists()
        try fileManager.createDirectory(at: CoreSystemPaths.coreRootDirURL(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: CoreSystemPaths.downloadsDirURL(), withIntermediateDirectories: true)
    }
}

