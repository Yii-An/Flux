import Foundation

enum ProviderID: String, CaseIterable, Codable, Sendable, Identifiable {
    case gemini
    case claude
    case codex
    case qwen
    case vertexAI
    case iFlow
    case antigravity
    case kiro
    case copilot
    case cursor
    case trae
    case glm

    var id: String { rawValue }
}

enum ProviderAuthKind: String, Codable, Sendable {
    case none
    case apiKey
    case file
    case cli
    case sqlite
}

struct ProviderDescriptor: Codable, Sendable, Identifiable, Hashable {
    let id: ProviderID
    let displayNameKey: String
    let authKind: ProviderAuthKind
    let supportsQuota: Bool

    init(id: ProviderID, displayNameKey: String, authKind: ProviderAuthKind, supportsQuota: Bool) {
        self.id = id
        self.displayNameKey = displayNameKey
        self.authKind = authKind
        self.supportsQuota = supportsQuota
    }

    static let defaults: [ProviderDescriptor] = [
        .init(id: .gemini, displayNameKey: "provider_gemini", authKind: .file, supportsQuota: false),
        .init(id: .claude, displayNameKey: "provider_claude", authKind: .file, supportsQuota: true),
        .init(id: .codex, displayNameKey: "provider_codex", authKind: .file, supportsQuota: true),
        .init(id: .qwen, displayNameKey: "provider_qwen", authKind: .apiKey, supportsQuota: false),
        .init(id: .vertexAI, displayNameKey: "provider_vertex_ai", authKind: .apiKey, supportsQuota: false),
        .init(id: .iFlow, displayNameKey: "provider_iflow", authKind: .apiKey, supportsQuota: false),
        .init(id: .antigravity, displayNameKey: "provider_antigravity", authKind: .file, supportsQuota: true),
        .init(id: .kiro, displayNameKey: "provider_kiro", authKind: .apiKey, supportsQuota: false),
        .init(id: .copilot, displayNameKey: "provider_copilot", authKind: .cli, supportsQuota: true),
        .init(id: .cursor, displayNameKey: "provider_cursor", authKind: .sqlite, supportsQuota: false),
        .init(id: .trae, displayNameKey: "provider_trae", authKind: .apiKey, supportsQuota: false),
        .init(id: .glm, displayNameKey: "provider_glm", authKind: .apiKey, supportsQuota: false),
    ]
}

extension ProviderID {
    var descriptor: ProviderDescriptor {
        ProviderDescriptor.defaultsByID[self] ?? ProviderDescriptor(
            id: self,
            displayNameKey: "provider_\(rawValue)",
            authKind: .none,
            supportsQuota: false
        )
    }
}

private extension ProviderDescriptor {
    static let defaultsByID: [ProviderID: ProviderDescriptor] = Dictionary(uniqueKeysWithValues: defaults.map { ($0.id, $0) })
}
