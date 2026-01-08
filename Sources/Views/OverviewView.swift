import SwiftUI

struct OverviewView: View {
    @EnvironmentObject var appSettings: AppSettings
    @EnvironmentObject var runtimeService: CLIProxyAPIRuntimeService
    @EnvironmentObject var proxyCoordinator: ManagedProxyCoordinator
    @StateObject private var viewModel = OverviewViewModel()
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("概览")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                // 1. 服务状态 Hero Card
                ServiceHeroCard(
                    runtimeState: runtimeService.state,
                    healthState: viewModel.healthState,
                    localVersion: proxyCoordinator.currentVersion,
                    serverVersion: viewModel.serverVersion,
                    proxyPort: appSettings.cliProxyAPIPort,
                    isExternalRunning: isExternalRunning,
                    onStart: startService,
                    onStop: stopService,
                    onRestart: restartService
                )

                // 2. 统计卡片 (2x2 网格)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    MetricCard(
                        title: "API Keys",
                        value: metricText(for: \.apiKeysCount),
                        subtitle: "个配置项",
                        icon: "key.horizontal",
                        color: .blue
                    )

                    MetricCard(
                        title: "AI 供应商",
                        value: metricText(for: \.providersCount),
                        subtitle: "个第三方中转",
                        icon: "server.rack",
                        color: .purple
                    )

                    MetricCard(
                        title: "认证文件",
                        value: metricText(for: \.authFilesCount),
                        subtitle: "个会话文件",
                        icon: "doc.badge.gearshape",
                        color: .orange
                    )

                    MetricCard(
                        title: "可用模型",
                        value: metricText(for: \.modelsCount),
                        subtitle: "个模型",
                        icon: "cpu",
                        color: .green
                    )
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            await proxyCoordinator.refresh()
            await viewModel.refresh(baseURL: appSettings.managementBaseURL, password: appSettings.managementPassword)
        }
    }
    
    // MARK: - Helpers

    private var isExternalRunning: Bool {
        if runtimeService.state.isRunning { return false }
        if case .loaded(let h) = viewModel.healthState, h.status == "ok" {
            return true
        }
        return false
    }
    
    private func metricText(for keyPath: KeyPath<DashboardStats, Int>) -> String {
        if case .loaded(let stats) = viewModel.dashboardStatsState {
            return "\(stats[keyPath: keyPath])"
        }
        return "--"
    }

    // MARK: - Actions

    private func startService() {
        Task {
            if let path = ProxyStorageManager.shared.currentBinaryPath?.path {
                await runtimeService.start(
                    binaryPath: path,
                    port: appSettings.cliProxyAPIPort,
                    configPath: appSettings.cliProxyAPIConfigPath
                )
            }
        }
    }

    private func stopService() {
        Task { await runtimeService.stop() }
    }

    private func restartService() {
        Task {
            if let path = ProxyStorageManager.shared.currentBinaryPath?.path {
                await runtimeService.restart(
                    binaryPath: path,
                    port: appSettings.cliProxyAPIPort,
                    configPath: appSettings.cliProxyAPIConfigPath
                )
            }
        }
    }
}

// MARK: - Service Hero Card

