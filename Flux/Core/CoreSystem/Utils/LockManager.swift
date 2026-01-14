import Foundation
import Darwin

enum CoreLockName: String, Sendable, CaseIterable {
    case install
    case upgrade

    var fileURL: URL {
        CoreSystemPaths.locksDirURL().appendingPathComponent("\(rawValue).lock", isDirectory: false)
    }
}

actor LockManager {
    static let shared = LockManager()

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func tryLock(_ name: CoreLockName) throws -> LockedFileLock? {
        try ensureLockDirectory()

        let fd = open(name.fileURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw CoreError(code: .permissionDenied, message: "Failed to open lock file", details: "\(name.fileURL.path) errno=\(errno)")
        }

        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            return LockedFileLock(fileDescriptor: fd, fileURL: name.fileURL)
        }

        let err = errno
        close(fd)

        if err == EWOULDBLOCK {
            return nil
        }

        throw CoreError(code: .fileWriteFailed, message: "Failed to acquire lock", details: "\(name.fileURL.path) errno=\(err)")
    }

    func lock(_ name: CoreLockName, pollIntervalMilliseconds: UInt64 = 100) async throws -> LockedFileLock {
        while true {
            try Task.checkCancellation()

            if let locked = try tryLock(name) {
                return locked
            }

            try await Task.sleep(nanoseconds: pollIntervalMilliseconds * 1_000_000)
        }
    }

    private func ensureLockDirectory() throws {
        try FluxPaths.ensureConfigDirExists()
        try fileManager.createDirectory(at: CoreSystemPaths.coreRootDirURL(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: CoreSystemPaths.locksDirURL(), withIntermediateDirectories: true)
    }
}

final actor LockedFileLock: Sendable {
    private var fileDescriptor: Int32?
    private let fileURL: URL

    init(fileDescriptor: Int32, fileURL: URL) {
        self.fileDescriptor = fileDescriptor
        self.fileURL = fileURL
    }

    deinit {
        if let fd = fileDescriptor {
            _ = flock(fd, LOCK_UN)
            close(fd)
        }
        fileDescriptor = nil
    }

    func unlock() {
        guard let fd = fileDescriptor else { return }
        _ = flock(fd, LOCK_UN)
        close(fd)
        fileDescriptor = nil
    }

    func path() -> String { fileURL.path }
}

