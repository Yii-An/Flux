import Foundation
import Darwin

actor CoreRunner {
    static let shared = CoreRunner()

    private let fileManager: FileManager

    private var running: RunningProcess?

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func start(executable: URL, configURL: URL, port: UInt16) async throws -> Int32 {
        if let running {
            return running.pid
        }

        if !isPortAvailable(port: port) {
            if let listener = try queryListeningProcess(port: port) {
                let reclaimed = await terminateIfStaleFluxCore(listener: listener, port: port)
                if !reclaimed {
                    throw CoreError(
                        code: .portInUse,
                        message: "Port already in use",
                        details: "port=\(port) pid=\(listener.pid) command=\(listener.commandName ?? "?") cmdline=\(listener.commandLine ?? "?")"
                    )
                }
            }
        }

        guard isPortAvailable(port: port) else {
            throw CoreError(code: .portInUse, message: "Port already in use", details: "port=\(port)")
        }

        let logURL = try ensureLogFile()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-config", configURL.path]
        process.currentDirectoryURL = executable.deletingLastPathComponent()

        let logHandle = try FileHandle(forWritingTo: logURL)
        try logHandle.seekToEnd()
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            try process.run()
        } catch {
            try? logHandle.close()
            throw CoreError(code: .coreStartFailed, message: "Failed to start core process", details: String(describing: error))
        }

        let pid = process.processIdentifier
        self.running = RunningProcess(process: process, pid: pid, port: port, isDryRun: false, logHandle: logHandle, logURL: logURL)

        try await waitForRunning(process, timeoutSeconds: 2)

        return pid
    }

    func startDryRun(executable: URL, configURL: URL) async throws -> (pid: Int32, port: UInt16) {
        let port = try allocateEphemeralPort()
        let tempConfigURL = try createDryRunConfig(from: configURL, overridingPort: port)
        let pid = try await startDryRun(executable: executable, configURL: tempConfigURL, port: port)
        // persist temp config for cleanup
        if var running = self.running {
            running.temporaryConfigURL = tempConfigURL
            self.running = running
        }
        return (pid, port)
    }

    func startDryRun(executable: URL, configURL: URL, port: UInt16) async throws -> Int32 {
        if let running {
            return running.pid
        }

        guard isPortAvailable(port: port) else {
            throw CoreError(code: .portInUse, message: "Dry-run port already in use", details: "port=\(port)")
        }

        let logURL = try ensureLogFile()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-config", configURL.path]
        process.currentDirectoryURL = executable.deletingLastPathComponent()

        let logHandle = try FileHandle(forWritingTo: logURL)
        try logHandle.seekToEnd()
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            try process.run()
        } catch {
            try? logHandle.close()
            throw CoreError(code: .coreStartFailed, message: "Failed to start dry-run core process", details: String(describing: error))
        }

        let pid = process.processIdentifier
        self.running = RunningProcess(process: process, pid: pid, port: port, isDryRun: true, logHandle: logHandle, logURL: logURL)

        try await waitForRunning(process, timeoutSeconds: 2)

        return pid
    }

    func stop() async {
        guard let running else { return }
        self.running = nil

        let process = running.process
        let pid = running.pid
        let logHandle = running.logHandle
        let tempConfigURL = running.temporaryConfigURL

        if process.isRunning {
            process.terminate()

            let deadline = Date().addingTimeInterval(2.0)
            while process.isRunning && Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }

            if process.isRunning {
                kill(pid, SIGKILL)
            }
        }

        try? logHandle.close()
        if let tempConfigURL {
            try? fileManager.removeItem(at: tempConfigURL)
        }
    }

    func currentPID() -> Int32? { running?.pid }
    func currentPort() -> UInt16? { running?.port }
    func isDryRun() -> Bool { running?.isDryRun ?? false }
    func logFileURL() -> URL? { running?.logURL }

    // MARK: - Private

    private struct RunningProcess: Sendable {
        let process: Process
        let pid: Int32
        let port: UInt16
        let isDryRun: Bool
        let logHandle: FileHandle
        let logURL: URL
        var temporaryConfigURL: URL? = nil
    }

    private func ensureLogFile() throws -> URL {
        try FluxPaths.ensureConfigDirExists()
        try fileManager.createDirectory(at: CoreSystemPaths.coreRootDirURL(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: CoreSystemPaths.logsDirURL(), withIntermediateDirectories: true)

        let url = CoreSystemPaths.logsDirURL().appendingPathComponent("core.log", isDirectory: false)
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        return url
    }

    private func waitForRunning(_ process: Process, timeoutSeconds: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if process.isRunning {
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        throw CoreError(code: .coreStartTimeout, message: "Core process start timed out")
    }

    private func isPortAvailable(port: UInt16) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bindResult == 0
    }

    private struct ListeningProcessInfo: Sendable {
        var pid: Int32
        var commandName: String?
        var commandLine: String?
    }

    private func queryListeningProcess(port: UInt16) throws -> ListeningProcessInfo? {
        let lsofPath = "/usr/sbin/lsof"
        let args = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpctn"]
        let (code, stdout, _) = try runProcess(executable: lsofPath, arguments: args)
        guard code == 0 else { return nil }

        var pid: Int32?
        var command: String?
        for raw in stdout.split(whereSeparator: \.isNewline) {
            guard let first = raw.first else { continue }
            let value = raw.dropFirst()
            switch first {
            case "p":
                pid = Int32(value) ?? pid
            case "c":
                command = String(value)
            default:
                break
            }
        }

        guard let pid else { return nil }

        let cmdline = try? queryCommandLine(pid: pid)
        return ListeningProcessInfo(pid: pid, commandName: command, commandLine: cmdline)
    }

    private func queryCommandLine(pid: Int32) throws -> String? {
        let psPath = "/bin/ps"
        let (code, stdout, _) = try runProcess(executable: psPath, arguments: ["-p", "\(pid)", "-o", "command="])
        guard code == 0 else { return nil }
        let value = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func terminateIfStaleFluxCore(listener: ListeningProcessInfo, port: UInt16) async -> Bool {
        let commandLine = listener.commandLine ?? ""
        let commandName = listener.commandName ?? ""

        // Only attempt to kill Flux-managed core processes.
        let coreRoot = FluxPaths.coreDir().standardizedFileURL.path
        let isFluxCore = commandLine.contains(coreRoot) && commandName.contains("CLIProxyAPI")
        guard isFluxCore else { return false }

        // Try SIGTERM first, then SIGKILL if still alive.
        _ = kill(listener.pid, SIGTERM)

        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if isPortAvailable(port: port) { return true }
            if !isPIDAlive(listener.pid) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        _ = kill(listener.pid, SIGKILL)

        let killDeadline = Date().addingTimeInterval(1.0)
        while Date() < killDeadline {
            if isPortAvailable(port: port) { return true }
            if !isPIDAlive(listener.pid) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        return isPortAvailable(port: port)
    }

    private func isPIDAlive(_ pid: Int32) -> Bool {
        let result = kill(pid, 0)
        if result == 0 { return true }
        return errno != ESRCH
    }

    private func runProcess(executable: String, arguments: [String]) throws -> (Int32, String, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
        } catch {
            throw CoreError(code: .coreStartFailed, message: "Failed to run helper process", details: "\(executable) \(arguments.joined(separator: " ")) - \(error)")
        }

        process.waitUntilExit()

        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }

    private func allocateEphemeralPort() throws -> UInt16 {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw CoreError(code: .coreStartFailed, message: "Failed to allocate socket for port selection", details: "errno=\(errno)")
        }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw CoreError(code: .coreStartFailed, message: "Failed to bind ephemeral port", details: "errno=\(errno)")
        }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        var out = sockaddr_in()
        let getResult = withUnsafeMutablePointer(to: &out) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(sock, $0, &length)
            }
        }
        guard getResult == 0 else {
            throw CoreError(code: .coreStartFailed, message: "Failed to get allocated port", details: "errno=\(errno)")
        }

        return UInt16(bigEndian: out.sin_port)
    }

    private func createDryRunConfig(from configURL: URL, overridingPort port: UInt16) throws -> URL {
        let baseText: String
        if fileManager.fileExists(atPath: configURL.path),
           let text = try? String(contentsOf: configURL, encoding: .utf8) {
            baseText = text
        } else {
            // Minimal fallback config (keeps in sync with existing Flux default config format).
            let authDir = FluxPaths.tildePath(for: FluxPaths.cliProxyAuthDir())
            baseText = """
            host: \"127.0.0.1\"
            port: 8080
            auth-dir: \"\(authDir)\"
            proxy-url: \"\"

            api-keys:
              - \"flux-dryrun\"

            remote-management:
              allow-remote: false
            """
        }

        var lines = baseText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var replaced = false
        for i in 0..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("port:") {
                let indent = lines[i].prefix { $0 == " " || $0 == "\t" }
                lines[i] = "\(indent)port: \(port)"
                replaced = true
                break
            }
        }
        if !replaced {
            lines.insert("port: \(port)", at: 0)
        }

        let tempURL = fileManager.temporaryDirectory
            .appendingPathComponent("flux-core-dryrun-\(UUID().uuidString).yaml", isDirectory: false)
        try lines.joined(separator: "\n").write(to: tempURL, atomically: true, encoding: .utf8)
        return tempURL
    }
}
