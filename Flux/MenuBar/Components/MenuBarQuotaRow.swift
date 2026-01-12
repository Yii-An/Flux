import SwiftUI

struct MenuBarQuotaRow: View {
    let item: MenuBarViewModel.QuotaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProviderIcon(item.providerID, size: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.providerID.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)

                    Text(detailText)
                        .font(.dinBold(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                if let trailingText {
                    Text(trailingText)
                        .font(.dinBold(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            MenuBarProgressBar(fraction: progressFraction, tint: item.providerID.tintColor)
        }
        .padding(10)
        .fluxCardStyle()
    }

    private var snapshot: QuotaSnapshot { item.snapshot }

    private var detailText: String {
        switch snapshot.kind {
        case .ok:
            if let metrics = snapshot.metrics {
                let usedText = metrics.used.map(String.init) ?? "—"
                let limitText = metrics.limit.map(String.init) ?? "—"
                return "\(usedText)/\(limitText) \(metrics.unit.rawValue.localizedStatic())"
            }
            return snapshot.message ?? "OK".localizedStatic()
        case .authMissing, .unsupported, .error, .loading:
            return snapshot.message ?? "—"
        }
    }

    private var trailingText: String? {
        guard let fraction = progressFraction else { return nil }
        let percent = Int((fraction * 100).rounded())
        return "\(percent)%"
    }

    private var progressFraction: Double? {
        guard snapshot.kind == .ok, let metrics = snapshot.metrics else { return nil }
        guard let used = metrics.used, let limit = metrics.limit, limit > 0 else { return nil }

        let value = min(max(Double(used) / Double(limit), 0), 1)
        return value
    }
}

private struct MenuBarProgressBar: View {
    let fraction: Double?
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(max(fraction ?? 0, 0), 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.15))

                Capsule()
                    .fill(tint)
                    .frame(width: proxy.size.width * clamped)
            }
            .animation(.smooth(duration: 0.3), value: clamped)
        }
        .frame(height: 5)
    }
}
