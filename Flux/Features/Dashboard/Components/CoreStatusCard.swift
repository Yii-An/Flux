import SwiftUI

struct CoreStatusCard: View {
    let coreState: CoreRuntimeState
    let coreVersion: String?
    let coreStartedAt: Date?
    let corePort: UInt16
    let isRefreshing: Bool
    let onToggleCore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text("Core Status".localizedStatic())
                    .font(.headline)

                Spacer()

                if isRefreshing {
                    SmallProgressView()
                        .frame(width: 14, height: 14)
                }

                Button {
                    onToggleCore()
                } label: {
                    Image(systemName: coreState.isRunning ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isBusy)
                .help(coreState.isRunning ? "Stop Core".localizedStatic() : "Start Core".localizedStatic())
            }

            HStack(spacing: UITokens.Spacing.md) {
                uptimeColumn
                BigNumberView(
                    title: "Version".localizedStatic(),
                    value: coreVersion ?? "—",
                    tint: statusColor
                )
                BigNumberView(
                    title: "Port".localizedStatic(),
                    value: String(corePort),
                    tint: statusColor
                )
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                Text(coreState.shortDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(statusColor.opacity(0.08), in: RoundedRectangle(cornerRadius: UITokens.Radius.small))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fluxCardStyle()
    }

    private var isBusy: Bool {
        switch coreState {
        case .starting, .stopping:
            return true
        default:
            return false
        }
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

    @ViewBuilder
    private var uptimeColumn: some View {
        if coreState.isRunning, let coreStartedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                BigNumberView(
                    title: "Uptime".localizedStatic(),
                    value: formatDuration(context.date.timeIntervalSince(coreStartedAt)),
                    tint: statusColor
                )
            }
        } else {
            BigNumberView(
                title: "Uptime".localizedStatic(),
                value: "—",
                tint: statusColor
            )
        }
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
}

