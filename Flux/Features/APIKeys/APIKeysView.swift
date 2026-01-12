import SwiftUI

struct APIKeysView: View {
    @State private var viewModel = APIKeysViewModel()
    @State private var drafts: [ProviderID: String] = [:]

    var body: some View {
        List {
            // Core 未运行提示条
            if !viewModel.coreState.isRunning {
                Section {
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
                .listRowInsets(EdgeInsets(top: UITokens.Spacing.xs, leading: UITokens.Spacing.md, bottom: UITokens.Spacing.xs, trailing: UITokens.Spacing.md))
                .listRowBackground(Color.clear)
            }

            let providers = viewModel.apiKeyProviders()

            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                } header: {
                    Text("Error")
                }
            }

            Section {
                if providers.isEmpty {
                    ContentUnavailableView {
                        Label("No API Keys".localizedStatic(), systemImage: "key.horizontal")
                    } description: {
                        Text("No API-key based providers are available.".localizedStatic())
                    }
                } else {
                    ForEach(providers, id: \.self) { provider in
                        APIKeyRow(
                            provider: provider,
                            status: viewModel.status(for: provider),
                            draft: draftBinding(for: provider),
                            onSave: {
                                let value = drafts[provider] ?? ""
                                Task {
                                    await viewModel.setProviderAPIKey(value, for: provider)
                                    drafts[provider] = ""
                                }
                            },
                            onCopy: {
                                Task { await viewModel.copyProviderAPIKey(for: provider) }
                            },
                            onDelete: {
                                Task { await viewModel.deleteProviderAPIKey(for: provider) }
                            }
                        )
                        .listRowInsets(EdgeInsets(top: UITokens.Spacing.xs, leading: UITokens.Spacing.md, bottom: UITokens.Spacing.xs, trailing: UITokens.Spacing.md))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }
            }
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
        .scrollContentBackground(.hidden)
        .animation(UITokens.Animation.transition, value: viewModel.statuses.count)
    }

    private func draftBinding(for provider: ProviderID) -> Binding<String> {
        Binding(
            get: { drafts[provider] ?? "" },
            set: { drafts[provider] = $0 }
        )
    }
}

private struct APIKeyRow: View {
    let provider: ProviderID
    let status: APIKeysViewModel.ProviderKeyStatus
    @Binding var draft: String
    let onSave: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void
    @State private var isCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: UITokens.Spacing.sm) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: provider.systemImageName)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 4) {
                    Text(provider.displayName)
                        .fontWeight(.medium)

                    Text(maskedKeyText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    onCopy()
                    guard status.isSet else { return }

                    withAnimation(UITokens.Animation.hover) {
                        isCopied = true
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation(UITokens.Animation.hover) {
                            isCopied = false
                        }
                    }
                } label: {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(isCopied ? .green : .secondary)
                        .frame(width: 20, height: 20)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .help("Copy Key".localizedStatic())
                .disabled(!status.isSet)
            }

            HStack(spacing: 10) {
                SecureField("API Key", text: $draft)
                    .textFieldStyle(.roundedBorder)

                Button("Save") {
                    onSave()
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Clear") {
                    onDelete()
                }
                .disabled(!status.isSet)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(UITokens.Spacing.md)
        .fluxCardStyle()
        .contextMenu {
            Button {
                onCopy()
            } label: {
                Label("Copy Key".localizedStatic(), systemImage: "doc.on.doc")
            }
            .disabled(!status.isSet)

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete".localizedStatic(), systemImage: "trash")
            }
            .disabled(!status.isSet)
        }
    }

    private var maskedKeyText: String {
        if status.isSet, let masked = status.maskedDisplay, !masked.isEmpty {
            return masked
        }
        return "Not set".localizedStatic()
    }
}
