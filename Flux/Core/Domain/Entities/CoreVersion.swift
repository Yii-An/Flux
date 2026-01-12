import Foundation

struct CoreVersion: Codable, Sendable, Identifiable, Hashable {
    var id: String { sha256 }

    var version: String
    var installedAt: Date
    var path: URL
    var sha256: String
    var isActive: Bool

    init(version: String, installedAt: Date, path: URL, sha256: String, isActive: Bool) {
        self.version = version
        self.installedAt = installedAt
        self.path = path
        self.sha256 = sha256
        self.isActive = isActive
    }
}

enum CoreRuntimeState: Sendable {
    case notInstalled
    case stopped
    case starting
    case running(pid: Int32)
    case stopping
    case crashed(exitCode: Int32)
    case error(FluxError)
}
