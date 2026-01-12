import SwiftUI

struct QuotaView: View {
    @State private var viewModel = QuotaViewModel()
    @State private var selectedProvider: ProviderID = .claude
    @State private var isSpinningRefresh = false

    var body: some View {
        VStack(spacing: 0) {
            TopHeader(
                selectedProvider: $selectedProvider,
                providers: sortedProviders(),
                countsByProvider: countsByProvider,
                summary: quotaSummary,
                lastRefreshAt: viewModel.lastRefreshAt
            )

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: UITokens.Spacing.md) {
                        let providers = sortedProviders()

                        if providers.isEmpty {
                            ContentUnavailableView {
                                Label("No Providers".localizedStatic(), systemImage: "bolt.horizontal")
                            } description: {
                                Text("No quota providers available.".localizedStatic())
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, UITokens.Spacing.lg)
                        } else {
                            ForEach(providers, id: \.self) { provider in
                                ProviderQuotaCard(
                                    provider: provider,
                                    snapshot: viewModel.snapshots[provider],
                                    providerSnapshot: viewModel.providerSnapshots[provider]
                                )
                                .id(provider)
                            }
                        }
                    }
                    .padding(UITokens.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: selectedProvider) { _, newValue in
                    withAnimation(UITokens.Animation.transition) {
                        proxy.scrollTo(newValue, anchor: .top)
                    }
                }
            }
        }
        .task {
            await viewModel.loadCached()
            await viewModel.refreshAll()

            let providers = sortedProviders()
            if providers.contains(selectedProvider) == false {
                selectedProvider = providers.first ?? .claude
            }
        }
        .onChange(of: viewModel.isRefreshing) { _, newValue in
            if newValue {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    isSpinningRefresh = true
                }
            } else {
                isSpinningRefresh = false
            }
        }
        .toolbar {
            Button {
                Task { await viewModel.refreshAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(isSpinningRefresh ? 360 : 0))
            }
            .buttonStyle(.toolbarIcon)
            .help("Refresh".localizedStatic())
            .disabled(viewModel.isRefreshing)
        }
        .animation(UITokens.Animation.transition, value: viewModel.lastRefreshAt)
    }

    private func sortedProviders() -> [ProviderID] {
        let supported = ProviderID.allCases.filter(\.descriptor.supportsQuota)
        return supported.sorted { lhs, rhs in
            let lhsCount = viewModel.providerSnapshots[lhs]?.accounts.count ?? 0
            let rhsCount = viewModel.providerSnapshots[rhs]?.accounts.count ?? 0

            if lhsCount > 0, rhsCount == 0 { return true }
            if lhsCount == 0, rhsCount > 0 { return false }

            if lhsCount != rhsCount { return lhsCount > rhsCount }

            return lhs.displayName < rhs.displayName
        }
    }

    private var countsByProvider: [ProviderID: Int] {
        Dictionary(uniqueKeysWithValues: sortedProviders().map { provider in
            let count = viewModel.providerSnapshots[provider]?.accounts.count ?? 0
            return (provider, count)
        })
    }

    private var quotaSummary: QuotaSummary {
        var total = 0
        var ok = 0
        var warn = 0
        var error = 0

        for provider in ProviderID.allCases where provider.descriptor.supportsQuota {
            guard let accounts = viewModel.providerSnapshots[provider]?.accounts.values else { continue }
            for account in accounts {
                total += 1
                switch account.kind {
                case .ok:
                    ok += 1
                case .error:
                    error += 1
                case .authMissing, .unsupported, .loading:
                    warn += 1
                }
            }
        }

        return QuotaSummary(total: total, ok: ok, warn: warn, error: error)
    }
}

private struct QuotaSummary: Hashable, Sendable {
    let total: Int
    let ok: Int
    let warn: Int
    let error: Int
}

private struct TopHeader: View {
    @Binding var selectedProvider: ProviderID
    let providers: [ProviderID]
    let countsByProvider: [ProviderID: Int]
    let summary: QuotaSummary
    let lastRefreshAt: Date?

