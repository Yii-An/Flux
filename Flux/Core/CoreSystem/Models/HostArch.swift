import Foundation

enum HostArch: String, Codable, Sendable, CaseIterable {
    case arm64
    case x86_64
}

extension HostArch {
    init?(unameMachine value: String) {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "arm64":
            self = .arm64
        case "x86_64":
            self = .x86_64
        default:
            return nil
        }
    }

    /// Expected token used by CLIProxyAPIPlus asset names (e.g. `darwin_amd64`).
    var cliProxyAPIPlusAssetToken: String {
        switch self {
        case .arm64:
            return "arm64"
        case .x86_64:
            return "amd64"
        }
    }
}

