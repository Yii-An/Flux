import SwiftUI

struct MetricsRow: View {
    let quotaProvidersCount: Int
    let credentialsAvailableCount: Int
    let quotaOKCount: Int
    let installedAgentsCount: Int

    var body: some View {
        HStack(spacing: UITokens.Spacing.md) {
            StatCard(
                icon: "server.rack",
                title: "Quota Providers".localizedStatic(),
                value: "\(quotaProvidersCount)",
                tint: .blue
            )

            StatCard(
                icon: "checkmark.seal.fill",
                title: "Credentials Ready".localizedStatic(),
                value: "\(credentialsAvailableCount)",
                tint: .green
            )

            StatCard(
                icon: "chart.pie.fill",
                title: "Quota OK".localizedStatic(),
                value: "\(quotaOKCount)",
                tint: .purple
            )

            StatCard(
                icon: "terminal.fill",
                title: "Agents Installed".localizedStatic(),
                value: "\(installedAgentsCount)",
                tint: .orange
            )
        }
        .frame(maxWidth: .infinity)
    }
}
