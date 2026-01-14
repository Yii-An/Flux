import Foundation

enum ProviderKind: String, CaseIterable, Sendable, Codable {
    case antigravity
    case codex
    case geminiCLI
}

extension ProviderKind {
    var displayName: String {
        switch self {
        case .antigravity: "Antigravity"
        case .codex: "Codex"
        case .geminiCLI: "Gemini CLI"
        }
    }
}

