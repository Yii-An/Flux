import SwiftUI

struct ProvidersView: View {
    let viewModel: ProvidersViewModel
    @State private var isShowingAddPlaceholder = false

    init(viewModel: ProvidersViewModel = ProvidersViewModel()) {
        self.viewModel = viewModel
    }

    var body: some View {
        List {
            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(UITokens.Spacing.md)
                        .fluxCardStyle()
                        .listRowInsets(EdgeInsets(top: UITokens.Spacing.xs, leading: UITokens.Spacing.md, bottom: UITokens.Spacing.xs, trailing: UITokens.Spacing.md))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } header: {
                    Text("Error")
                }
            }

            let groups = viewModel.groupedProviders()

            if groups.isEmpty {
                ContentUnavailableView {
                    Label("No Providers".localizedStatic(), systemImage: "bolt.horizontal")
                } description: {
                    Text("No provider definitions found.".localizedStatic())
                }
            } else {
                ForEach(groups) { group in
                    ProviderGroupCard(
                        group: group,
                        isExpanded: Binding(
                            get: { viewModel.isExpanded(group.providerID) },
                            set: { newValue in
                                withAnimation(UITokens.Animation.transition) {
                                    viewModel.setExpanded(newValue, for: group.providerID)
                                }
                            }
                        )
                    )
                    .listRowInsets(EdgeInsets(top: UITokens.Spacing.xs, leading: UITokens.Spacing.md, bottom: UITokens.Spacing.xs, trailing: UITokens.Spacing.md))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
        }
        .task {
            await viewModel.refresh()
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    isShowingAddPlaceholder = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.toolbarIcon)
                .help("Add".localizedStatic())

                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.toolbarIcon)
                .help("Refresh".localizedStatic())
                .disabled(viewModel.isRefreshing)
            }
        }
        .scrollContentBackground(.hidden)
        .animation(UITokens.Animation.transition, value: viewModel.lastUpdatedAt)
        .sheet(isPresented: $isShowingAddPlaceholder) {
            VStack(alignment: .leading, spacing: UITokens.Spacing.md) {
                Text("Add Provider".localizedStatic())
                    .font(.headline)
                Text("Not implemented yet.".localizedStatic())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(UITokens.Spacing.lg)
            .frame(minWidth: 420, minHeight: 260)
        }
    }
}

private struct ProviderGroupCard: View {
    let group: ProvidersViewModel.ProviderGroup
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ProviderAuthRow(provider: group.providerID, authState: group.authState)
                .padding(.top, UITokens.Spacing.sm)
        } label: {
            header
        }
        .padding(UITokens.Spacing.md)
        .fluxCardStyle()
        .contextMenu {
            Button {
                Pasteboard.copy(group.providerID.rawValue)
            } label: {
                Label("Copy ID".localizedStatic(), systemImage: "doc.on.doc")
            }
        }
    }

    private var header: some View {
        ProviderGroupHeader(
            providerID: group.providerID,
            count: group.credentialCount,
            isConnected: isConnected
        )
    }

    private var isConnected: Bool {
        if case .available = group.authState { return true }
        return false
    }
}

private struct ProviderGroupHeader: View {
    let providerID: ProviderID
    let count: Int
    let isConnected: Bool

    var body: some View {
        HStack {
            ProviderIcon(providerID, size: 24)

            Text(providerID.displayName)
                .font(.headline)

            Spacer()

            if !isConnected {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            Text("\(count) keys")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.1), in: Capsule())
        }
        .padding(.vertical, 4)
    }
}

private struct ProviderAuthRow: View {
    typealias ProviderAuthState = AuthFileReader.ProviderAuthState

    let provider: ProviderID
    let authState: ProviderAuthState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(authColor)
                .frame(width: 6, height: 6)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 4) {
                Text("Auth".localizedStatic())
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(authDescription)
                    .font(.caption)
                    .foregroundStyle(authColor)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }

            Spacer()
        }
    }

    private var authDescription: String {
        switch authState {
        case .available(let source, let expiresAt):
            if let expiresAt {
                return String(
                    format: "Available • expires %@ • %@".localizedStatic(),
                    formatDate(expiresAt),
                    source
                )
            }
            return String(format: "Available • %@".localizedStatic(), source)
        case .missing:
            return "Missing".localizedStatic()
        case .unsupported:
            return "Unsupported".localizedStatic()
        case .error(let error):
            return String(format: "Error • %@".localizedStatic(), error.message)
        }
    }

    private var authColor: Color {
        switch authState {
        case .available:
            return .green
        case .missing:
            return .orange
        case .unsupported:
            return .secondary
        case .error:
            return .red
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
