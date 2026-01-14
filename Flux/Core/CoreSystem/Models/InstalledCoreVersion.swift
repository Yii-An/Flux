import Foundation

struct InstalledCoreVersion: Codable, Sendable, Identifiable, Equatable {
    var version: String
    var installedAt: Date
    var executableURL: URL
    var sha256: String?
    var arch: HostArch?
    var isCurrent: Bool

    var id: String { version }
}

