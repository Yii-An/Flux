import Foundation

actor CoreStateStore {
    static let shared = CoreStateStore()

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func read() throws -> CoreState {
        try ensureCoreRootDirExists()
        let url = CoreSystemPaths.stateFileURL()
        guard fileManager.fileExists(atPath: url.path) else {
            return CoreState()
        }

        do {
            let data = try Data(contentsOf: url)
            return try CoreJSON.decoder.decode(CoreState.self, from: data)
        } catch {
            throw CoreError(code: .parseError, message: "Failed to parse core state file", details: "\(url.path) - \(error)")
        }
    }

    func write(_ state: CoreState) throws {
        try ensureCoreRootDirExists()
        let url = CoreSystemPaths.stateFileURL()
        do {
            let data = try CoreJSON.encoder.encode(state)
            try data.write(to: url, options: [.atomic])
        } catch {
            throw CoreError(code: .fileWriteFailed, message: "Failed to write core state file", details: "\(url.path) - \(error)")
        }
    }

    func update(_ mutate: (inout CoreState) -> Void) throws {
        var state = try read()
        mutate(&state)
        try write(state)
    }

    private func ensureCoreRootDirExists() throws {
        try FluxPaths.ensureConfigDirExists()
        try fileManager.createDirectory(at: CoreSystemPaths.coreRootDirURL(), withIntermediateDirectories: true)
    }
}
