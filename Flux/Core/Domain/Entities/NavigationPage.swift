import Foundation

enum NavigationPage: String, CaseIterable, Identifiable {
    case dashboard, quota, logs, providers, agents, apiKeys, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .quota: return "Quota"
        case .logs: return "Logs"
        case .providers: return "Providers"
        case .agents: return "Agents"
        case .apiKeys: return "API Keys"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.bottom.50percent"
        case .quota: return "chart.pie.fill"
        case .logs: return "list.bullet.rectangle.portrait"
        case .providers: return "server.rack"
        case .agents: return "terminal.fill"
        case .apiKeys: return "key.horizontal.fill"
        case .settings: return "gearshape"
        }
    }
}

