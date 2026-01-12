import Foundation

extension CoreRuntimeState {
    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var shortDescription: String {
        switch self {
        case .notInstalled:
            return "Not installed".localizedStatic()
        case .stopped:
            return "Stopped".localizedStatic()
        case .starting:
            return "Starting…".localizedStatic()
        case .running(let pid):
            return String(format: "Running (pid %@)".localizedStatic(), String(pid))
        case .stopping:
            return "Stopping…".localizedStatic()
        case .crashed(let exitCode):
            return String(format: "Crashed (exit %@)".localizedStatic(), String(exitCode))
        case .error(let error):
            return String(format: "Error: %@".localizedStatic(), error.message)
        }
    }
}
