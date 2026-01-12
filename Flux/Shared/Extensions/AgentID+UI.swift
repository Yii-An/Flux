import Foundation

extension AgentID {
    var displayName: String {
        switch self {
        case .claudeCode: "agent_claude_code".localizedStatic()
        case .codexCLI: "agent_codex_cli".localizedStatic()
        case .geminiCLI: "agent_gemini_cli".localizedStatic()
        case .ampCLI: "agent_amp_cli".localizedStatic()
        case .openCode: "agent_opencode".localizedStatic()
        case .factoryDroid: "agent_factory_droid".localizedStatic()
        }
    }

    var systemImageName: String {
        "terminal"
    }
}
