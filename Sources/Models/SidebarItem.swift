import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case overview = "概览"
    case providers = "Provider"
    case authFiles = "认证文件"
    case agents = "Agent 配置"
    case settings = "设置"
    case logs = "日志"
    
    var id: String { rawValue }
    
    var title: String { rawValue }
    
    var systemImage: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.bottom.50percent"
        case .providers: return "server.rack"
        case .authFiles: return "lock.doc.fill"
        case .agents: return "cpu"
        case .settings: return "gearshape"
        case .logs: return "doc.text"
        }
    }
}
