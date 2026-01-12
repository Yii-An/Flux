import Foundation

actor AgentDiscoveryService {
    static let shared = AgentDiscoveryService()

    private var cachedStatuses: [AgentID: AgentStatus]?
    private var cacheTimestamp: Date?
    private let cacheValidity: TimeInterval = 60

    private let cliExecutor: CLIExecutor

    init(cliExecutor: CLIExecutor = .shared) {
        self.cliExecutor = cliExecutor
    }

    func detectAll(forceRefresh: Bool = false) async -> [AgentID: AgentStatus] {
        if !forceRefresh,
           let cached = cachedStatuses,
           let timestamp = cacheTimestamp,
           Date().timeIntervalSince(timestamp) < cacheValidity {
            return cached
        }

        var results: [AgentID: AgentStatus] = [:]
        for agent in AgentID.allCases {
            results[agent] = await detectAgent(agent)
        }

        cachedStatuses = results
        cacheTimestamp = Date()
        return results
    }

    func detectAgent(_ agent: AgentID) async -> AgentStatus {
        let now = Date()
        let binary = await cliExecutor.findBinary(names: agent.binaryNames)

        guard let binary else {
            return AgentStatus(isInstalled: false, version: nil, lastCheckedAt: now)
        }

        let version = await getVersion(binaryPath: binary)
        return AgentStatus(isInstalled: true, version: version, lastCheckedAt: now)
    }

    func invalidateCache() {
        cachedStatuses = nil
        cacheTimestamp = nil
    }

    private func getVersion(binaryPath: URL) async -> String? {
        do {
            let result = try await cliExecutor.run(binaryPath: binaryPath, args: ["--version"], timeout: 5)
            let candidate = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let combined = candidate.isEmpty ? fallback : candidate
            return combined
                .components(separatedBy: .newlines)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}

extension AgentID {
    var binaryNames: [String] {
        switch self {
        case .claudeCode:
            ["claude"]
        case .codexCLI:
            ["codex"]
        case .geminiCLI:
            ["gemini"]
        case .ampCLI:
            ["amp"]
        case .openCode:
            ["opencode", "oc"]
        case .factoryDroid:
            ["droid", "fd"]
        }
    }
}
