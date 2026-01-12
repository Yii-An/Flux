import Foundation

actor CLIExecutor {
    static let shared = CLIExecutor()

    private let fileManager = FileManager.default

    private let staticSearchPaths: [String] = [
        "/usr/local/bin",
        "/opt/homebrew/bin",
        "/usr/bin",
        "~/.local/bin",
        "~/.cargo/bin",
        "~/.bun/bin",
        "~/.deno/bin",
        "~/.npm-global/bin",
        "~/.opencode/bin",
        "~/.volta/bin",
        "~/.asdf/shims",
        "~/.local/share/mise/shims",
    ]

    private init() {}

    func findBinary(names: [String]) async -> URL? {
        for name in names {
            if let url = await which(name) {
                return url
            }

            for base in staticSearchPaths {
                let path = (expandTilde(base) as NSString).appendingPathComponent(name)
                if fileManager.isExecutableFile(atPath: path) {
                    return URL(fileURLWithPath: path)
                }
            }

            for path in versionManagerPaths(binaryName: name) {
                if fileManager.isExecutableFile(atPath: path) {
                    return URL(fileURLWithPath: path)
                }
            }
        }
        return nil
    }

    func run(binaryPath: URL, args: [String], timeout: TimeInterval = 30) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = binaryPath
        process.arguments = args
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw FluxError(
                code: .unknown,
                message: "Failed to start process",
                details: "\(binaryPath.path) \(args.joined(separator: " ")) - \(error.localizedDescription)"
            )
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                throw FluxError(
                    code: .unknown,
                    message: "Command timed out",
                    details: "\(binaryPath.path) \(args.joined(separator: " "))",
                    recoverySuggestion: "Try increasing timeout or verify the CLI is responsive"
                )
            }
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }

        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }

    private func which(_ name: String) async -> URL? {
        do {
            let result = try await run(binaryPath: URL(fileURLWithPath: "/usr/bin/which"), args: [name], timeout: 2)
            guard result.exitCode == 0 else { return nil }
            let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return URL(fileURLWithPath: trimmed)
        } catch {
            return nil
        }
    }

    private func expandTilde(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    private func versionManagerPaths(binaryName name: String) -> [String] {
        let home = fileManager.homeDirectoryForCurrentUser.path
        var results: [String] = []

        // nvm: ~/.nvm/versions/node/v*/bin/<name>
        let nvmBase = "\(home)/.nvm/versions/node"
        if let versions = try? fileManager.contentsOfDirectory(atPath: nvmBase) {
            for version in versions.sorted().reversed() {
                results.append("\(nvmBase)/\(version)/bin/\(name)")
            }
        }

        // fnm: $XDG_DATA_HOME/fnm (defaults to ~/.local/share/fnm), then legacy ~/.fnm
        let xdgDataHome = (ProcessInfo.processInfo.environment["XDG_DATA_HOME"]?.isEmpty == false)
            ? ProcessInfo.processInfo.environment["XDG_DATA_HOME"]!
            : "\(home)/.local/share"
        let fnmCandidates = [
            "\(xdgDataHome)/fnm/node-versions",
            "\(home)/.fnm/node-versions",
        ]

        for base in fnmCandidates {
            if let versions = try? fileManager.contentsOfDirectory(atPath: base), !versions.isEmpty {
                for version in versions.sorted().reversed() {
                    results.append("\(base)/\(version)/installation/bin/\(name)")
                }
                break
            }
        }

        return results
    }
}
