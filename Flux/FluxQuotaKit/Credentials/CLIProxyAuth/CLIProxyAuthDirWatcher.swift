import Foundation
import Darwin

final class CLIProxyAuthDirWatcher: @unchecked Sendable {
    private let directoryURL: URL
    private let logger: FluxLogger

    private var fileDescriptor: Int32 = -1
    private var source: DispatchSourceFileSystemObject?

    private var debounceTask: Task<Void, Never>?
    private let debounceNanoseconds: UInt64

    private let onChange: @Sendable () -> Void

    init(
        directoryURL: URL = FluxPaths.cliProxyAuthDir(),
        logger: FluxLogger = .shared,
        debounceNanoseconds: UInt64 = 250_000_000,
        onChange: @escaping @Sendable () -> Void
    ) {
        self.directoryURL = directoryURL
        self.logger = logger
        self.debounceNanoseconds = debounceNanoseconds
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start() {
        stop()

        let path = directoryURL.path
        fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            Task { [logger] in
                await logger.log(.warning, category: LogCategories.auth, metadata: ["dir": .string(path)], message: "CLIProxyAuthDirWatcher failed to open directory")
            }
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename, .attrib, .extend],
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            self?.scheduleDebouncedChange()
        }

        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fileDescriptor >= 0 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }

        self.source = source
        source.resume()

        Task { [logger] in
            await logger.log(.info, category: LogCategories.auth, metadata: ["dir": .string(path)], message: "CLIProxyAuthDirWatcher started")
        }
    }

    func stop() {
        debounceTask?.cancel()
        debounceTask = nil

        source?.cancel()
        source = nil

        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    private func scheduleDebouncedChange() {
        debounceTask?.cancel()
        debounceTask = Task { [debounceNanoseconds, onChange] in
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return }
            onChange()
        }
    }
}
