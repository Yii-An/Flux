import SwiftUI

struct FluxRootView: View {
    @Binding var currentPage: NavigationPage
    @State private var languageManager = LanguageManager.shared
    @State private var coreState: CoreRuntimeState = .stopped
    @State private var coreVersion: String?

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
            DashboardView()
        case .quota:
            QuotaView()
        case .logs:
            LogsView()
        case .providers:
            ProvidersView()
        case .agents:
            AgentsView()
        case .apiKeys:
            APIKeysView()
        case .settings:
            SettingsView()
        }
}

    private func refreshCoreStatus() async {
        coreState = await CoreManager.shared.state()
        coreVersion = (try? await CoreVersionManager.shared.activeVersion())?.version
    }

    private func toggleCore() async {
        let manager = CoreManager.shared
        let state = await manager.state()
        if state.isRunning {
            await manager.stop()
        } else {
            await manager.start()
        }
        await refreshCoreStatus()
    }
}
