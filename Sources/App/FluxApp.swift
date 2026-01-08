import SwiftUI

@main
struct FluxApp: App {
    @StateObject private var appViewModel = AppViewModel()
    @StateObject private var appSettings = AppSettings()
    @StateObject private var runtimeService = CLIProxyAPIRuntimeService()
    @StateObject private var updateService = UpdateService()
    @StateObject private var proxyCoordinator = ManagedProxyCoordinator()
    @Environment(\.openWindow) private var openWindow

    init() {
        // Request notification authorization on launch
        Task {
            await NotificationService.shared.requestAuthorization()
        }
    }

    var body: some Scene {
        MenuBarExtra("Flux", systemImage: "bolt.horizontal.circle") {
            Button("打开面板") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("o", modifiers: .command)

            Divider()

            // Runtime status indicator
            switch runtimeService.state {
            case .running(let pid, let port, _):
                Text("运行中 (PID: \(pid), 端口: \(port))")
                    .foregroundStyle(.secondary)
            case .stopped:
                Text("已停止")
                    .foregroundStyle(.secondary)
            case .starting:
                Text("启动中...")
                    .foregroundStyle(.secondary)
            case .stopping:
                Text("停止中...")
                    .foregroundStyle(.secondary)
            case .failed(let reason):
                Text("失败: \(reason)")
                    .foregroundStyle(.red)
            }

            Divider()

            // Quick actions
            if case .running = runtimeService.state {
                Button("停止 CLIProxyAPI") {
                    Task {
                        await runtimeService.stop()
                        NotificationService.shared.notifyProcessStopped()
                    }
                }
            } else if case .stopped = runtimeService.state {
                Button("启动 CLIProxyAPI") {
                    Task {
                        if let path = ProxyStorageManager.shared.currentBinaryPath?.path {
                            await runtimeService.start(
                                binaryPath: path,
                                port: appSettings.cliProxyAPIPort,
                                configPath: appSettings.cliProxyAPIConfigPath
                            )
                            if case .running(_, let port, _) = runtimeService.state {
                                NotificationService.shared.notifyProcessStarted(port: port)
                            }
                        }
                    }
                }
                .disabled(ProxyStorageManager.shared.currentBinaryPath == nil)
            }

            Divider()

            Button("检查更新...") {
                updateService.checkForUpdates()
            }
            .disabled(!updateService.canCheckForUpdates)

            Button("退出") {
                Task {
                    if case .running = runtimeService.state {
                        await runtimeService.stop()
                    }
                    NSApp.terminate(nil)
                }
            }
            .keyboardShortcut("q", modifiers: .command)
        }

        Window("Flux", id: "main") {
            ContentView()
                .environmentObject(appViewModel)
                .environmentObject(appSettings)
                .environmentObject(runtimeService)
                .environmentObject(updateService)
                .environmentObject(proxyCoordinator)
        }
        .defaultSize(width: 980, height: 680)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("检查更新...") {
                    updateService.checkForUpdates()
                }
                .disabled(!updateService.canCheckForUpdates)
            }
        }
    }
}
