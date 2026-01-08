import Foundation
import os.log

enum CLIProxyAPIRunState: Equatable {
    case stopped
    case starting
    case running(pid: Int32, port: Int, startDate: Date)
    case stopping
    case failed(reason: String)
    
    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

@MainActor
final class CLIProxyAPIRuntimeService: ObservableObject {
    @Published private(set) var state: CLIProxyAPIRunState = .stopped
    @Published private(set) var logs: [String] = []
    
    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private let logger = Logger(subsystem: "com.flux.app", category: "CLIProxyAPIRuntime")
    private let maxLogLines = 500
    
    func start(binaryPath: String, port: Int, configPath: String? = nil) async {
        guard case .stopped = state else {
            logger.warning("Cannot start: not in stopped state")
            return
        }
        
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            state = .failed(reason: "二进制文件不可执行: \(binaryPath)")
            return
        }
        
        guard port > 0 && port <= 65535 else {
            state = .failed(reason: "端口无效: \(port)")
            return
        }
        
        state = .starting
        logs.removeAll()
        
        do {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: binaryPath)
            
            var args = ["--port", String(port)]
            if let config = configPath, !config.isEmpty {
                args.append(contentsOf: ["--config", config])
            }
            proc.arguments = args
            
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            
            outputPipe = outPipe
            errorPipe = errPipe
            
            setupOutputHandler(pipe: outPipe)
            setupOutputHandler(pipe: errPipe)
            
            proc.terminationHandler = { [weak self] _ in
                Task { @MainActor in
                    self?.handleTermination()
                }
            }
            
            try proc.run()
            process = proc
            
            // Give it a moment to start
            try? await Task.sleep(for: .milliseconds(500))
            
            if proc.isRunning {
                state = .running(pid: proc.processIdentifier, port: port, startDate: Date())
                logger.info("CLIProxyAPI started with PID \(proc.processIdentifier) on port \(port)")
            } else {
                state = .failed(reason: "进程启动后立即退出")
            }
        } catch {
            state = .failed(reason: error.localizedDescription)
            logger.error("Failed to start CLIProxyAPI: \(error.localizedDescription)")
        }
    }
    
    func stop() async {
        guard case .running(let pid, _, _) = state else {
            logger.warning("Cannot stop: not running")
            return
        }
        
        state = .stopping
        
        // Try graceful termination first
        process?.terminate()
        
        // Wait for termination with timeout
        for _ in 0..<30 {
            if !(process?.isRunning ?? false) {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        
        // Force kill if still running
        if process?.isRunning == true {
            process?.interrupt()
            try? await Task.sleep(for: .milliseconds(500))
            
            // Last resort: SIGKILL via kill command
            if process?.isRunning == true {
                kill(pid, SIGKILL)
                logger.warning("Force killed CLIProxyAPI with SIGKILL")
            }
        }
        
        cleanupPipes()
        process = nil
        state = .stopped
        logger.info("CLIProxyAPI stopped")
    }
    
    func restart(binaryPath: String, port: Int, configPath: String? = nil) async {
        await stop()
        try? await Task.sleep(for: .milliseconds(200))
        await start(binaryPath: binaryPath, port: port, configPath: configPath)
    }
    
    private func setupOutputHandler(pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            
            if let output = String(data: data, encoding: .utf8) {
                Task { @MainActor in
                    self?.appendLog(output)
                }
            }
        }
    }

    private func cleanupPipes() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        errorPipe = nil
    }
    
    private func appendLog(_ text: String) {
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        logs.append(contentsOf: lines)
        
        if logs.count > maxLogLines {
            logs.removeFirst(logs.count - maxLogLines)
        }
    }
    
    private func handleTermination() {
        cleanupPipes()
        if case .running = state {
            state = .stopped
            logger.info("CLIProxyAPI terminated unexpectedly")
        } else if case .stopping = state {
            state = .stopped
        }
        process = nil
    }
}