struct ServiceHeroCard: View {
    let runtimeState: CLIProxyAPIRunState
    let healthState: LoadState<HealthResponse>
    let localVersion: String?
    let serverVersion: String?
    let proxyPort: Int
    let isExternalRunning: Bool
    let onStart: () -> Void
    let onStop: () -> Void
    let onRestart: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                // 上部分：状态图标 + 信息 + 按钮
                HStack(spacing: 20) {
                    // 左侧图标
                    ZStack {
                        Circle()
                            .fill(statusColor.opacity(0.1))
                            .frame(width: 56, height: 56)

                        Image(systemName: statusIcon)
                            .font(.system(size: 28))
                            .foregroundStyle(statusColor)
                    }

                    // 中间信息
                    VStack(alignment: .leading, spacing: 4) {
                        Text(statusTitle)
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundStyle(statusColor)

                        Text(versionText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    // 连接状态指示
                    connectionBadge

                    // 右侧操作按钮
                    HStack(spacing: 12) {
                        if runtimeState.isRunning {
                            Button(action: onRestart) {
                                Label("重启", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)

                            Button(action: onStop) {
                                Label("停止", systemImage: "stop.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                        } else if !isExternalRunning {
                            Button(action: onStart) {
                                Label("启动", systemImage: "play.fill")
                                    .frame(minWidth: 80)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            .disabled(localVersion == nil)
                        } else {
                            // 外部运行中，不显示操作按钮或显示提示
                            Text("外部管理")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.secondary.opacity(0.1))
                                .cornerRadius(4)
                        }
                    }
                }

                Divider()

                // 下部分：中转地址 + 运行指标
                HStack {
                    // 中转地址
                    HStack(spacing: 8) {
                        Text("中转地址:")
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        Text(proxyURL)
                            .font(.callout)
                            .fontWeight(.medium)
                            .monospaced()
                            .textSelection(.enabled)

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(proxyURL, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help("复制地址")
                    }

                    Spacer()

                    // 运行指标 (仅运行态显示)
                    if case .running(let pid, let port, let startDate) = runtimeState {
                        HStack(spacing: 16) {
                            HStack(spacing: 4) {
                                Image(systemName: "cpu")
                                Text("PID: \(pid)")
                            }
                            HStack(spacing: 4) {
                                Image(systemName: "network")
                                Text("端口: \(port)")
                            }
                            HStack(spacing: 4) {
                                Image(systemName: "clock")
                                Text(formatUptime(from: startDate))
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else if isExternalRunning {
                        HStack(spacing: 4) {
                            Image(systemName: "network")
                            Text("端口: \(proxyPort)")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
        }
    }

    // MARK: - Connection Badge

    @ViewBuilder
    private var connectionBadge: some View {
        switch healthState {
        case .loading:
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.6)
                Text("连接中")
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(4)
        case .loaded(let h) where h.status == "ok":
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("API 已连接")
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.green.opacity(0.1))
            .cornerRadius(4)
        case .error:
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text("连接失败")
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.red.opacity(0.1))
            .cornerRadius(4)
        default:
            EmptyView()
        }
    }

    // MARK: - Logic Properties

    private var statusColor: Color {
        if runtimeState.isRunning { return .green }
        if isExternalRunning { return .blue }
        return .secondary
    }

    private var statusIcon: String {
        if runtimeState.isRunning { return "checkmark.shield.fill" }
        if isExternalRunning { return "externaldrive.connected.to.line.below.fill" }
        return "power.circle"
    }

    private var statusTitle: String {
        if runtimeState.isRunning { return "服务运行中" }
        if isExternalRunning { return "外部服务运行中" }
        return "服务已停止"
    }

    private var versionText: String {
        if runtimeState.isRunning {
            // 托管运行中
            if let version = localVersion {
                return "版本: v\(version)"
            }
            return "版本: 未知"
        } else if isExternalRunning {
            // 外部运行中 - 使用 serverVersion
            if let version = serverVersion, !version.isEmpty {
                return "版本: v\(version)"
            }
            return "版本: 运行中"
        } else {
            // 已停止
            if let version = localVersion {
                return "版本: v\(version)"
            }
            return "版本: 未安装"
        }
    }

    private var proxyURL: String {
        "http://127.0.0.1:\(proxyPort)/v1"
    }

    private func formatUptime(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "\(Int(interval))s" }
        if interval < 3600 { return "\(Int(interval)/60)m" }
        return "\(Int(interval)/3600)h"
    }
}

// MARK: - Metric Card

struct MetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let color: Color

    var body: some View {
        GroupBox {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: icon)
                            .foregroundStyle(color)
                        Text(title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Text(value)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.primary)
                    
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(8)
        }
    }
}

#Preview {
    OverviewView()
        .environmentObject(AppSettings())
        .environmentObject(CLIProxyAPIRuntimeService())
        .environmentObject(ManagedProxyCoordinator())
}
