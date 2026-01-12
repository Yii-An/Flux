import SwiftUI

extension ProviderID {
    var displayName: String {
        descriptor.displayNameKey.localizedStatic()
    }

    var systemImageName: String {
        switch self {
        case .claude: "sparkles"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .gemini, .geminiCLI: "wand.and.stars"
        case .copilot: "brain"
        case .cursor: "cursorarrow.rays"
        default: "bolt.horizontal"
        }
    }

    var tintColor: Color {
        switch self {
        case .claude:
            return Color(red: 0.98, green: 0.36, blue: 0.23)
        case .codex:
            return Color(red: 0.08, green: 0.66, blue: 0.43)
        case .gemini:
            return Color(red: 0.40, green: 0.35, blue: 0.98)
        case .geminiCLI:
            return Color(red: 0.40, green: 0.35, blue: 0.98)
        case .qwen:
            return Color(red: 0.91, green: 0.25, blue: 0.35)
        case .vertexAI:
            return Color(red: 0.26, green: 0.56, blue: 0.98)
        case .iFlow:
            return Color(red: 0.10, green: 0.70, blue: 0.68)
        case .antigravity:
            return Color(red: 0.86, green: 0.33, blue: 0.80)
        case .kiro:
            return Color(red: 0.98, green: 0.66, blue: 0.16)
        case .copilot:
            return Color(red: 0.16, green: 0.67, blue: 0.36)
        case .cursor:
            return Color(red: 0.20, green: 0.50, blue: 0.98)
        case .trae:
            return Color(red: 0.55, green: 0.36, blue: 0.98)
        case .glm:
            return Color(red: 0.86, green: 0.28, blue: 0.33)
        }
    }
}
