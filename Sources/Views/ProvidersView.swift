import SwiftUI

struct ProvidersView: View {
    @EnvironmentObject var appSettings: AppSettings
    @StateObject private var viewModel = ProvidersViewModel()
    @State private var isRefreshing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerView

                if isRefreshing {
                    ProgressView("刷新中...")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                }

                providerSection(
                    title: "Gemini",
                    icon: "sparkles",
                    countText: viewModel.geminiKeysState.countText,
                    state: viewModel.geminiKeysState,
                    content: { keys in
                        ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                            ProviderKeyRow(
                                apiKey: key.apiKey,
                                baseUrl: key.baseUrl,
                                proxyUrl: key.proxyUrl,
                                excludedModels: key.excludedModels
                            )
                        }
                    }
                )

                providerSection(
                    title: "Codex",
                    icon: "cube.fill",
                    countText: viewModel.codexKeysState.countText,
                    state: viewModel.codexKeysState,
                    content: { keys in
                        ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                            ProviderKeyRow(
                                apiKey: key.apiKey,
                                baseUrl: key.baseUrl,
                                proxyUrl: key.proxyUrl,
                                excludedModels: key.excludedModels
                            )
                        }
                    }
                )

                providerSection(
                    title: "Claude",
                    icon: "brain.head.profile",
                    countText: viewModel.claudeKeysState.countText,
                    state: viewModel.claudeKeysState,
                    content: { keys in
                        ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                            ProviderKeyRow(
                                apiKey: key.apiKey,
                                baseUrl: key.baseUrl,
                                proxyUrl: key.proxyUrl,
                                excludedModels: key.excludedModels
                            )
                        }
                    }
                )

                providerSection(
                    title: "OpenAI Compatibility",
                    icon: "network",
                    countText: viewModel.openAICompatState.countText,
                    state: viewModel.openAICompatState,
                    content: { entries in
                        ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                            OpenAICompatRow(entry: entry)
                        }
                    }
                )
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            await viewModel.refreshAll(baseURL: appSettings.managementBaseURL, password: appSettings.managementPassword)
        }
    }

    @ViewBuilder
    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                Text("Providers")
                    .font(.system(size: 34, weight: .bold))
                Text("管理 AI 提供商配置")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            Button(action: refreshProviders) {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("刷新")
                }
            }
            .buttonStyle(.bordered)
            .disabled(isRefreshing)
        }
    }

    private func refreshProviders() {
        isRefreshing = true
        Task {
            await viewModel.refreshAll(baseURL: appSettings.managementBaseURL, password: appSettings.managementPassword)
            isRefreshing = false
        }
    }
}

@ViewBuilder
private func providerSection<T>(
    title: String,
    icon: String,
    countText: String,
    state: LoadState<[T]>,
    @ViewBuilder content: @escaping ([T]) -> some View
) -> some View {
    GroupBox {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.headline)
                Spacer()
                Text(countText)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Divider()

            switch state {
            case .idle:
                EmptyView()
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            case .loaded(let items) where items.isEmpty:
                VStack {
                    Image(systemName: "tray")
                        .font(.system(size: 32))
                    Text("暂无配置")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding()
            case .loaded(let items):
                VStack(alignment: .leading, spacing: 8) {
                    content(items)
                }
            case .error(let message):
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.system(size: 24))
                    Text("加载失败")
                        .font(.headline)
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding()
            }
        }
        .padding(.vertical, 8)
    }
}

@ViewBuilder
private func ProviderKeyRow(
    apiKey: String?,
    baseUrl: String?,
    proxyUrl: String?,
    excludedModels: [String]?
) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        if let key = apiKey, !key.isEmpty {
            HStack {
                Text(maskApiKey(key))
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                Spacer()
            }
        }

        if let url = baseUrl, !url.isEmpty {
            Text(url)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }

        if let proxy = proxyUrl, !proxy.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.2.circlepath.doc.on.clipboard")
                    .font(.caption2)
                Text(proxy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }

        if let models = excludedModels, !models.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "minus.circle")
                    .font(.caption2)
                    Text("排除: \(models.prefix(3).joined(separator: ", "))\(models.count > 3 ? " ..." : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
    .padding(.vertical, 4)
}

@ViewBuilder
private func OpenAICompatRow(entry: OpenAICompatibilityEntry) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        HStack {
            Text(entry.name ?? "Unknown")
                .font(.caption)
                .fontWeight(.medium)
            Spacer()
            if let entries = entry.apiKeyEntries {
                Image(systemName: "key.fill")
                    .font(.caption2)
                Text("\(entries.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }

        if let url = entry.baseUrl, !url.isEmpty {
            Text(url)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }

        if let models = entry.models, !models.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "cube")
                    .font(.caption2)
                Text("\(models.count) models")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    .padding(.vertical, 4)
}

@ViewBuilder
private func Dot(color: Color) -> some View {
    Circle()
        .fill(color)
        .frame(width: 6, height: 6)
}

private func maskApiKey(_ key: String) -> String {
    guard key.count > 8 else { return "***" }
    let prefix = String(key.prefix(4))
    let suffix = String(key.suffix(4))
    return "\(prefix)...\(suffix)"
}

#Preview {
    ProvidersView()
        .environmentObject(AppSettings())
}
