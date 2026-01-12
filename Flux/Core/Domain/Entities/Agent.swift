import Foundation

enum AgentID: String, CaseIterable, Codable, Sendable, Identifiable {
    case claudeCode
    case codexCLI
    case geminiCLI
    case ampCLI
    case openCode
    case factoryDroid

    var id: String { rawValue }
}

struct AgentConfig: Codable, Sendable, Hashable {
    var enabled: Bool
    var executablePath: String?
    var arguments: [String]
    var environment: [String: String]

    init(
        enabled: Bool = true,
        executablePath: String? = nil,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) {
        self.enabled = enabled
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
    }
}

struct AgentStatus: Codable, Sendable, Hashable {
    var isInstalled: Bool
    var version: String?
    var lastCheckedAt: Date?

    init(isInstalled: Bool = false, version: String? = nil, lastCheckedAt: Date? = nil) {
        self.isInstalled = isInstalled
        self.version = version
        self.lastCheckedAt = lastCheckedAt
    }
}
