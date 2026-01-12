import SwiftUI

struct CoreStatusBadge: View {
    let state: CoreRuntimeState

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(status.color)
                .frame(width: UITokens.Radius.small, height: UITokens.Radius.small)

            Text("Core".localizedStatic())
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            StatusBadge(text: state.shortDescription, status: status)
        }
    }

    private var status: StatusType {
        switch state {
        case .running:
            return .active
        case .starting, .stopping:
            return .neutral
        case .stopped:
            return .warning
        case .notInstalled:
            return .neutral
        case .crashed, .error:
            return .error
        }
    }
}
