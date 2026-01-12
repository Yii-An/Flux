import SwiftUI

struct CoreOfflineView: View {
    let coreState: CoreRuntimeState
    let onStart: () async -> Void
    let onInstallFromFile: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(description)
                .multilineTextAlignment(.center)
        } actions: {
            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var title: String {
        switch coreState {
        case .notInstalled:
            "Core Not Available".localizedStatic()
        case .starting:
            "Starting…".localizedStatic()
        case .stopping:
            "Stopping…".localizedStatic()
        case .stopped:
            "Core Stopped".localizedStatic()
        case .crashed:
            "Core Crashed".localizedStatic()
        case .error:
            "Core Unavailable".localizedStatic()
        case .running:
            "Core".localizedStatic()
        }
    }

    private var icon: String {
        switch coreState {
        case .notInstalled:
            "exclamationmark.triangle"
        case .stopped:
            "stop.circle"
        case .crashed, .error:
            "exclamationmark.circle"
        case .starting, .stopping:
            "hourglass"
        default:
            "bolt.slash"
        }
    }

    private var description: String {
        switch coreState {
        case .notInstalled:
            "Flux Core is not installed or not found.".localizedStatic()
        case .starting:
            "Core is starting. Please wait…".localizedStatic()
        case .stopping:
            "Core is stopping. Please wait…".localizedStatic()
        case .stopped:
            "Flux Core is not running.".localizedStatic()
        case .crashed:
            "Flux Core crashed. Start it again to recover.".localizedStatic()
        case .error:
            "Flux Core failed to start. Start it again or check logs.".localizedStatic()
        case .running:
            "Core is running.".localizedStatic()
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch coreState {
        case .notInstalled:
            VStack(spacing: 12) {
                Link(destination: URL(string: "https://github.com/anthropics/claude-code/releases")!) {
                    Label("Get Core...".localizedStatic(), systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    onInstallFromFile()
                } label: {
                    Label("Install from File...".localizedStatic(), systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }
        case .stopped, .crashed, .error:
            Button {
                Task { await onStart() }
            } label: {
                Label("Start Core".localizedStatic(), systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        case .starting, .stopping, .running:
            EmptyView()
        }
    }
}
