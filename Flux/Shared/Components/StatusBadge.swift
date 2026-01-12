import SwiftUI

enum StatusType {
    case success, warning, error, neutral, active

    var color: Color {
        switch self {
        case .success, .active: return .green
        case .warning: return .orange
        case .error: return .red
        case .neutral: return .secondary
        }
    }
}

struct StatusBadge: View {
    let text: String
    let status: StatusType

    var body: some View {
        Text(text)
            .font(.system(.caption, design: .rounded))
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                Capsule()
                    .fill(status.color.opacity(0.15))
            }
            .foregroundStyle(status.color)
    }
}
