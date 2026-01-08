import SwiftUI

struct AuthFilesView: View {
    @EnvironmentObject var appSettings: AppSettings
    @StateObject private var viewModel = AuthFilesViewModel()
    @State private var isRefreshing = false
    @State private var isQuotaRefreshing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerView

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("认证文件", systemImage: "lock.doc.fill")
                                .font(.headline)
                            Spacer()
                            Text(viewModel.authFilesState.countText)
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }

                        Divider()

                        switch viewModel.authFilesState {
                        case .idle:
                            EmptyView()
                        case .loading:
                            ProgressView()
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding()
                        case .loaded(let files) where files.isEmpty:
                            VStack(spacing: 8) {
                                Image(systemName: "tray")
                                    .font(.system(size: 32))
                                Text("暂无认证文件")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                        case .loaded(let files):
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                                    AuthFileRow(
                                        file: file,
                                        quotaState: quotaState(for: file)
                                    )
                                }
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
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            await viewModel.refresh(baseURL: appSettings.managementBaseURL, password: appSettings.managementPassword)
        }
    }

    @ViewBuilder
    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                Text("认证文件")
                    .font(.system(size: 34, weight: .bold))
                Text("查看 OAuth / 登录凭据文件状态")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            Button(action: refreshQuota) {
                HStack {
                    Image(systemName: "chart.pie")
                    Text("刷新额度")
                }
            }
            .buttonStyle(.bordered)
            .disabled(isQuotaRefreshing)

            Button(action: refresh) {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("刷新")
                }
            }
            .buttonStyle(.bordered)
            .disabled(isRefreshing)
        }
    }

    private func refresh() {
        isRefreshing = true
        Task {
            await viewModel.refresh(baseURL: appSettings.managementBaseURL, password: appSettings.managementPassword)
            isRefreshing = false
        }
    }

    private func refreshQuota() {
        isQuotaRefreshing = true
        Task {
            await viewModel.refreshQuota(baseURL: appSettings.managementBaseURL, password: appSettings.managementPassword)
            isQuotaRefreshing = false
        }
    }

    private func quotaState(for file: AuthFile) -> LoadState<String>? {
        let key = (file.name ?? file.id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return viewModel.quotaStateByName[key]
    }
}

private struct AuthFileRow: View {
    let file: AuthFile
    let quotaState: LoadState<String>?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(file.name ?? "Unknown")
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)

                if let provider = file.provider, !provider.isEmpty {
                    Text(provider)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if file.runtimeOnly == true {
                    Text("runtime_only")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                Spacer()

                if let status = file.status, !status.isEmpty {
                    Dot(color: statusColor(for: status))
                }
            }

            if let email = file.email, !email.isEmpty {
                Text(email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let label = file.label, !label.isEmpty {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let statusMessage = file.statusMessage, !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            quotaLine
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var quotaLine: some View {
        let provider = (file.provider ?? file.type ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !["antigravity", "codex", "gemini-cli"].contains(provider) {
            EmptyView()
        } else {
            switch quotaState {
            case .none:
                Text("额度：--")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .some(.idle):
                Text("额度：--")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .some(.loading):
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("额度查询中...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            case .some(.loaded(let text)):
                Text(text)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            case .some(.error(let message)):
                Text("额度：\(message)")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }

    private func statusColor(for status: String) -> Color {
        switch status.lowercased() {
        case "ready", "ok":
            return .green
        case "error", "failed":
            return .red
        case "disabled":
            return .gray
        default:
            return .orange
        }
    }
}

private struct Dot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
    }
}

#Preview {
    AuthFilesView()
        .environmentObject(AppSettings())
}
