import SwiftUI

struct QuotaView: View {
    let viewModel: QuotaViewModel
    @State private var selectedProvider: ProviderID = .codex
    @State private var isProgrammaticScroll = false

    init(viewModel: QuotaViewModel = QuotaViewModel()) {
        self.viewModel = viewModel
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                QuotaAnchorTabBar(
                    selected: $selectedProvider,
                    providers: providers,
                    badges: tabBadges,
                    onSelect: { provider in
                        isProgrammaticScroll = true
                        withAnimation(UITokens.Animation.transition) {
                            selectedProvider = provider
                            proxy.scrollTo(provider, anchor: .top)
                        }
                        Task {
                            try? await Task.sleep(nanoseconds: 350_000_000)
                            isProgrammaticScroll = false
                        }
                    }
                )
                .zIndex(1)

                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: UITokens.Spacing.xl, pinnedViews: [.sectionHeaders]) {
                        if hasAnyAccounts == false {
                            QuotaEmptyState()
                                .frame(maxWidth: .infinity)
                                .padding(.top, UITokens.Spacing.xxl)
                        } else {
                            ForEach(providers, id: \.self) { provider in
                                Section {
                                    ProviderSectionContent(
                                        provider: provider,
                                        providerSnapshot: viewModel.providerSnapshots[provider],
                                        isRefreshingProvider: viewModel.isRefreshingAll || viewModel.refreshingProviders.contains(provider),
                                        onRefreshProvider: {
                                            Task { await viewModel.refreshProvider(provider, force: true) }
                                        },
                                        onRefreshAccount: { accountKey in
                                            Task { await viewModel.refreshAccount(provider, accountKey: accountKey) }
                                        },
                                        isRefreshingAccount: { accountKey in
                                            viewModel.isRefreshingAccount(provider, accountKey)
                                        }
                                    )
                                    .padding(.horizontal, UITokens.Spacing.lg)
                                    .padding(.bottom, UITokens.Spacing.lg)
                                } header: {
                                    ProviderSectionHeader(
                                        provider: provider,
                                        providerSnapshot: viewModel.providerSnapshots[provider],
                                    )
                                    .id(provider)
                                    .background(ProviderHeaderOffsetReader(provider: provider))
                                }
                            }
                        }
                    }
                    .padding(.vertical, UITokens.Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .coordinateSpace(name: ProviderHeaderOffsetReader.coordinateSpaceName)
                .onPreferenceChange(ProviderHeaderOffsetKey.self) { offsets in
                    guard isProgrammaticScroll == false else { return }
                    guard let next = ProviderHeaderOffsetReader.closestToTop(offsets: offsets, providers: providers) else { return }
                    guard next != selectedProvider else { return }
                    selectedProvider = next
                }
            }
        }
        .task {
            await viewModel.loadCached()
            await viewModel.refreshAll()

            if providers.contains(selectedProvider) == false { selectedProvider = providers.first ?? .codex }
        }
        .toolbar {
            Button {
                Task { await viewModel.refreshAll(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .symbolEffect(.rotate, options: .repeat(.continuous), isActive: viewModel.isRefreshingAll)
            }
            .buttonStyle(.toolbarIcon)
            .help("Refresh".localizedStatic())
            .disabled(viewModel.isRefreshingAny)
        }
        .animation(UITokens.Animation.transition, value: viewModel.lastRefreshAt)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var providers: [ProviderID] {
        sortedProviders()
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

    private var hasAnyAccounts: Bool {
        providers.contains { provider in
            (viewModel.providerSnapshots[provider]?.accounts.isEmpty == false)
        }
    }
    private var tabBadges: [ProviderID: QuotaTabBadge] {
        Dictionary(uniqueKeysWithValues: providers.map { provider in
            let accountsDict = viewModel.providerSnapshots[provider]?.accounts ?? [:]
            let accounts = Array(accountsDict.values)
            let count = accounts.count
            let hasIssues = accounts.contains { account in
                switch account.kind {
                case .ok, .loading:
                    return false
                case .authMissing, .unsupported, .error:
                    return true
                }
            }
            return (provider, QuotaTabBadge(count: count, hasIssues: hasIssues))
        })
    }
}

private struct QuotaTabBadge: Hashable, Sendable {
    let count: Int
    let hasIssues: Bool
}

// MARK: - Navigation Bar

private struct QuotaAnchorTabBar: View {
    @Binding var selected: ProviderID
    let providers: [ProviderID]
    let badges: [ProviderID: QuotaTabBadge]
    let onSelect: (ProviderID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(providers, id: \.self) { provider in
                    QuotaAnchorPill(
                        provider: provider,
                        badge: badges[provider] ?? QuotaTabBadge(count: 0, hasIssues: false),
                        isSelected: selected == provider
                    ) {
                        onSelect(provider)
                    }
                }
            }
            .padding(.horizontal, UITokens.Spacing.lg)
            .padding(.vertical, UITokens.Spacing.md)
        }
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct QuotaAnchorPill: View {
    let provider: ProviderID
    let badge: QuotaTabBadge
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                ProviderIcon(provider, size: 16)
                    .grayscale(isSelected ? 0 : 1)
                    .opacity(isSelected ? 1 : 0.7)

                Text(provider.displayName)
                    .font(.system(.subheadline, design: .rounded))
                    .fontWeight(isSelected ? .semibold : .medium)
                    .foregroundStyle(isSelected ? .primary : .secondary)

                if badge.count > 0 {
                    Text("\(badge.count)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(isSelected ? .white : .secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(isSelected ? provider.tintColor : Color.secondary.opacity(0.15))
                        )
                }
                
                if badge.hasIssues {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(background)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var background: some View {
        Capsule()
            .fill(isSelected ? Color.secondary.opacity(0.1) : (isHovering ? Color.secondary.opacity(0.05) : Color.clear))
    }
}

// MARK: - Section Header

private struct ProviderSectionHeader: View {
    let provider: ProviderID
    let providerSnapshot: ProviderQuotaSnapshot?

    var body: some View {
        HStack(spacing: UITokens.Spacing.sm) {
            ProviderIcon(provider, size: 24)
            
            Text(provider.displayName)
                .font(.title3)
                .fontWeight(.bold)
                .foregroundStyle(.primary)

            Spacer()

            if stats.active > 0 || stats.warn > 0 || stats.error > 0 {
                HStack(spacing: 4) {
                    if stats.error > 0 {
                        StatusDot(color: .red, count: stats.error)
                    }
                    if stats.warn > 0 {
                        StatusDot(color: .orange, count: stats.warn)
                    }
                    if stats.active > 0 {
                        StatusDot(color: .green, count: stats.active)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule())
            }
        }
        .padding(.horizontal, UITokens.Spacing.lg)
        .padding(.vertical, UITokens.Spacing.md)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.95)
        )
        .overlay(alignment: .bottom) {
            Divider().opacity(0.5)
        }
    }

    private var stats: ProviderStats {
        let accounts = Array((providerSnapshot?.accounts ?? [:]).values)
        let active = accounts.filter { $0.kind == .ok }.count
        let warn = accounts.filter { $0.kind != .ok && $0.kind != .error && $0.kind != .loading }.count
        let err = accounts.filter { $0.kind == .error }.count
        return ProviderStats(active: active, warn: warn, error: err)
    }
}

private struct StatusDot: View {
    let color: Color
    let count: Int
    
    var body: some View {
        HStack(spacing: 2) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(count)")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

private struct ProviderStats: Hashable, Sendable {
    let active: Int
    let warn: Int
    let error: Int
}

// MARK: - Content

private struct ProviderSectionContent: View {
    let provider: ProviderID
    let providerSnapshot: ProviderQuotaSnapshot?
    let isRefreshingProvider: Bool
    let onRefreshProvider: () -> Void
    let onRefreshAccount: (String) -> Void
    let isRefreshingAccount: (String) -> Bool

    var body: some View {
        let accounts = sortedAccounts
        if accounts.isEmpty {
            DashedProviderEmptyBox(provider: provider)
        } else {
            VStack(spacing: UITokens.Spacing.md) {
                ForEach(accounts) { account in
                    AccountBentoCard(
                        provider: provider,
                        account: account,
                        isRefreshing: isRefreshingProvider || isRefreshingAccount(account.accountKey),
                        onRefresh: { onRefreshAccount(account.accountKey) }
                    )
                }
            }
        }
    }

    private var sortedAccounts: [AccountQuota] {
        let accounts = Array((providerSnapshot?.accounts ?? [:]).values)
        return accounts.sorted { ($0.email ?? $0.accountKey) < ($1.email ?? $1.accountKey) }
    }
}

private struct DashedProviderEmptyBox: View {
    let provider: ProviderID

    var body: some View {
        HStack(spacing: UITokens.Spacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title3)
                .foregroundStyle(.secondary)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("No auth files found".localizedStatic())
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text("Add OAuth JSON files under ~/.cli-proxy-api/ to enable quota fetching.".localizedStatic())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: UITokens.Radius.medium)
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(.secondary.opacity(0.3))
        )
    }
}

private struct AccountBentoCard: View {
    let provider: ProviderID
    let account: AccountQuota
    let isRefreshing: Bool
    let onRefresh: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if let planType = account.planType, planType != .unknown {
                HStack(spacing: 6) {
                    Text("Plan".localizedStatic())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(planType.displayName)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            if account.modelQuotas.isEmpty {
                simpleQuotaSummary
            } else {
                VStack(spacing: 6) {
                    ForEach(account.modelQuotas) { quota in
                        ModelQuotaRow(quota: quota)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: UITokens.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: UITokens.Radius.medium)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if isHovering {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing)
                .transition(.opacity)
            }
        }
        .animation(UITokens.Animation.hover, value: isHovering)
        .onHover { isHovering = $0 }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ProviderBadge(provider: provider)

            Text(account.email ?? account.accountKey)
                .font(.system(.subheadline, design: .rounded))
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.primary)

            if account.kind != .ok {
                StatusBadgeSmall(status: statusType)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, account.planType == nil || account.planType == .unknown ? 12 : 8)
    }

    private var simpleQuotaSummary: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: UITokens.Spacing.lg) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("OAuth Account")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 4) {
                    if let used = account.quota?.used, let limit = account.quota?.limit {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text("\(used)")
                                .fontWeight(.semibold)
                                .foregroundStyle(usageColor)
                            Text("/")
                                .foregroundStyle(.tertiary)
                            Text("\(limit)")
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(.callout, design: .monospaced))
                    } else {
                        Text("—")
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }

                    if let resetAt = account.quota?.resetAt {
                        Text(resetCountdownText(resetAt))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.1))

                    if let p = percent {
                        Rectangle()
                            .fill(usageColor)
                            .frame(width: geo.size.width * p)
                    }
                }
            }
            .frame(height: 3)
        }
    }

    private var percent: Double? {
        guard let quota = account.quota else { return nil }
        if let used = quota.used, let limit = quota.limit, limit > 0 {
            return min(max(Double(used) / Double(limit), 0), 1)
        }
        if let remaining = quota.remaining, let limit = quota.limit, limit > 0 {
            return min(max(1 - Double(remaining) / Double(limit), 0), 1)
        }
        return nil
    }

    private var usageColor: Color {
        let p = percent ?? 0
        if p < 0.70 { return .green }
        if p < 0.90 { return .orange }
        return .red
    }

    private var statusType: StatusType {
        switch account.kind {
        case .ok: return .success
        case .authMissing, .unsupported: return .warning
        case .error: return .error
        case .loading: return .neutral
        }
    }
    
    private func resetCountdownText(_ date: Date) -> String {
        let interval = max(0, date.timeIntervalSinceNow)
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1
        if interval >= 60 * 60 * 24 {
            formatter.allowedUnits = [.day]
        } else if interval >= 60 * 60 {
            formatter.allowedUnits = [.hour]
        } else {
            formatter.allowedUnits = [.minute]
        }

        let delta = formatter.string(from: interval) ?? "—"
        return String(format: "Resets in %@".localizedStatic(), delta)
    }
}

