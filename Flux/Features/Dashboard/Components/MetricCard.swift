import SwiftUI

enum MetricTrend: String, Sendable {
    case up
    case down
    case flat
}

struct MetricCard: View {
    let title: String
    let value: String
    let subtitle: String?
    let systemImage: String
    let tint: Color
    let trend: MetricTrend

    init(
        title: String,
        value: String,
        subtitle: String? = nil,
        systemImage: String,
        tint: Color = .accentColor,
        trend: MetricTrend = .flat
    ) {
        self.title = title
        self.value = value
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.trend = trend
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: systemImage)
                        .foregroundStyle(tint)
                }

                Spacer(minLength: 0)

                Image(systemName: trendSystemImage)
                    .font(.caption)
                    .foregroundStyle(trendColor)
            }

            Text(value)
                .font(.dinNumber(.title2))

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(UITokens.Spacing.md)
        .fluxCardStyle()
    }

    private var trendSystemImage: String {
        switch trend {
        case .up:
            return "arrow.up.right"
        case .down:
            return "arrow.down.right"
        case .flat:
            return "minus"
        }
    }

    private var trendColor: Color {
        switch trend {
        case .up:
            return .green
        case .down:
            return .red
        case .flat:
            return .secondary
        }
    }
}
