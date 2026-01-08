import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appViewModel: AppViewModel
    @EnvironmentObject var appSettings: AppSettings
    @EnvironmentObject var runtimeService: CLIProxyAPIRuntimeService
    @StateObject private var navigationViewModel = NavigationViewModel()
    
    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $navigationViewModel.selection) { item in
                Label(item.title, systemImage: item.systemImage)
                    .tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            detailView
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch navigationViewModel.selection ?? .overview {
        case .overview:
            OverviewView()
        case .providers:
            ProvidersView()
        case .authFiles:
            AuthFilesView()
        case .agents:
            PlaceholderView(item: .agents)
        case .settings:
            SettingsView()
        case .logs:
            LogsView()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppViewModel())
        .environmentObject(AppSettings())
        .environmentObject(CLIProxyAPIRuntimeService())
}