private struct ProviderBadge: View {
    let provider: ProviderID

    var body: some View {
        Text(provider.displayName)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(provider.tintColor, in: RoundedRectangle(cornerRadius: 4))
    }
}

private struct ModelQuotaRow: View {
    let quota: ModelQuota

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(quota.displayName)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Text("\(Int(quota.remainingPercent.rounded()))%")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(usageColor)
                    .monospacedDigit()

                if let resetAt = quota.resetAt {
                    Text(Self.resetTimeFormatter.string(from: resetAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            GeometryReader { geo in
                let fraction = max(0, min(1, quota.remainingPercent / 100))
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.secondary.opacity(0.1))
                    Rectangle()
                        .fill(usageColor)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 3)
        }
    }

    private var usageColor: Color {
        let remaining = quota.remainingPercent
        if remaining > 30 { return .green }
        if remaining > 10 { return .orange }
        return .red
    }

    private static let resetTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter
    }()
}

private struct StatusBadgeSmall: View {
    let status: StatusType
    
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
    }
    
    var color: Color {
        switch status {
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        case .neutral: return .secondary
        case .active: return .green
        }
    }
}

// MARK: - Helpers

private struct ProviderHeaderOffsetKey: PreferenceKey {
    static let defaultValue: [ProviderID: CGFloat] = [:]
    static func reduce(value: inout [ProviderID: CGFloat], nextValue: () -> [ProviderID: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct ProviderHeaderOffsetReader: View {
    static let coordinateSpaceName = "quotaScroll"
    let provider: ProviderID
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: ProviderHeaderOffsetKey.self,
                value: [provider: proxy.frame(in: .named(Self.coordinateSpaceName)).minY]
            )
        }.frame(height: 0)
    }
    static func closestToTop(offsets: [ProviderID: CGFloat], providers: [ProviderID]) -> ProviderID? {
        providers.compactMap { p in offsets[p].map { (p, $0) } }
            .min(by: { abs($0.1) < abs($1.1) })?.0
    }
}

private struct QuotaEmptyState: View {
    var body: some View {
        ContentUnavailableView {
            Label("No quotas found".localizedStatic(), systemImage: "chart.pie")
        } description: {
            Text("No OAuth auth files were detected under ~/.cli-proxy-api.".localizedStatic())
        } actions: {
            Button("Go to Settings".localizedStatic()) {
                FluxNavigation.navigate(to: .settings)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
