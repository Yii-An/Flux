import SwiftUI

struct UsageRiskCard: View {
    let quotaPressure: Double
    let riskyProviders: [QuotaRiskItem]

    var body: some View {
        HStack(spacing: UITokens.Spacing.lg) {
            ring

            VStack(alignment: .leading, spacing: 10) {
                Text("Usage Risk".localizedStatic())
                    .font(.headline)

                if riskyProviders.isEmpty {
                    Text("No risk".localizedStatic())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(riskyProviders.prefix(3)) { item in
                            HStack(spacing: 10) {
                                ProviderIcon(item.providerID, size: 18)

                                Text(item.displayNameKey.localizedStatic())
                                    .font(.subheadline)
                                    .lineLimit(1)

                                Spacer()

                                Text("\(Int(item.percentUsed * 100))%")
                                    .font(.dinNumber(.caption))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fluxCardStyle()
    }

    private var ring: some View {
        let clamped = min(1, max(0, quotaPressure))
        return ZStack {
            Circle()
                .stroke(Color.gray.opacity(0.15), lineWidth: 10)

            Circle()
                .trim(from: 0, to: clamped)
                .stroke(ringColor(clamped), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))

            VStack(spacing: 4) {
                Text("\(Int(clamped * 100))%")
                    .font(.dinNumber(.title3))

                Text("Quota".localizedStatic())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 110, height: 110)
    }

    private func ringColor(_ value: Double) -> Color {
        if value >= 0.90 { return .red }
        if value >= 0.75 { return .orange }
        return .green
    }
}
