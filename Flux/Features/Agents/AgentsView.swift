import SwiftUI

struct AgentsView: View {
    let viewModel: AgentsViewModel

    init(viewModel: AgentsViewModel = AgentsViewModel()) {
        self.viewModel = viewModel
    }

    var body: some View {
        ScrollView {
            let columns = [GridItem(.adaptive(minimum: 240), spacing: UITokens.Spacing.md, alignment: .topLeading)]

            VStack(alignment: .leading, spacing: UITokens.Spacing.md) {
                // Core 未运行提示条
                if !viewModel.coreState.isRunning {
                    HStack(spacing: 12) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.orange)

                        Text("Core is not running. Some features may be limited.".localizedStatic())
                            .foregroundStyle(.primary)
                            .font(.subheadline)

                        Spacer()

                        Button("Start Core".localizedStatic()) {
                            Task { await viewModel.startCore() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(UITokens.Spacing.md)
                    .background(Color.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: UITokens.Radius.medium))
                }

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if AgentID.allCases.isEmpty {
                    ContentUnavailableView {
                        Label("No Agents".localizedStatic(), systemImage: "terminal")
                    } description: {
                        Text("No CLI agents detected on this system.".localizedStatic())
                    }
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: UITokens.Spacing.md) {
                        ForEach(AgentID.allCases, id: \.self) { agent in
                            AgentGridCard(
                                agent: agent,
                                status: viewModel.status(for: agent),
                                isEnabled: Binding(
                                    get: { viewModel.enabledAgents.contains(agent) },
                                    set: { newValue in
                                        Task { await viewModel.setEnabled(newValue, for: agent) }
                                    }
                                ),
                                onOpenInFinder: {
                                    Task { await viewModel.openInFinder(agent) }
                                }
                            )
                        }
                    }
                }
            }
            .padding(UITokens.Spacing.md)
        }
        .task {
            await viewModel.refresh()
        }
        .toolbar {
            Button {
                Task { await viewModel.refresh(forceRefresh: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.toolbarIcon)
            .help("Refresh".localizedStatic())
            .disabled(viewModel.isRefreshing)
        }
        .animation(UITokens.Animation.transition, value: viewModel.statuses.count)
    }
}

private struct AgentGridCard: View {
    let agent: AgentID
    let status: AgentStatus
    @Binding var isEnabled: Bool
    let onOpenInFinder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(status.isInstalled ? Color.blue.opacity(0.1) : Color.gray.opacity(0.1))
                        .frame(width: 36, height: 36)

                    Image(systemName: "terminal.fill")
                        .foregroundStyle(status.isInstalled ? Color.blue : Color.gray)
                }

                Spacer()

                Toggle("", isOn: $isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!status.isInstalled)
                    .scaleEffect(0.8)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(agent.displayName)
                    .font(.headline)
                    .foregroundStyle(status.isInstalled ? .primary : .secondary)

                Text(agent.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let version = status.version, !version.isEmpty {
                    Text(version)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(12)
        .opacity(status.isInstalled ? 1.0 : 0.6)
        .overlay(
            RoundedRectangle(cornerRadius: UITokens.Radius.medium)
                .stroke(status.isInstalled ? Color.blue.opacity(0.2) : Color.clear, lineWidth: 1)
        )
        .fluxCardStyle()
        .contextMenu {
            Button {
                onOpenInFinder()
            } label: {
                Label("Open in Finder".localizedStatic(), systemImage: "folder")
            }
            .disabled(!status.isInstalled)
        }
    }
}
