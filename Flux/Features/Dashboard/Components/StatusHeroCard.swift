import SwiftUI

struct StatusHeroCard: View {
    let coreState: CoreRuntimeState
    let coreVersion: String?
    let coreStartedAt: Date?
    let isRefreshing: Bool
    let quotaProvidersCount: Int
    let credentialsAvailableCount: Int
    let quotaOKCount: Int
    let lastRefreshAt: Date?
    let onToggleCore: () -> Void

    @State private var pulse = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("AI coding assistant control center".localizedStatic())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        statusIndicator
                        Text(coreStatusTitle)
                            .font(.system(.title3, design: .rounded))
                            .fontWeight(.semibold)

                        if isRefreshing {
                            SmallProgressView()
                                .frame(width: 14, height: 14)
                        }
                    }

                    Text(coreState.shortDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        Text(versionText)
                            .font(.dinNumber(.caption))

                        Text("•")
                            .foregroundStyle(.tertiary)

                        uptimeView
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    onToggleCore()
                } label: {
                    Image(systemName: toggleSystemImage)
                }
                .buttonStyle(.toolbarIcon)
                .help(toggleHelp)
                .disabled(isBusy)
            }

            HStack(spacing: 12) {
                heroStat(title: "Quota Providers".localizedStatic(), value: "\(quotaProvidersCount)")
                heroStat(title: "Credentials Ready".localizedStatic(), value: "\(credentialsAvailableCount)")
                heroStat(title: "Quota OK".localizedStatic(), value: "\(quotaOKCount)")
                Spacer()
                Text(lastRefreshAt.map(Self.formatTime) ?? "—")
                    .font(.dinNumber(.caption))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(UITokens.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: UITokens.Radius.large))
        .overlay(
            RoundedRectangle(cornerRadius: UITokens.Radius.large)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(isHovering ? 0.10 : 0), radius: 6, x: 0, y: 3)
        .onHover { hovering in
            withAnimation(UITokens.Animation.hover) {
                isHovering = hovering
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                pulse.toggle()
            }
        }
    }

    private static func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private var isBusy: Bool {
        switch coreState {
        case .starting, .stopping:
            return true
        default:
            return false
        }
    }

    private var coreStatusTitle: String {
        switch coreState {
        case .running:
            return "Core Running".localizedStatic()
        case .starting:
            return "Starting…".localizedStatic()
        case .stopping:
            return "Stopping…".localizedStatic()
        case .stopped:
            return "Core Stopped".localizedStatic()
        case .notInstalled:
            return "Core Not Installed".localizedStatic()
        case .crashed:
            return "Core Crashed".localizedStatic()
        case .error:
            return "Core Error".localizedStatic()
        }
    }

    private var toggleSystemImage: String {
        if coreState.isRunning { return "stop.fill" }
        return "play.fill"
    }

    private var toggleHelp: String {
        if coreState.isRunning { return "Stop Core".localizedStatic() }
        return "Start Core".localizedStatic()
    }

    private var versionText: String {
        guard let coreVersion, !coreVersion.isEmpty else {
            return "Core v—".localizedStatic()
        }
        return "Core v\(coreVersion)".localizedStatic()
    }

    @ViewBuilder
    private var uptimeView: some View {
        if coreState.isRunning, let coreStartedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("Uptime \(formatDuration(context.date.timeIntervalSince(coreStartedAt)))".localizedStatic())
                    .font(.dinNumber(.caption))
            }
        } else {
            Text("Uptime —".localizedStatic())
                .font(.dinNumber(.caption))
        }
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }

    private var statusIndicator: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 12, height: 12)
            .shadow(color: statusColor.opacity(0.6), radius: pulse ? 8 : 2)
            .scaleEffect(pulse ? 1.2 : 1.0)
    }

    private var statusColor: Color {
        switch coreState {
        case .running:
            return .green
        case .starting, .stopping:
            return .orange
        case .stopped, .notInstalled:
            return .red
        case .crashed, .error:
            return .red
        }
    }

    private var background: some View {
        let highlight = statusColor.opacity(0.22)
        let base = Color(nsColor: .controlBackgroundColor)
        return LinearGradient(
            colors: [highlight, base.opacity(0.98), base],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func heroStat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.dinNumber(.headline))
        }
        .frame(minWidth: 90, alignment: .leading)
    }
}
