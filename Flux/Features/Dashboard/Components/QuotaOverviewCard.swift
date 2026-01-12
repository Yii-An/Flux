import SwiftUI

struct QuotaOverviewCard: View {
    let providerStats: (ok: Int, warn: Int, error: Int)
    let quotaProvidersCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quota Status".localizedStatic())
                .font(.headline)

            HStack(spacing: UITokens.Spacing.md) {
                BigNumberView(
                    title: "OK".localizedStatic(),
                    value: "\(providerStats.ok)",
                    tint: .green
                )

                BigNumberView(
                    title: "Warning".localizedStatic(),
                    value: "\(providerStats.warn)",
                    tint: .orange
                )

                BigNumberView(
                    title: "Error".localizedStatic(),
                    value: "\(providerStats.error)",
                    tint: .red
                )
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Text(String(format: "%@ quota providers".localizedStatic(), String(quotaProvidersCount)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                Text("Updated on refresh".localizedStatic())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: UITokens.Radius.small))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fluxCardStyle()
    }
}
