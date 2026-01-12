import SwiftUI

struct MenuBarPopoverView: View {
    @State private var viewModel: MenuBarViewModel
    @State private var languageManager = LanguageManager.shared

    private let onOpenMainWindow: () -> Void
    private let onOpenSettings: () -> Void
    private let onQuit: () -> Void

    init(
        viewModel: MenuBarViewModel = MenuBarViewModel(),
        onOpenMainWindow: @escaping () -> Void = {},
        onOpenSettings: @escaping () -> Void = {},
        onQuit: @escaping () -> Void = {}
    ) {
        _viewModel = State(initialValue: viewModel)
        self.onOpenMainWindow = onOpenMainWindow
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            quotaList
            Divider()
            MenuBarBottomBar(
                onOpenMainWindow: onOpenMainWindow,
                onRefresh: { await viewModel.refresh() },
                onOpenSettings: onOpenSettings,
                onQuit: onQuit,
                isLoading: viewModel.isLoading
            )
        }
        .frame(width: 300)
        .background(.regularMaterial)
        .environment(\.locale, languageManager.locale)
        .task {
            await viewModel.load()
        }
    }

    private var header: some View {
        HStack {
            Text("Flux")
                .font(.system(size: 14, weight: .bold))

            Spacer()

            if viewModel.isLoading {
                SmallProgressView()
                    .frame(width: 14, height: 14)
            } else {
                Text(viewModel.totalUsedDisplay)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var quotaList: some View {
        if viewModel.quotaItems.isEmpty {
            ContentUnavailableView {
                Label("No Providers".localizedStatic(), systemImage: "bolt.horizontal")
            } description: {
                Text("Enable at least one provider to view quota.".localizedStatic())
            }
            .padding(16)
        } else {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(viewModel.quotaItems) { item in
                        MenuBarQuotaRow(item: item)
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: 280)
        }
    }
}