    var body: some View {
        VStack(spacing: UITokens.Spacing.sm) {
            QuotaSegmentedTabBar(
                selected: $selectedProvider,
                providers: providers,
                countsByProvider: countsByProvider,
                lastRefreshAt: lastRefreshAt
            )

            QuotaSummaryBar(summary: summary)
        }
        .padding(.horizontal, UITokens.Spacing.md)
        .padding(.top, UITokens.Spacing.sm)
        .padding(.bottom, UITokens.Spacing.md)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct QuotaSummaryBar: View {
    let summary: QuotaSummary

    var body: some View {
        HStack(spacing: UITokens.Spacing.md) {
            SummaryChip(icon: "person.2.fill", title: "Accounts".localizedStatic(), value: summary.total, tint: .blue)
            SummaryChip(icon: "checkmark.circle.fill", title: "OK".localizedStatic(), value: summary.ok, tint: .green)
            SummaryChip(icon: "exclamationmark.triangle.fill", title: "Warn".localizedStatic(), value: summary.warn, tint: .orange)
            SummaryChip(icon: "xmark.octagon.fill", title: "Error".localizedStatic(), value: summary.error, tint: .red)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, UITokens.Spacing.md)
        .padding(.vertical, UITokens.Spacing.sm)
        .background(
            LinearGradient(
                colors: [
                    Color.primary.opacity(0.06),
                    Color.primary.opacity(0.02),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: UITokens.Radius.medium)
        )
        .overlay(
            RoundedRectangle(cornerRadius: UITokens.Radius.medium)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct SummaryChip: View {
    let icon: String
    let title: String
    let value: Int
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(tint)

            Text("\(value)")
                .font(.dinBold(size: 14))
                .foregroundStyle(.primary)
                .monospacedDigit()

            Text(title)
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct QuotaSegmentedTabBar: View {
    @Binding var selected: ProviderID
    let providers: [ProviderID]
    let countsByProvider: [ProviderID: Int]
    let lastRefreshAt: Date?

    var body: some View {
        HStack(spacing: UITokens.Spacing.md) {
            HStack(spacing: 0) {
                ForEach(providers, id: \.self) { provider in
                    QuotaSegmentItem(
                        provider: provider,
                        count: countsByProvider[provider] ?? 0,
                        isSelected: selected == provider
                    ) {
                        withAnimation(UITokens.Animation.transition) {
                            selected = provider
                        }
                    }
                }
            }
            .padding(4)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )

            Spacer(minLength: 0)

            if let lastRefreshAt {
                Text(Self.formatTime(lastRefreshAt))
                    .font(.dinNumber(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("—")
                    .font(.dinNumber(.caption))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private struct QuotaSegmentItem: View {
    let provider: ProviderID
    let count: Int
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                ProviderIcon(provider, size: 16)

                Text(provider.displayName)
                    .font(.system(.caption, design: .rounded))
                    .fontWeight(.medium)
                    .foregroundStyle(isSelected ? .primary : .secondary)

                ZStack {
                    Circle()
                        .fill(Color.secondary.opacity(0.18))
                        .frame(width: 16, height: 16)
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(minHeight: 30)
            .frame(maxWidth: .infinity)
            .background(background)
            .overlay(overlay)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(UITokens.Animation.hover) {
                isHovering = hovering
            }
        }
        .help(provider.displayName)
    }

    private var background: some ShapeStyle {
        if isSelected {
            return provider.tintColor.opacity(0.22)
        }
        if isHovering {
            return Color.primary.opacity(0.05)
        }
        return Color.clear
    }

    private var overlay: some View {
        Capsule()
            .strokeBorder(isSelected ? provider.tintColor.opacity(0.35) : Color.clear, lineWidth: 1)
    }
}

private struct ProviderQuotaCard: View {
    let provider: ProviderID
    let snapshot: QuotaSnapshot?
    let providerSnapshot: ProviderQuotaSnapshot?

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: UITokens.Spacing.md) {
            header

            if let accounts = sortedAccounts, accounts.isEmpty == false {
                VStack(alignment: .leading, spacing: UITokens.Spacing.sm) {
                    ForEach(accounts) { account in
                        AccountQuotaCard(provider: provider, account: account)
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("No Accounts".localizedStatic(), systemImage: "person.crop.circle.badge.exclamationmark")
                } description: {
                    Text("Add OAuth files under ~/.cli-proxy-api to see quota.".localizedStatic())
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, UITokens.Spacing.sm)
            }
        }
        .padding(UITokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: UITokens.Radius.large))
        .overlay(tintOverlay)
        .overlay(
            RoundedRectangle(cornerRadius: UITokens.Radius.large)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(isHovering ? 0.10 : 0), radius: 8, x: 0, y: 4)
        .onHover { hovering in
            withAnimation(UITokens.Animation.hover) {
                isHovering = hovering
            }
        }
    }

    private var kind: QuotaSnapshotKind {
        snapshot?.kind ?? .loading
    }

    private var statusText: String {
        switch kind {
        case .ok: "OK".localizedStatic()
        case .authMissing: "Auth missing".localizedStatic()
        case .unsupported: "Unsupported".localizedStatic()
        case .error: "Error".localizedStatic()
        case .loading: "Loading".localizedStatic()
        }
    }

    private var statusType: StatusType {
        switch kind {
        case .ok:
            return .success
        case .authMissing:
            return .warning
        case .unsupported:
            return .neutral
        case .error:
            return .error
        case .loading:
            return .neutral
        }
    }

    private var header: some View {
        HStack(spacing: UITokens.Spacing.sm) {
            ProviderIcon(provider, size: 32)

            Text(provider.displayName)
                .font(.headline)

            Spacer()

            Text("\(providerSnapshot?.accounts.count ?? 0)")
                .font(.dinBold(size: 14))
                .foregroundStyle(.secondary)

            Circle()
                .fill(providerStatusColor)
                .frame(width: 8, height: 8)

            StatusBadge(text: statusText, status: statusType)
        }
    }

    private var providerStatusColor: Color {
        if let accounts = providerSnapshot?.accounts.values, accounts.isEmpty == false {
            if accounts.contains(where: { $0.kind == .error }) { return .red }
            if accounts.contains(where: { $0.kind != .ok }) { return .orange }
            return .green
        }
        switch kind {
        case .error:
            return .red
        case .authMissing:
            return .orange
        case .ok:
            return .green
        case .loading, .unsupported:
            return .secondary
        }
    }

    private var tintOverlay: some View {
        LinearGradient(
            colors: [
                provider.tintColor.opacity(0.08),
                provider.tintColor.opacity(0.02),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .clipShape(RoundedRectangle(cornerRadius: UITokens.Radius.large))
    }

    private var sortedAccounts: [AccountQuota]? {
        guard let accounts = providerSnapshot?.accounts else { return nil }
        return accounts.values.sorted { ($0.email ?? $0.accountKey) < ($1.email ?? $1.accountKey) }
    }
}

private struct AccountQuotaCard: View {
    let provider: ProviderID
    let account: AccountQuota
    @State private var animatedPercent: Double = 0
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: UITokens.Spacing.sm) {
            HStack(spacing: UITokens.Spacing.sm) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                Text(account.email ?? account.accountKey)
                    .font(.system(.body, design: .rounded))
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                StatusBadge(text: statusText, status: statusType)
            }

            if let progressMetrics {
                HStack(spacing: 10) {
                    ProgressView(value: animatedPercent)
                        .progressViewStyle(.linear)
                        .tint(provider.tintColor)
                        .animation(.smooth(duration: 0.3), value: animatedPercent)

                    Text("\(Int(round(animatedPercent * 100)))%")
                        .font(.dinBold(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                Text(progressMetrics.detailLine)
                    .font(.dinNumber(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if let message = account.message ?? account.error {
                Text(message)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(isHovering ? 0.04 : 0.02), in: RoundedRectangle(cornerRadius: UITokens.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: UITokens.Radius.medium)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(UITokens.Animation.hover) {
                isHovering = hovering
            }
        }
        .onAppear {
            animatedPercent = 0
            guard let percent else { return }
            withAnimation(.smooth(duration: 0.3)) {
                animatedPercent = percent
            }
        }
        .onChange(of: percent) { _, newValue in
            guard let newValue else { return }
            withAnimation(.smooth(duration: 0.3)) {
                animatedPercent = newValue
            }
        }
    }

    private var statusText: String {
        switch account.kind {
        case .ok: "OK".localizedStatic()
        case .authMissing: "Auth missing".localizedStatic()
        case .unsupported: "Unsupported".localizedStatic()
        case .error: "Error".localizedStatic()
        case .loading: "Loading".localizedStatic()
        }
    }

    private var statusColor: Color {
        switch account.kind {
        case .ok: .green
        case .loading: .secondary
        case .unsupported: .secondary
        case .authMissing: .orange
        case .error: .red
        }
    }

    private var statusType: StatusType {
        switch account.kind {
        case .ok: .success
        case .authMissing: .warning
        case .unsupported: .neutral
        case .error: .error
        case .loading: .neutral
        }
    }

    private struct ProgressMetrics {
        let percent: Double
        let detailLine: String
    }

    private var progressMetrics: ProgressMetrics? {
        guard account.kind == .ok, let metrics = account.quota else { return nil }
        guard let used = metrics.used, let limit = metrics.limit, limit > 0 else { return nil }

        let percent = min(max(Double(used) / Double(limit), 0), 1)

        let resetText: String
        if let resetAt = metrics.resetAt {
            resetText = String(format: "• Resets %@".localizedStatic(), formatRelative(resetAt))
        } else {
            resetText = ""
        }

        let base = String(format: "Used: %@ / Limit: %@".localizedStatic(), String(used), String(limit))
        let detail = resetText.isEmpty ? base : "\(base) \(resetText)"

        return ProgressMetrics(percent: percent, detailLine: detail)
    }

    private var percent: Double? {
        progressMetrics?.percent
    }

    private func formatRelative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
