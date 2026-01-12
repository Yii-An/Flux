import SwiftUI

struct ProviderListCard: View {
    let items: [ProviderStatusItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Provider Status".localizedStatic())
                    .font(.headline)
                Spacer()
                Text("\(items.count)")
                    .font(.dinNumber(.caption))
                    .foregroundStyle(.secondary)
            }

            if items.isEmpty {
                Text("No Providers".localizedStatic())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(items.prefix(6)) { item in
                        ProviderStatusRow(item: item)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fluxCardStyle()
    }
}

private struct ProviderStatusRow: View {
    let item: ProviderStatusItem

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(item.providerID.displayName)
                .font(.subheadline)
                .lineLimit(1)

            Spacer()

            if let percentUsed = item.percentUsed {
                Text("\(Int(percentUsed * 100))%")
                    .font(.dinNumber(.caption))
                    .foregroundStyle(.secondary)
            }

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: UITokens.Radius.small))
    }

    private var statusColor: Color {
        switch item.kind {
        case .ok:
            return .green
        case .authMissing:
            return .orange
        case .error:
            return .red
        case .unsupported, .loading:
            return .secondary
        }
    }

    private var statusText: String {
        switch item.kind {
        case .ok:
            return "OK".localizedStatic()
        case .authMissing:
            return "Auth Missing".localizedStatic()
        case .unsupported:
            return "Unsupported".localizedStatic()
        case .error:
            return "Error".localizedStatic()
        case .loading:
            return "Loading".localizedStatic()
        }
    }
}
