import SwiftUI
import AppKit

struct CoreHeroCard: View {
    let coreState: CoreRuntimeState
    let coreVersion: String?
    let coreStartedAt: Date?
    let isRefreshing: Bool
    let onToggleCore: () -> Void

    @State private var pulse = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        statusIndicator

                        Text(coreStatusTitle)
                            .font(.system(.title3, design: .rounded))
                            .fontWeight(.semibold)

                        if isRefreshing {
                            SmallProgressView()
                                .frame(width: 16, height: 16)
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
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isBusy)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(isHovering ? 0.12 : 0), radius: 8, x: 0, y: 4)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                pulse.toggle()
            }
        }
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
            .frame(width: 14, height: 14)
            .shadow(color: statusColor.opacity(0.7), radius: pulse ? 10 : 3)
            .scaleEffect(pulse ? 1.3 : 1.0)
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
        let highlight = statusColor.opacity(0.25)
        let base = Color(nsColor: .controlBackgroundColor)
        return LinearGradient(
            colors: [highlight, base.opacity(0.98), base],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
