import Darwin
import Foundation

actor CoreProcess {
    static let shared = CoreProcess()

    private var process: Process?
    private var pid: Int32?
    private var lastExitCode: Int32?
    private var logFileHandle: FileHandle?

    func start(executableURL: URL, arguments: [String], workingDirectory: URL? = nil, logFileURL: URL? = nil) throws -> Int32 {
        if let pid, process?.isRunning == true {
            return pid
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        closeLogFileHandle()
        if let logFileURL {
            process.standardOutput = try openLogFileHandle(at: logFileURL)
            process.standardError = process.standardOutput
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        process.environment = environment

        do {
            try process.run()
        } catch {
            throw FluxError(
                code: .coreStartFailed,
                message: "Failed to start core process",
                details: "\(executableURL.path) \(arguments.joined(separator: " ")) - \(error)"
            )
        }

        self.process = process
        let pid = process.processIdentifier
        self.pid = pid
        self.lastExitCode = nil

        monitorExit(pid: pid)
        return pid
    }

    func stop(gracePeriod: TimeInterval = 2) async {
        guard let pid, let process else {
            return
        }

        if !process.isRunning {
            handleExit(pid: pid, exitCode: process.terminationStatus)
            return
        }

        process.terminate()

        let deadline = Date().addingTimeInterval(gracePeriod)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        if process.isRunning {
            kill(pid, SIGKILL)
        }
    }

    func isRunning() -> Bool {
        process?.isRunning == true
    }

    func currentPID() -> Int32? {
        pid
    }

    func lastTerminationExitCode() -> Int32? {
        lastExitCode
    }

    private func monitorExit(pid: Int32) {
        let actor = self
        Task.detached(priority: .background) { [actor] in
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
            let exitCode = actor.extractExitCode(status: status)
            await actor.handleExit(pid: pid, exitCode: exitCode)
        }
    }

    private func handleExit(pid: Int32, exitCode: Int32) {
        guard self.pid == pid else {
            return
        }
        lastExitCode = exitCode
        process = nil
        self.pid = nil
        closeLogFileHandle()
    }

    private nonisolated func extractExitCode(status: Int32) -> Int32 {
        let wstatus = status & 0x7f
        if wstatus == 0 {
            return (status >> 8) & 0xff
        }
        if wstatus == 0x7f {
            return status
        }
        return -wstatus
    }

    private func openLogFileHandle(at url: URL) throws -> FileHandle {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        if fd == -1 {
            throw FluxError(code: .fileMissing, message: "Failed to open core log file", details: "\(url.path)")
        }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        logFileHandle = handle
        return handle
    }

    private func closeLogFileHandle() {
        guard let handle = logFileHandle else { return }
        try? handle.close()
        logFileHandle = nil
    }
}
