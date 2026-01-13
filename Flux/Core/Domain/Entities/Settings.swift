import Foundation

enum AppLanguage: String, Codable, Sendable {
    case system
    case en
    case zhHans = "zh-Hans"
}

struct AppSettings: Codable, Sendable, Hashable {
    var language: AppLanguage
    var refreshIntervalSeconds: Int
    var showInDock: Bool
    var startAtLogin: Bool
    var keepCoreVersions: Int
    var automaticallyChecksForUpdates: Bool
    var autoRestartCore: Bool
    var enabledAgents: Set<AgentID>
    var logConfig: LogConfig

    init(
        language: AppLanguage = .system,
        refreshIntervalSeconds: Int = 300,
        showInDock: Bool = false,
        startAtLogin: Bool = false,
        keepCoreVersions: Int = 2,
        automaticallyChecksForUpdates: Bool = true,
        autoRestartCore: Bool = true,
        enabledAgents: Set<AgentID> = Set(AgentID.allCases),
        logConfig: LogConfig = LogConfig()
    ) {
        self.language = language
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.showInDock = showInDock
        self.startAtLogin = startAtLogin
        self.keepCoreVersions = keepCoreVersions
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        self.autoRestartCore = autoRestartCore
        self.enabledAgents = enabledAgents
        self.logConfig = logConfig
    }

    static let `default` = AppSettings()

    var autoCheckUpdates: Bool {
        get { automaticallyChecksForUpdates }
        set { automaticallyChecksForUpdates = newValue }
    }

    enum CodingKeys: String, CodingKey {
        case language
        case refreshIntervalSeconds
        case showInDock
        case startAtLogin
        case keepCoreVersions
        case automaticallyChecksForUpdates
        case autoRestartCore
        case enabledAgents
        case logConfig
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        language = try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
        refreshIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .refreshIntervalSeconds) ?? 300
        showInDock = try container.decodeIfPresent(Bool.self, forKey: .showInDock) ?? false
        startAtLogin = try container.decodeIfPresent(Bool.self, forKey: .startAtLogin) ?? false
        keepCoreVersions = try container.decodeIfPresent(Int.self, forKey: .keepCoreVersions) ?? 2
        automaticallyChecksForUpdates = try container.decodeIfPresent(Bool.self, forKey: .automaticallyChecksForUpdates) ?? true
        autoRestartCore = try container.decodeIfPresent(Bool.self, forKey: .autoRestartCore) ?? true
        enabledAgents = try container.decodeIfPresent(Set<AgentID>.self, forKey: .enabledAgents) ?? Set(AgentID.allCases)
        logConfig = try container.decodeIfPresent(LogConfig.self, forKey: .logConfig) ?? LogConfig()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(language, forKey: .language)
        try container.encode(refreshIntervalSeconds, forKey: .refreshIntervalSeconds)
        try container.encode(showInDock, forKey: .showInDock)
        try container.encode(startAtLogin, forKey: .startAtLogin)
        try container.encode(keepCoreVersions, forKey: .keepCoreVersions)
        try container.encode(automaticallyChecksForUpdates, forKey: .automaticallyChecksForUpdates)
        try container.encode(autoRestartCore, forKey: .autoRestartCore)
        try container.encode(enabledAgents, forKey: .enabledAgents)
        try container.encode(logConfig, forKey: .logConfig)
    }
}
