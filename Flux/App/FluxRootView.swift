import SwiftUI

struct FluxRootView: View {
    @Environment(\.openWindow) private var openWindow
    @Binding var currentPage: NavigationPage
    @State private var languageManager = LanguageManager.shared
    @State private var coreState: CoreRuntimeState = .stopped
    @State private var coreVersion: String?
    @State private var dashboardViewModel = DashboardViewModel()
    @State private var quotaViewModel = QuotaViewModel()
    @State private var logsViewModel = LogsViewModel()
    @State private var providersViewModel = ProvidersViewModel()
    @State private var agentsViewModel = AgentsViewModel()
    @State private var apiKeysViewModel = APIKeysViewModel()
    @State private var settingsViewModel = SettingsViewModel()

    var body: some View {
        NavigationSplitView {
            List(selection: $currentPage) {
                Section("Insight") {
                    ForEach([NavigationPage.dashboard, .quota, .logs], id: \.self) { page in
                        Label(page.title.localizedStatic(), systemImage: page.icon)
                            .tag(page)
                    }
                }

                Section("Configuration") {
                    ForEach([NavigationPage.providers, .agents, .apiKeys], id: \.self) { page in
                        Label(page.title.localizedStatic(), systemImage: page.icon)
                            .tag(page)
                    }
                }

                Section("System") {
                    Label(NavigationPage.settings.title.localizedStatic(), systemImage: NavigationPage.settings.icon)
                        .tag(NavigationPage.settings)
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                CoreStatusBar(coreState: coreState, version: coreVersion) {
                    Task {
                        await toggleCore()
                    }
                }
            }
            .navigationTitle("Flux".localizedStatic())
            .navigationSplitViewColumnWidth(min: 170, ideal: 195, max: 220)
        } detail: {
            NavigationStack {
                detailView(for: currentPage)
            }
            .navigationTitle(currentPage.title.localizedStatic())
        }
        .environment(\.locale, languageManager.locale)
        .frame(minWidth: 1100, minHeight: 700)
        .task {
            await WindowPolicyManager.shared.registerOpenWindow(openWindow)
            await refreshCoreStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: FluxNavigation.notification)) { notification in
            guard let rawValue = notification.userInfo?[FluxNavigation.pageUserInfoKey] as? String,
                  let page = NavigationPage(rawValue: rawValue)
            else { return }
            currentPage = page
        }
    }

    @ViewBuilder
    private func detailView(for page: NavigationPage) -> some View {
        switch page {
        case .dashboard:
            DashboardView(viewModel: dashboardViewModel)
        case .quota:
            QuotaView(viewModel: quotaViewModel)
        case .logs:
            LogsView(viewModel: logsViewModel)
        case .providers:
            ProvidersView(viewModel: providersViewModel)
        case .agents:
            AgentsView(viewModel: agentsViewModel)
        case .apiKeys:
            APIKeysView(viewModel: apiKeysViewModel)
        case .settings:
            SettingsView(viewModel: settingsViewModel)
        }
}

    private func refreshCoreStatus() async {
        coreState = await CoreOrchestrator.shared.runtimeState()
        if let version = try? await CoreStorage.shared.currentVersion() {
            coreVersion = version
        } else {
            coreVersion = nil
        }
    }

    private func toggleCore() async {
        let orchestrator = CoreOrchestrator.shared
        let state = await orchestrator.runtimeState()
        if state.isRunning {
            await orchestrator.stop()
        } else {
            await orchestrator.start()
        }
        await refreshCoreStatus()
    }
}
