import Foundation

struct AgentIntegrationItem: Identifiable, Sendable, Hashable {
    let agentID: AgentID
    let isInstalled: Bool
    let version: String?

    var id: AgentID { agentID }
}

