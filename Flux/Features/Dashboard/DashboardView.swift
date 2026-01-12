import AppKit
import SwiftUI

struct DashboardView: View {
    @State private var viewModel = DashboardViewModel()

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: UITokens.Spacing.md) {
                topRow
                middleRow
                bottomRow
                quickActionsRow
            }
            .padding(UITokens.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            await viewModel.refresh()
        }
        .toolbar {
            Button {
                Task { await viewModel.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.toolbarIcon)
            .help("Refresh".localizedStatic())
            .disabled(viewModel.isRefreshing)
        }
        .animation(UITokens.Animation.transition, value: viewModel.coreState.shortDescription)
        .animation(UITokens.Animation.transition, value: viewModel.lastRefreshAt)
    }

    private var topRow: some View {
        HStack(alignment: .top, spacing: UITokens.Spacing.md) {
            CoreStatusCard(
                coreState: viewModel.coreState,
                coreVersion: viewModel.coreVersion,
                coreStartedAt: viewModel.coreStartedAt,
                corePort: viewModel.corePort,
                isRefreshing: viewModel.isRefreshing
            ) {
                Task { await viewModel.toggleCore() }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 130)

            QuotaOverviewCard(
                providerStats: viewModel.providerStats,
                quotaProvidersCount: viewModel.quotaProvidersCount
            )
            .frame(maxWidth: .infinity)
            .frame(height: 130)
        }
    }

    private var middleRow: some View {
        HStack(alignment: .top, spacing: UITokens.Spacing.md) {
            ProviderListCard(items: viewModel.providerItems)
                .frame(maxWidth: .infinity)
                .frame(height: 200)

            AgentListCard(items: viewModel.agentItems)
                .frame(maxWidth: .infinity)
                .frame(height: 200)
        }
    }

    private var bottomRow: some View {
        UsageRiskCard(quotaPressure: viewModel.quotaPressure, riskyProviders: viewModel.riskyProviders)
            .frame(maxWidth: .infinity)
            .frame(height: 160)
    }

    private var quickActionsRow: some View {
        QuickActionsRow(
            isRefreshing: viewModel.isRefreshing,
            onRefresh: { Task { await viewModel.refresh() } },
            onToggleCore: { Task { await viewModel.toggleCore() } },
            onCheckUpdates: { Task { await UpdateService.shared.checkForUpdates() } },
            onOpenConfigFolder: {
                try? FluxPaths.ensureConfigDirExists()
                openInFinder(FluxPaths.configDir())
            }
        )
        .frame(maxWidth: .infinity)
    }

    private func openInFinder(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
