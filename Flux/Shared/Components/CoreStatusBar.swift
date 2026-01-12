import SwiftUI

struct CoreStatusBar: View {
    let coreState: CoreRuntimeState
    let version: String?
    let onToggle: () -> Void

    init(coreState: CoreRuntimeState, version: String?, onToggle: @escaping () -> Void) {
        self.coreState = coreState
        self.version = version
        self.onToggle = onToggle
    }

    var body: some View {
        VStack(spacing: 4) {
            Divider()
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if isBusy {
                    SmallProgressView()
                        .frame(width: 14, height: 14)
                } else {
                    Button {
                        onToggle()
                    } label: {
                        Image(systemName: toggleSystemImage)
                    }
                    .buttonStyle(.subtle)
                    .help(toggleHelp)
                }

                if let version = version, !version.isEmpty {
                    Text("v\(version)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.regularMaterial)
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
        case .stopped, .notInstalled:
            return .red
        case .starting, .stopping:
            return .orange
        case .crashed, .error:
            return .red
        }
    }

    private var statusText: String {
        switch coreState {
        case .running:
            return "Core Running".localizedStatic()
        case .stopped:
            return "Core Stopped".localizedStatic()
        case .starting:
            return "Starting…".localizedStatic()
        case .stopping:
            return "Stopping…".localizedStatic()
        case .notInstalled:
            return "Core Not Installed".localizedStatic()
        case .crashed:
            return "Core Crashed".localizedStatic()
        case .error:
            return "Core Error".localizedStatic()
        }
    }

    private var toggleSystemImage: String {
        if coreState.isRunning {
            return "stop.fill"
        }
        return "play.fill"
    }

    private var toggleHelp: String {
        if coreState.isRunning {
            return "Stop Core".localizedStatic()
        }
        return "Start Core".localizedStatic()
    }
}

