import SwiftUI

struct AlertsBanner: View {
    let providerStats: (ok: Int, warn: Int, error: Int)
    let systemAlerts: [String]

    var body: some View {
        HStack(spacing: UITokens.Spacing.md) {
            trafficLight

            VStack(alignment: .leading, spacing: 8) {
                Text(alertsTitle)
                    .font(.headline)

                Text(alertsText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(UITokens.Spacing.md)
        .frame(maxWidth: .infinity)
        .background(alertsBackground)
        .clipShape(RoundedRectangle(cornerRadius: UITokens.Radius.medium))
    }

    private var trafficLight: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(providerStats.error > 0 ? Color.red : Color.gray.opacity(0.3))
                .frame(width: 10, height: 10)

            Circle()
                .fill(providerStats.warn > 0 ? Color.orange : Color.gray.opacity(0.3))
                .frame(width: 10, height: 10)

            Circle()
                .fill(providerStats.ok > 0 ? Color.green : Color.gray.opacity(0.3))
                .frame(width: 10, height: 10)
        }
    }

    private var alertsTitle: String {
        if providerStats.error > 0 {
            return "System Alert".localizedStatic()
        } else if providerStats.warn > 0 {
            return "System Warning".localizedStatic()
        } else {
            return "System Status".localizedStatic()
        }
    }

    private var alertsText: String {
        if systemAlerts.isEmpty {
            return "All systems nominal".localizedStatic()
        } else {
            return systemAlerts.prefix(3).map { $0.localizedStatic() }.joined(separator: " • ")
        }
    }

    private var alertsBackground: some View {
        if providerStats.error > 0 {
            return Color.red.opacity(0.08)
        } else if providerStats.warn > 0 {
            return Color.orange.opacity(0.08)
        } else {
            return Color.green.opacity(0.08)
        }
    }
}
