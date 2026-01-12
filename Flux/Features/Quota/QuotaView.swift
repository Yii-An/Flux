import SwiftUI

struct QuotaView: View {
    @State private var viewModel = QuotaViewModel()
    @State private var selectedProvider: ProviderID = .claude
    @State private var isSpinningRefresh = false
    @State private var isProgrammaticScroll = false

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

                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: UITokens.Spacing.md, pinnedViews: [.sectionHeaders]) {
                        if hasAnyAccounts == false {
                            QuotaEmptyState()
                                .frame(maxWidth: .infinity)
                                .padding(.top, UITokens.Spacing.lg)
                        } else {
                            ForEach(providers, id: \.self) { provider in
                                Section {
                                    ProviderSectionContent(
                                        provider: provider,
                                        providerSnapshot: viewModel.providerSnapshots[provider],
                                        onRefresh: {
                                            Task { await viewModel.refreshAll() }
                                        }
                                    )
                                } header: {
                                    ProviderSectionHeader(
                                        provider: provider,
                                        providerSnapshot: viewModel.providerSnapshots[provider],
                                        snapshot: viewModel.snapshots[provider]
                                    )
                                    .id(provider)
                                    .background(ProviderHeaderOffsetReader(provider: provider))
                                }
                            }
                        }
                    }
                    .padding(UITokens.Spacing.md)
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

            if providers.contains(selectedProvider) == false { selectedProvider = providers.first ?? .claude }
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

private struct QuotaAnchorTabBar: View {
    @Binding var selected: ProviderID
    let providers: [ProviderID]
    let badges: [ProviderID: QuotaTabBadge]
    let onSelect: (ProviderID) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(providers, id: \.self) { provider in
                QuotaAnchorPill(
                    provider: provider,
                    badge: badges[provider] ?? QuotaTabBadge(count: 0, hasIssues: false),
                    isSelected: selected == provider
                ) {
                    onSelect(provider)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, UITokens.Spacing.md)
        .padding(.vertical, UITokens.Spacing.sm)
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
            HStack(spacing: 8) {
                ProviderIcon(provider, size: 18)
                    .opacity(isSelected ? 1 : 0.65)

                Text(provider.displayName)
                    .font(.system(.caption, design: .rounded))
                    .fontWeight(.semibold)
                    .foregroundStyle(isSelected ? provider.tintColor : .secondary)

                badgeDot(count: badge.count)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
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
        .overlay(alignment: .topTrailing) {
            if badge.hasIssues {
                Circle()
                    .fill(Color.red)
                    .frame(width: 7, height: 7)
                    .offset(x: 2, y: -2)
            }
        }
    }

    private func badgeDot(count: Int) -> some View {
        ZStack {
            Circle()
                .fill(Color.secondary.opacity(0.18))
                .frame(width: 16, height: 16)
            Text("\(count)")
                .font(.dinBold(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var background: some ShapeStyle {
        if isSelected {
            return provider.tintColor.opacity(0.14)
        }
        if isHovering {
            return Color.primary.opacity(0.05)
        }
        return Color.clear
    }

    private var overlay: some View {
        Capsule()
            .strokeBorder(isSelected ? provider.tintColor.opacity(0.25) : Color.primary.opacity(0.08), lineWidth: 1)
    }
}

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
            Color.clear
                .preference(
                    key: ProviderHeaderOffsetKey.self,
                    value: [provider: proxy.frame(in: .named(Self.coordinateSpaceName)).minY]
                )
        }
        .frame(height: 0)
    }

    static func closestToTop(offsets: [ProviderID: CGFloat], providers: [ProviderID]) -> ProviderID? {
        let pairs = providers.compactMap { provider -> (ProviderID, CGFloat)? in
            guard let value = offsets[provider] else { return nil }
            return (provider, value)
        }
        return pairs.min(by: { abs($0.1) < abs($1.1) })?.0
    }
}

private struct ProviderSectionHeader: View {
    let provider: ProviderID
    let providerSnapshot: ProviderQuotaSnapshot?
    let snapshot: QuotaSnapshot?

    var body: some View {
        HStack(spacing: UITokens.Spacing.md) {
            ProviderIcon(provider, size: 32)

            Text(provider.displayName)
                .font(.system(.title2, design: .rounded))
                .fontWeight(.bold)

            Spacer(minLength: 0)

            ProviderHeaderBadge(provider: provider, stats: stats)
        }
        .padding(.horizontal, UITokens.Spacing.md)
        .padding(.vertical, UITokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private var stats: ProviderStats {
        let accounts = Array((providerSnapshot?.accounts ?? [:]).values)
        let active = accounts.filter { $0.kind == .ok }.count
        let warn = accounts.filter { $0.kind != .ok && $0.kind != .error && $0.kind != .loading }.count
        let err = accounts.filter { $0.kind == .error }.count
        let fallbackKind = snapshot?.kind ?? .loading
        return ProviderStats(active: active, warn: warn, error: err, fallbackKind: fallbackKind)
    }
}

private struct ProviderStats: Hashable, Sendable {
    let active: Int
    let warn: Int
    let error: Int
    let fallbackKind: QuotaSnapshotKind
}

private struct ProviderHeaderBadge: View {
    let provider: ProviderID
    let stats: ProviderStats

    var body: some View {
        HStack(spacing: 6) {
            if stats.active == 0, stats.warn == 0, stats.error == 0 {
                Text("No Accounts".localizedStatic())
                    .font(.system(.caption, design: .rounded))
                    .fontWeight(.medium)
            } else {
                badgePiece(value: stats.active, label: "Active".localizedStatic())

                if stats.warn > 0 {
                    separatorDot
                    badgePiece(value: stats.warn, label: "Warning".localizedStatic())
                }

                if stats.error > 0 {
                    separatorDot
                    badgePiece(value: stats.error, label: "Error".localizedStatic())
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(badgeColor.opacity(0.15)))
        .foregroundStyle(badgeColor)
    }

    private func badgePiece(value: Int, label: String) -> some View {
        HStack(spacing: 4) {
            Text("\(value)")
                .font(.dinNumber(.caption))
                .monospacedDigit()
            Text(label)
                .font(.system(.caption, design: .rounded))
                .fontWeight(.medium)
        }
    }

    private var separatorDot: some View {
        Text("·")
            .font(.system(.caption, design: .rounded))
            .foregroundStyle(.tertiary)
    }

    private var badgeColor: Color {
        if stats.error > 0 { return .red }
        if stats.warn > 0 { return .orange }
        if stats.active > 0 { return .green }
        switch stats.fallbackKind {
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
}

private struct ProviderSectionContent: View {
    let provider: ProviderID
    let providerSnapshot: ProviderQuotaSnapshot?
    let onRefresh: () -> Void

    var body: some View {
        let accounts = sortedAccounts
        if accounts.isEmpty {
            DashedProviderEmptyBox(provider: provider)
        } else {
            VStack(spacing: UITokens.Spacing.sm) {
                ForEach(accounts) { account in
                    AccountBentoCard(provider: provider, account: account, onRefresh: onRefresh)
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
        VStack(alignment: .leading, spacing: UITokens.Spacing.sm) {
            Text("No auth files found for this provider.".localizedStatic())
                .font(.system(.body, design: .rounded))
                .fontWeight(.semibold)

            Text("Add OAuth JSON files under ~/.cli-proxy-api/ to enable quota fetching.".localizedStatic())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(UITokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: UITokens.Radius.large, style: .continuous)
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                .foregroundStyle(provider.tintColor.opacity(0.35))
        )
    }
}

private struct AccountBentoCard: View {
    let provider: ProviderID
    let account: AccountQuota
    let onRefresh: () -> Void

    @State private var isHovering = false
    @State private var animatedPercent: Double = 0

    var body: some View {
        HStack(spacing: UITokens.Spacing.lg) {
            identityColumn
                .frame(maxWidth: .infinity, alignment: .leading)

            usageColumn
                .frame(maxWidth: .infinity, alignment: .leading)

            statusColumn
                .frame(width: 160, alignment: .trailing)
        }
        .padding(UITokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 100)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: UITokens.Radius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: UITokens.Radius.large, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(isHovering ? 0.10 : 0), radius: isHovering ? 10 : 0, x: 0, y: 4)
        .scaleEffect(isHovering ? 1.01 : 1.0)
        .onHover { hovering in
            withAnimation(UITokens.Animation.hover) {
                isHovering = hovering
            }
        }
        .onAppear {
            animatedPercent = 0
            if let percent {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    animatedPercent = percent
                }
            }
        }
        .onChange(of: percent) { _, newValue in
            guard let newValue else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                animatedPercent = newValue
            }
        }
    }

    private var identityColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(account.email ?? account.accountKey)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            Text("OAuth".localizedStatic())
                .font(.system(.caption2, design: .rounded))
                .fontWeight(.medium)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
                .foregroundStyle(.secondary)
        }
    }

    private var usageColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                usedLimitText
                Spacer(minLength: 0)
            }

            ProgressView(value: animatedPercent)
                .progressViewStyle(.linear)
                .tint(usageTintColor)
                .animation(UITokens.Animation.transition, value: animatedPercent)

            if let resetAt = account.quota?.resetAt {
                Text(resetCountdownText(resetAt))
                    .font(.dinNumber(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("—")
                    .font(.dinNumber(.caption))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var statusColumn: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 8) {
                if isHovering {
                    Button {
                        onRefresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.toolbarIcon)
                    .help("Refresh".localizedStatic())
                }

                StatusBadge(text: statusText, status: statusType)
            }

            if let message = account.message ?? account.error, account.kind != .ok {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            } else {
                Spacer()
            }
        }
    }

    private var usedLimitText: some View {
        Group {
            if let used = account.quota?.used, let limit = account.quota?.limit {
                Text("\(used)")
                    .font(.dinBold(size: 18))
                    .contentTransition(.numericText())
                    .monospacedDigit()
                Text("/")
                    .font(.system(.callout, design: .rounded))
                    .foregroundStyle(.tertiary)
                Text("\(limit)")
                    .font(.dinBold(size: 18))
                    .contentTransition(.numericText())
                    .monospacedDigit()
            } else {
                Text("—")
                    .font(.dinBold(size: 18))
                    .foregroundStyle(.secondary)
            }
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

    private var usageTintColor: Color {
        let p = percent ?? 0
        if p < 0.70 { return .green }
        if p < 0.90 { return .orange }
        return .red
    }

    private var statusText: String {
        switch account.kind {
        case .ok: "OK".localizedStatic()
        case .authMissing: "WARN".localizedStatic()
        case .unsupported: "WARN".localizedStatic()
        case .error: "ERR".localizedStatic()
        case .loading: "…".localizedStatic()
        }
    }

    private var statusType: StatusType {
        switch account.kind {
        case .ok:
            return .success
        case .authMissing, .unsupported:
            return .warning
        case .error:
            return .error
        case .loading:
            return .neutral
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
